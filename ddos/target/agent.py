#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
 靶机 agent —— 隔离内网 多向量 DDoS / 端口扫描 / 爆破 检测、自动封禁与审计面板
==============================================================================
 部署位置 : /opt/ddos/agent.py   （root 运行）
 运行方式 : python3 /opt/ddos/agent.py            （或 systemctl start ddos-agent）
 面板地址 : http://192.168.3.152:5000/            （面板 HTML 独立为 index.html，
                                                   与本文件同目录或 PANEL_FILE 指定的路径）

 线程模型:
   1) sniff   : Scapy 抓包，统计 L4 来源 / 端口分布 / 每源端口集合（扫描检测）
   2) nginx   : tail -F access.log，解析 HTTP 请求，统计每源 QPS
   3) secure  : tail -F /var/log/secure，解析 SSH 失败
   4) blocker : 每 2s 评估阈值 -> iptables 封禁/解封 -> 写审计日志

 日志（JSON Lines）: /var/log/ddos/{packets,http,auth,blocks}.jsonl
 API                : GET /  GET /api/stats  POST /api/unblock  POST /api/auto
==============================================================================
"""

import io
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections import deque, defaultdict

try:                                   # Python 3 标准库；py2 无此模块则只支持精确 IP
    import ipaddress
except ImportError:                    # pragma: no cover
    ipaddress = None

try:
    from flask import Flask, Response, jsonify, request, send_file
except ImportError:  # pragma: no cover
    sys.exit("[!] 缺少 flask，请执行: pip install flask==2.0.3 (py3) / flask==1.1.4 (py2)")


# ============================================================================
#                          关键参数常量区（调参只改这里）
# ============================================================================

# ---------------- 网络 / 监听 ----------------
IFACE = os.environ.get("DDOS_IFACE", "")        # 嗅探网卡；留空自动探测默认路由出口网卡
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("DDOS_PORT", "5000"))

# ---------------- 会话关闭 / 数据目录 ----------------
WORK_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = "/var/log/ddos"
PANEL_FILE = os.environ.get("DDOS_PANEL", os.path.join(WORK_DIR, "index.html"))

# ---------------- 受保护端口（flood 封禁永远不动 SSH） ----------------
SYN_DPORT = 80      # SYN Flood 检测的 TCP 目的端口
UDP_DPORT = 53      # UDP Flood 检测的 UDP 目的端口

# ---------------- 滑动窗口（秒） ----------------
WINDOW = 5.0            # 通用滑动窗口
BRUTE_WINDOW = 60.0     # SSH 爆破窗口

# ---------------- 检测阈值（默认值，可通过命令行覆盖） ----------------
SYN_RATE_TH = 80        # 单源 80 端口 SYN > N/s  -> SYN flood
UDP_RATE_TH = 80        # 单源 53 端口 UDP > N/s  -> UDP flood
HTTP_RATE_TH = 20       # 单源 HTTP > N/s         -> HTTP flood
SCAN_PORT_TH = 10       # 单源 5s 内不同目的端口数 > N -> 端口扫描
BRUTE_TH = 5            # 单源 60s SSH 失败 > N   -> SSH 爆破

# ---------------- 封禁策略 ----------------
BLOCK_TTL = 60          # 普通/全端口封禁持续时间（秒），到期自动解封
MAX_BLOCKED = 200       # 同时存在的封禁条数上限
MAX_NEW_PER_ROUND = 20  # blocker 每轮最多处理的新源数量
POLL_INTERVAL = 2.0     # blocker 评估周期（秒）
BLOCK_TAG = "DDoS_BLOCK"          # iptables 规则注释标签（用于清理/解封）
MAX_SOURCE_TABLE = 30             # 面板 / API 每张表返回的最大来源数
EVENT_MAX = 200                   # 事件环形缓冲长度

# ---------------- 白名单（永不被封） ----------------
WHITELIST = {
    "127.0.0.1",        # 本机
    "192.168.3.152",    # 靶机自身（服务端）
    "192.168.3.155",    # 管理机（客户端，浏览器访问面板）
    "192.168.3.153",    # 攻击机（攻击端/备用客户端；管理员可临时注释此行以观察真实封禁效果）
}
WHITELIST = {ip.strip() for ip in WHITELIST if ip.strip()}

# ---------------- 外部白名单文件（IP 变动只改这里，不改代码） ----------------
# 每行一个 IP 或 CIDR，# 开头为注释；由 1_setup_target.sh 生成，tools/net_sync.py 维护
WHITELIST_FILE = os.environ.get("DDOS_WHITELIST_FILE", "/etc/ddos/whitelist.txt")
WHITELIST_NETS = []


def load_whitelist_file(path):
    nets = []
    try:
        with io.open(path, "r", encoding="utf-8") as f:
            for line in f:
                s = line.split("#", 1)[0].strip()
                if not s:
                    continue
                if ipaddress is None:
                    WHITELIST.add(s)
                    continue
                try:
                    nets.append(ipaddress.ip_network(s, strict=False))
                except ValueError:
                    sys.stderr.write("[!] 忽略非法白名单项: %r\n" % s)
    except (IOError, OSError):
        pass
    return nets


WHITELIST_NETS = load_whitelist_file(WHITELIST_FILE)

# ---------------- 用户字典（secure 日志解析用） ----------------
USER_RE = re.compile(r"Failed password for (?:invalid user )?(\S+) from (\d+\.\d+\.\d+\.\d+)")

# ---------------- 运行时开关 ----------------


# ============================================================================
#                          共享数据结构 + 全局锁
# ============================================================================

LOCK = threading.RLock()

l4 = defaultdict(lambda: deque())            # src -> deque(ts)   80/TCP SYN
udp = defaultdict(lambda: deque())           # src -> deque(ts)   53/UDP
http = defaultdict(lambda: deque())          # src -> deque(ts)   HTTP 请求
port_cnt = defaultdict(lambda: deque())      # dport -> deque(ts) 全局端口分布
src_ports = defaultdict(lambda: defaultdict(lambda: deque()))  # src -> dport -> deque(ts)
brute = defaultdict(lambda: deque())         # src -> deque(ts)   SSH 失败
blocked = {}                                 # ip -> {reason, until, rules, full}
events = deque(maxlen=EVENT_MAX)             # 最近事件

# 流量统计（分类累计 + 每秒直方图，供面板“流量统计与分类”区块） ============
TRAFFIC = defaultdict(int)                   # 分类累计: syn/udp/http/brute/other
traffic_hist = deque(maxlen=120)             # 每秒桶: {t, syn, udp, http, brute, other}

AUTO_BLOCK = True                            # 自动屏蔽总开关

# 后台线程停止标志 + 抓包过滤器热更新参数 =====================================
STOP = threading.Event()
SNIFF_NEED = []          # 当前工作集，用于打印日志
SNIFF_DPORTS = set()     # sniff 线程用：需要收包的端口集合（由主循环维护）

# 抓包按秒聚合（每包落盘会把磁盘写满：800pps 约 6GB/天）
PKT_BUCKET = {"t": 0, "tcp": 0, "udp": 0}


# ============================================================================
#                          工具函数
# ============================================================================

def now():
    return time.time()


def hhmmss(ts=None):
    return time.strftime("%H:%M:%S", time.localtime(ts if ts is not None else now()))


def say(msg):
    """跨版本安全输出：print(..., flush=True) 仅在 Python3.3+ 可用，
    CentOS7 的 python2 会把它当元组解析而报 SyntaxError，故统一先写再 flush。
    编码兜底：LANG=C 时中文会 UnicodeEncodeError，绝不能让它打死 blocker 线程。"""
    try:
        sys.stdout.write(str(msg) + "\n")
        sys.stdout.flush()
    except Exception:
        pass


def add_event(msg, level="info"):
    """写事件到环形缓冲 + 打印"""
    with LOCK:
        events.append({"ts": hhmmss(), "msg": msg, "level": level})
    say("[%s] %s" % (hhmmss(), msg))


def rate_of(dq, window, t=None):
    """deque 中窗口内元素数量 / 窗口长度，得到每秒速率"""
    t = t if t is not None else now()
    lo = t - window
    n = 0
    for ts in reversed(dq):
        if ts >= lo:
            n += 1
        else:
            break
    return round(n / window, 1)


def prune(dq, keep_secs):
    """去掉窗口外的旧时间戳"""
    lo = now() - keep_secs
    while dq and dq[0] < lo:
        dq.popleft()


def traffic_count(kind, n=1, t=None):
    """流量分类计数：累计 + 归入当前秒桶（kind: syn/udp/http/brute/other）"""
    t = t if t is not None else now()
    sec = int(t)
    with LOCK:
        TRAFFIC[kind] = TRAFFIC.get(kind, 0) + n
        if traffic_hist and traffic_hist[-1]["t"] == sec:
            b = traffic_hist[-1]
        else:
            b = {"t": sec, "syn": 0, "udp": 0, "http": 0, "brute": 0, "other": 0}
            traffic_hist.append(b)
        b[kind] = b.get(kind, 0) + n


def _pkt_bucket(ts, proto):
    """抓包按秒聚合：每秒最多写一行 packets.jsonl（调用方须已持 LOCK）"""
    sec = int(ts)
    if PKT_BUCKET["t"] != sec:
        if PKT_BUCKET["t"]:
            log_jsonl("packets", {"ts": hhmmss(PKT_BUCKET["t"]),
                                  "tcp": PKT_BUCKET["tcp"], "udp": PKT_BUCKET["udp"]})
        PKT_BUCKET["t"] = sec
        PKT_BUCKET["tcp"] = 0
        PKT_BUCKET["udp"] = 0
    PKT_BUCKET[proto] = PKT_BUCKET.get(proto, 0) + 1


def log_jsonl(name, obj):
    """追加一行 JSON 到 /var/log/ddos/<name>.jsonl，失败静默"""
    try:
        line = json.dumps(obj, ensure_ascii=False)
        if not isinstance(line, type(u"")):      # py2: str -> 统一为 unicode
            line = line.decode("utf-8", "replace")
        # py2 的内置 open() 不认 encoding=，用 io.open（py3 即内置 open）
        with io.open(os.path.join(LOG_DIR, name + ".jsonl"), "a", encoding="utf-8") as f:
            f.write(line + u"\n")
    except Exception:
        pass


def run_cmd(args):
    """执行命令，返回 (returncode, stdout+stderr)
    Python2 的 Popen.communicate() 不支持 timeout=（3.3+ 才有），
    故先尝试带超时，失败则退回无超时版本（iptables/ip 命令本身都是秒回）。"""
    try:
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            out, _ = p.communicate(timeout=10)
        except TypeError:                      # py2: 不认识 timeout 关键字
            out, _ = p.communicate()
        except subprocess.TimeoutExpired:      # 超时后必须 kill，否则子进程可能持 xtables 锁
            p.kill()
            p.communicate()
            return -1, "timeout: %s" % " ".join(args)
        return p.returncode, (out or b"").decode("utf-8", "ignore")
    except Exception as e:
        return -1, str(e)


def is_whitelisted(ip):
    if ip in WHITELIST:
        return True
    if ipaddress is None:
        return False
    try:
        addr = ipaddress.ip_address(ip)
    except (ValueError, TypeError):
        return False
    for net in WHITELIST_NETS:
        try:
            if addr in net:
                return True
        except TypeError:                 # IPv6 地址 vs IPv4Network（py3.6 会抛）
            continue
    return False


def detect_iface():
    """自动探测默认路由出口网卡：白名单对端 -> 8.8.8.8 -> 默认路由 -> 第一块非 lo 网卡。
    注意必须跳过 dev lo：白名单里含本机 IP，`ip route get 本机IP` 会返回 lo，
    若采用会让 scapy 嗅探回环网卡，L4 检测静默失效。"""
    global IFACE
    if IFACE:
        return IFACE
    probes = [ip for ip in sorted(WHITELIST) if not ip.startswith("127.")]
    probes.append("8.8.8.8")
    for probe in probes:
        rc, out = run_cmd(["ip", "route", "get", probe])
        if rc == 0:
            m = re.search(r"dev\s+(\S+)", out)
            if m and m.group(1) != "lo":
                IFACE = m.group(1)
                return IFACE
    rc, out = run_cmd(["ip", "route", "show", "default"])
    if rc == 0:
        m = re.search(r"dev\s+(\S+)", out)
        if m and m.group(1) != "lo":
            IFACE = m.group(1)
            return IFACE
    rc, out = run_cmd(["ip", "-o", "-4", "addr", "show"])
    if rc == 0:
        for line in out.splitlines():
            m = re.search(r"^\d+:\s+(\S+)\s+inet\s", line)
            if m and m.group(1) != "lo":
                IFACE = m.group(1)
                return IFACE
    IFACE = "eth0"
    return IFACE


# ============================================================================
#                          iptables 封禁实现
# ============================================================================

def iptables_rule_args(ip, dport, proto):
    """单端口封禁的 -I 参数"""
    return ["-I", "INPUT", "1", "-s", ip, "-p", proto,
            "--dport", str(dport), "-m", "comment", "--comment", BLOCK_TAG, "-j", "DROP"]


def iptables_full_rule_args(ip):
    """全端口封禁的 -I 参数"""
    return ["-I", "INPUT", "1", "-s", ip, "-m", "comment", "--comment", BLOCK_TAG, "-j", "DROP"]


def add_rule(args):
    rc, out = run_cmd(["iptables"] + args)
    if rc != 0:
        print("[!] iptables 添加失败: %s -> %s" % (" ".join(args), out.strip()))
    return rc == 0


def del_rule(args):
    rc, out = run_cmd(["iptables"] + args)
    if rc != 0:
        print("[!] iptables 删除失败: %s -> %s" % (" ".join(args), out.strip()))
    return rc == 0


def del_args(args):
    """add_rule 的参数（-I INPUT 1 ...）→ 删除参数（-D INPUT ...）"""
    if args and args[0] == "-I" and len(args) >= 3:
        return ["-D", args[1]] + args[3:]
    return ["-D"] + args[1:]


def apply_block(ip, full, kind=""):
    """执行封禁，返回实际生效的规则列表（用于解封）"""
    rules = []
    if kind == "brute":
        # 爆破只封 22/tcp：全端口 DROP 会把敲错密码的自己人连同面板一起封死
        args = iptables_rule_args(ip, 22, "tcp")
        if add_rule(args):
            rules.append(args)
        return rules, False
    if full:
        # 全端口 DROP 一条即可（含 SSH），只用于判定扫描/爆破的源
        if add_rule(iptables_full_rule_args(ip)):
            rules.append(iptables_full_rule_args(ip))
        return rules, True

    # flood：tcp/80 + udp/53，绝不会碰到 22
    for proto, dport in (("tcp", SYN_DPORT), ("udp", UDP_DPORT)):
        if dport == 22:
            continue
        args = iptables_rule_args(ip, dport, proto)
        if add_rule(args):
            rules.append(args)
    return rules, False


def release_block(ip, reason, full, why="", log=True):
    """解封：按记录的规则逐条删除；删除失败则保留记录，下一轮自动重试"""
    with LOCK:
        info = blocked.get(ip)
    rules = info.get("rules") if info else None
    if rules is None and info is not None:
        rules = []
    if not info:
        # 兜底：清理可能残留的同 IP 规则
        rules = [iptables_rule_args(ip, SYN_DPORT, "tcp"),
                 iptables_rule_args(ip, UDP_DPORT, "udp"),
                 iptables_full_rule_args(ip)]
    failed = [args for args in rules if not del_rule(del_args(args))]
    with LOCK:
        if info is not None and failed:
            info["retries"] = info.get("retries", 0) + 1
            blocked[ip] = info
        else:
            blocked.pop(ip, None)
    if failed:
        if info is None or info.get("retries", 0) % 5 == 1:
            add_event("解封 %s 失败 %d 条规则（保留记录，稍后重试）" % (ip, len(failed)), "warn")
        return False
    if log:
        log_jsonl("blocks", {"ts": hhmmss(), "action": "unblock", "ip": ip,
                             "reason": reason, "full": bool(full), "why": why})
        add_event("解封 %s（%s）" % (ip, why or reason), "ok")
    return True


def cleanup_rules():
    """启动清理：删除所有含 DDoS_BLOCK 注释的 INPUT 规则（兼容 -A / -I）
    注意 iptables -S 输出的 comment 带引号，必须用 shlex 拆，
    否则 -D 参数里残留引号，规则永远删不掉（重启自愈失效）。"""
    global blocked
    rc, out = run_cmd(["iptables", "-S", "INPUT"])
    if rc != 0:
        print("[!] 读取 iptables 失败: %s" % out.strip())
        return 0
    n = 0
    n_fail = 0
    for line in out.splitlines():
        if BLOCK_TAG not in line:
            continue
        if not (line.startswith("-A INPUT") or line.startswith("-I INPUT")):
            continue
        try:
            parts = shlex.split(line)
        except ValueError:
            parts = line.split()
        if not parts:
            continue
        parts[0] = "-D"                     # -A/-I -> -D，按规则规格删除
        if del_rule(parts):
            n += 1
        else:
            n_fail += 1
    with LOCK:
        if not n_fail:                      # 有残留不能假装清空，否则失去追踪
            blocked = {}
    print("[*] 启动清理：删除残留 %s 规则 %d 条%s"
          % (BLOCK_TAG, n, ("，失败 %d 条（见上方错误）" % n_fail) if n_fail else ""))
    return n


def list_block_rules():
    """返回当前 DDoS_BLOCK 规则列表（调试用）"""
    rc, out = run_cmd(["iptables", "-S", "INPUT"])
    return [l for l in out.splitlines() if BLOCK_TAG in l] if rc == 0 else []


# ============================================================================
#                          采集线程 1：Scapy 抓包
# ============================================================================

def sniff_worker():
    try:
        from scapy.all import IP, IPv6, TCP, UDP, sniff, conf
    except ImportError:
        add_event("未安装 scapy，L4 抓包线程退出（仅统计 HTTP/SSH）", "warn")
        return

    conf.sniff_promisc = 1
    # 只抓 TCP SYN + 全部 UDP：端口扫描/端口分布需要任意目的端口，
    # 原过滤器只放行 80/22/53，导致 SCAN_PORT_TH 永远不可能触发。
    # 注意 libpcap 语法的比较运算用单个 "="（"==" 会直接报语法错误，抓包线程起不来）。
    # 只抓「纯 SYN」：带 ACK 的 SYN-ACK 是本机对 flood 的回应，若一并统计，
    # 本机 IP 会因为成千上万个随机源端口被误判成「端口扫描」（实测 ports=1821）。
    bpf = "udp or (tcp and (tcp[tcpflags] & (tcp-syn|tcp-ack) = tcp-syn))"
    add_event("抓包线程启动 iface=%s filter=%s" % (detect_iface(), bpf))

    # 每次都新建一次 sniff，便于周期性重建（CentOS7 + libpcap 关闭缓冲较慢；
    # 如需实时性更好，可在 conf 中关闭 buffered mode）
    def _cb(pkt):
        try:
            if IP not in pkt:
                return                      # 只统计 IPv4：IPv6 源无法用 IPv4 iptables 封禁
            src = pkt[IP].src
            ts = now()
            if TCP in pkt and pkt[TCP].dport is not None:
                dport = int(pkt[TCP].dport)
                flags = pkt[TCP].flags
                is_syn = bool((int(flags) & 0x02) and not (int(flags) & 0x10))
                with LOCK:
                    port_cnt[dport].append(ts)
                    prune(port_cnt[dport], WINDOW * 2)
                    src_ports[src][dport].append(ts)
                    prune(src_ports[src][dport], WINDOW * 2)
                    if dport == SYN_DPORT and is_syn:
                        l4[src].append(ts)
                        traffic_count("syn", 1, ts)
                    else:
                        traffic_count("other", 1, ts)
                    _pkt_bucket(ts, "tcp")
            elif UDP in pkt and pkt[UDP].dport is not None:
                dport = int(pkt[UDP].dport)
                with LOCK:
                    port_cnt[dport].append(ts)
                    prune(port_cnt[dport], WINDOW * 2)
                    src_ports[src][dport].append(ts)
                    prune(src_ports[src][dport], WINDOW * 2)
                    if dport == UDP_DPORT:
                        udp[src].append(ts)
                        traffic_count("udp", 1, ts)
                    else:
                        traffic_count("other", 1, ts)
                    _pkt_bucket(ts, "udp")
        except Exception:
            pass

    while not STOP.is_set():
        try:
            sniff(iface=detect_iface(), filter=bpf, prn=_cb, store=False, timeout=5)
        except Exception as e:
            add_event("抓包异常：%s（5s 后重试）" % e, "warn")
            time.sleep(5)


# ============================================================================
#                          采集线程 2：Nginx 日志 tail
# ============================================================================

# 期望的 ddos 日志格式（见 target/nginx/ddos.conf）：
#   $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent
#   "$http_referer" "$http_user_agent" "$http_x_forwarded_for"
LOG_RE = re.compile(
    r'^(?P<remote>\S+) \S+ \S+ \[(?P<time>[^\]]+)\] "(?P<req>[^"]*)" '
    r'(?P<status>\d{3}) (?P<bytes>\S+) "(?P<ref>[^"]*)" "(?P<ua>[^"]*)" "(?P<xff>[^"]*)"'
)
# 兜底：标准 combined 格式（不含 xff）
LOG_RE_FALLBACK = re.compile(
    r'^(?P<remote>\S+) \S+ \S+ \[(?P<time>[^\]]+)\] "(?P<req>[^"]*)" '
    r'(?P<status>\d{3}) (?P<bytes>\S+) "(?P<ref>[^"]*)" "(?P<ua>[^"]*)"'
)

NGINX_LOG = "/var/log/nginx/access.log"


def nginx_worker():
    proc = None
    while not STOP.is_set():
        try:
            if proc is None or proc.poll() is not None:
                if not os.path.exists(NGINX_LOG):
                    add_event("未找到 %s，等待 Nginx 日志" % NGINX_LOG, "warn")
                    time.sleep(10)
                    continue
                proc = subprocess.Popen(["tail", "-n", "0", "-F", NGINX_LOG],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                add_event("Nginx 日志采集线程启动")
            line = proc.stdout.readline()
            if not line:
                time.sleep(0.2)
                continue
            line = line.decode("utf-8", "ignore").strip()
            if not line or line.startswith("tail:"):
                continue
            m = LOG_RE.match(line) or LOG_RE_FALLBACK.match(line)
            if not m:
                continue
            gd = m.groupdict()
            req = gd.get("req") or ""
            parts = req.split()
            method = parts[0] if len(parts) > 0 else "-"
            path = parts[1] if len(parts) > 1 else "-"
            remote = gd["remote"]
            ts = now()
            with LOCK:
                http[remote].append(ts)
                prune(http[remote], WINDOW * 2)
            traffic_count("http", 1, ts)
            log_jsonl("http", {"ts": hhmmss(ts), "remote": remote, "xff": gd.get("xff", "-"),
                               "method": method, "path": path, "status": int(gd["status"]),
                               "ua": gd.get("ua", "-")})
        except Exception as e:
            add_event("Nginx 日志线程异常：%s" % e, "warn")
            time.sleep(2)
            proc = None


# ============================================================================
#                          采集线程 3：/var/log/secure tail（SSH 失败）
# ============================================================================

SECURE_LOG = "/var/log/secure"


def secure_worker():
    proc = None
    while not STOP.is_set():
        try:
            if proc is None or proc.poll() is not None:
                if not os.path.exists(SECURE_LOG):
                    add_event("未找到 %s，等待 SSH 日志" % SECURE_LOG, "warn")
                    time.sleep(10)
                    continue
                proc = subprocess.Popen(["tail", "-n", "0", "-F", SECURE_LOG],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                add_event("SSH 失败日志采集线程启动")
            line = proc.stdout.readline()
            if not line:
                time.sleep(0.2)
                continue
            line = line.decode("utf-8", "ignore").strip()
            m = USER_RE.search(line)
            if not m:
                continue
            user, src = m.group(1), m.group(2)
            ts = now()
            with LOCK:
                brute[src].append(ts)
                prune(brute[src], BRUTE_WINDOW * 2)
            traffic_count("brute", 1, ts)
            log_jsonl("auth", {"ts": hhmmss(ts), "src": src, "user": user, "event": "ssh_failed"})
        except Exception as e:
            add_event("SSH 日志线程异常：%s" % e, "warn")
            time.sleep(2)
            proc = None


# ============================================================================
#                          执行线程 4：Blocker 阈值评估
# ============================================================================

def collect_candidates():
    """在锁内计算所有候选（不做 iptables 调用，避免持锁执行外部命令）"""
    cands = []
    t = now()
    lo = t - WINDOW
    with LOCK:
        # SYN Flood
        for src, dq in list(l4.items()):
            prune(dq, WINDOW * 2)
            if not dq:
                del l4[src]
                continue
            r = rate_of(dq, WINDOW, t)
            if r > SYN_RATE_TH:
                cands.append(("syn", src, r, False, "SYN flood %.0f/s" % r))
        # UDP Flood
        for src, dq in list(udp.items()):
            prune(dq, WINDOW * 2)
            if not dq:
                del udp[src]
                continue
            r = rate_of(dq, WINDOW, t)
            if r > UDP_RATE_TH:
                cands.append(("udp", src, r, False, "UDP flood %.0f/s" % r))
        # HTTP Flood
        for src, dq in list(http.items()):
            prune(dq, WINDOW * 2)
            if not dq:
                del http[src]
                continue
            r = rate_of(dq, WINDOW, t)
            if r > HTTP_RATE_TH:
                cands.append(("http", src, r, False, "HTTP flood %.0f/s" % r))
        # 端口扫描
        for src, pmap in list(src_ports.items()):
            port_set = {}
            for dport, dq in list(pmap.items()):
                prune(dq, WINDOW * 2)
                cnt = sum(1 for x in dq if x >= lo)
                if cnt:
                    port_set[dport] = cnt
                elif not dq:
                    del pmap[dport]
            if not pmap:
                del src_ports[src]
                continue
            if len(port_set) > SCAN_PORT_TH:
                cands.append(("scan", src, len(port_set), True, "port scan %d ports" % len(port_set)))
        # SSH 爆破
        for src, dq in list(brute.items()):
            prune(dq, BRUTE_WINDOW * 2)
            if not dq:
                del brute[src]
                continue
            n = sum(1 for x in dq if x >= t - BRUTE_WINDOW)
            if n > BRUTE_TH:
                cands.append(("brute", src, n, True, "SSH brute %d/60s" % n))
    return cands


def housekeeping():
    """每轮清理窗口外数据；独立于 AUTO_BLOCK 执行（--no-auto 时也不能无限增长）"""
    t = now()
    lo5 = t - WINDOW * 2
    lo60 = t - BRUTE_WINDOW * 2
    with LOCK:
        for mp, lo in ((l4, lo5), (udp, lo5), (http, lo5), (brute, lo60)):
            for k, dq in list(mp.items()):
                while dq and dq[0] < lo:
                    dq.popleft()
                if not dq:
                    del mp[k]
        for dport, dq in list(port_cnt.items()):
            while dq and dq[0] < lo5:
                dq.popleft()
            if not dq:
                del port_cnt[dport]
        for src, pmap in list(src_ports.items()):
            for dport, dq in list(pmap.items()):
                while dq and dq[0] < lo5:
                    dq.popleft()
                if not dq:
                    del pmap[dport]
            if not pmap:
                del src_ports[src]


def blocker_worker():
    add_event("Blocker 线程启动（自动屏蔽默认 %s）" % ("开启" if AUTO_BLOCK else "关闭"))
    full_warn_at = [0.0]
    while not STOP.is_set():
        try:
            t = now()
            housekeeping()

            # ---- 1) 到期自动解封 ----
            expired = []
            with LOCK:
                for ip, info in list(blocked.items()):
                    if info["until"] <= t:
                        expired.append((ip, info))
            for ip, info in expired:
                release_block(ip, info["reason"], info["full"], why="TTL 到期")

            # ---- 2) 阈值评估 + 封禁 ----
            if AUTO_BLOCK:
                cands = collect_candidates()
                # 优先级：扫描/爆破（全端口） > flood；同一源只封一次
                order = {"scan": 0, "brute": 1, "syn": 2, "udp": 3, "http": 4}
                cands.sort(key=lambda c: (order.get(c[0], 9), -c[2]))
                seen = set()
                new_cnt = 0
                for kind, src, val, full, reason in cands:
                    if src in seen:
                        continue
                    seen.add(src)
                    if is_whitelisted(src):
                        continue
                    with LOCK:
                        if src in blocked:
                            continue
                    with LOCK:
                        if len(blocked) >= MAX_BLOCKED:
                            if t - full_warn_at[0] > 60:
                                full_warn_at[0] = t
                                add_event("封禁表已满（%d），新来源暂不封禁" % MAX_BLOCKED, "warn")
                            continue
                    if new_cnt >= MAX_NEW_PER_ROUND:
                        break
                    rules, full_ = apply_block(src, full, kind)
                    if not rules:
                        continue
                    until = now() + BLOCK_TTL
                    with LOCK:
                        blocked[src] = {"reason": reason, "until": until,
                                        "rules": rules, "full": full_}
                    log_jsonl("blocks", {"ts": hhmmss(), "action": "block", "ip": src,
                                         "reason": reason, "full": full_, "why": kind})
                    add_event("封禁 %s  %s%s" % (src, reason, "（全端口）" if full_ else ""), "block")
                    new_cnt += 1
        except Exception as e:
            add_event("Blocker 线程异常：%s" % e, "warn")
        STOP.wait(POLL_INTERVAL)


# ============================================================================
#                          面板 HTTP API
# ============================================================================

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False


def _blocked_now(ip):
    with LOCK:
        return ip in blocked


def build_stats():
    """生成 /api/stats 返回结构（字段严格按需求文档 3.6）"""
    t = now()
    out = {"ts": hhmmss(t), "auto": AUTO_BLOCK}
    with LOCK:
        # L4 / UDP / HTTP 来源
        for key, dq_map, win in (("l4", l4, WINDOW), ("udp", udp, WINDOW), ("http", http, WINDOW)):
            rows = []
            for src, dq in dq_map.items():
                r = rate_of(dq, win, t)
                if r > 0 or src in blocked:
                    rows.append({"ip": src, "rate": r, "blocked": src in blocked})
            rows.sort(key=lambda x: -x["rate"])
            out[key] = rows[:MAX_SOURCE_TABLE]

        # 端口分布
        ports = []
        for dport, dq in port_cnt.items():
            r = rate_of(dq, win, t)
            if r > 0:
                ports.append({"port": int(dport), "rate": r})
        ports.sort(key=lambda x: -x["rate"])
        out["ports"] = ports[:MAX_SOURCE_TABLE]

        # 扫描 / 多端口
        scans = []
        lo = t - WINDOW
        for src, pmap in src_ports.items():
            n = sum(1 for dq in pmap.values() if any(x >= lo for x in dq))
            if n >= 3 or (src in blocked and blocked[src].get("reason", "").startswith("port scan")):
                scans.append({"ip": src, "ports": n, "blocked": src in blocked})
        scans.sort(key=lambda x: -x["ports"])
        out["scans"] = scans[:MAX_SOURCE_TABLE]

        # SSH 爆破失败
        lo = t - BRUTE_WINDOW
        brs = []
        for src, dq in brute.items():
            n = sum(1 for x in dq if x >= lo)
            if n > 0 or (src in blocked and blocked[src].get("reason", "").startswith("SSH brute")):
                brs.append({"ip": src, "fails": n, "blocked": src in blocked})
        brs.sort(key=lambda x: -x["fails"])
        out["brute"] = brs[:MAX_SOURCE_TABLE]

        # ---- 流量统计与分类 ----
        w5 = t - WINDOW
        w60 = t - BRUTE_WINDOW
        syn_n = sum(sum(1 for x in dq if x >= w5) for dq in l4.values())
        udp_n = sum(sum(1 for x in dq if x >= w5) for dq in udp.values())
        http_n = sum(sum(1 for x in dq if x >= w5) for dq in http.values())
        brute_n = sum(sum(1 for x in dq if x >= w60) for dq in brute.values())
        pkts_n = sum(sum(1 for x in dq if x >= w5) for dq in port_cnt.values())

        # 来源分类：窗口内取每个源的主导类型
        cls_rows = []
        for src in set(list(l4) + list(udp) + list(http) + list(brute) + list(src_ports)):
            s_n = sum(1 for x in l4.get(src, ()) if x >= w5)
            u_n = sum(1 for x in udp.get(src, ()) if x >= w5)
            h_n = sum(1 for x in http.get(src, ()) if x >= w5)
            b_n = sum(1 for x in brute.get(src, ()) if x >= w60)
            p_n = 0
            if src in src_ports:
                p_n = sum(1 for dq in src_ports[src].values()
                          if any(x >= w5 for x in dq))
            if s_n + u_n + h_n + b_n + p_n == 0 and src not in blocked:
                continue
            cand = [("SYN", s_n), ("UDP", u_n), ("HTTP", h_n),
                    ("爆破", b_n), ("扫描", p_n if p_n >= 3 else 0)]
            cand.sort(key=lambda x: -x[1])
            typ = cand[0][0] if cand[0][1] > 0 else "其他"
            cls_rows.append({"ip": src, "type": typ,
                             "syn": s_n, "udp": u_n, "http": h_n,
                             "brute": b_n, "ports": p_n,
                             "rate": round((s_n + u_n + h_n) / WINDOW, 1),
                             "blocked": src in blocked})
        cls_rows.sort(key=lambda x: -(x["syn"] + x["udp"] + x["http"] +
                                      x["brute"] + x["ports"]))

        out["traffic"] = {
            "totals": dict(TRAFFIC),
            "hist": [dict(b) for b in list(traffic_hist)],
            "rates": {"syn": round(syn_n / WINDOW, 1),
                      "udp": round(udp_n / WINDOW, 1),
                      "http": round(http_n / WINDOW, 1),
                      "brute": round(brute_n / BRUTE_WINDOW, 1),
                      "pkts": round(pkts_n / WINDOW, 1)},
        }
        out["classify"] = cls_rows[:MAX_SOURCE_TABLE]

        # 被屏蔽表
        bl = []
        for ip, info in blocked.items():
            bl.append({"ip": ip, "reason": info["reason"], "full": bool(info["full"]),
                       "ttl": max(0, int(info["until"] - t))})
        bl.sort(key=lambda x: x["ttl"])
        out["blocked"] = bl

        out["events"] = list(events)[-60:][::-1]
    return out


@app.route("/")
def index():
    try:
        return send_file(PANEL_FILE)
    except Exception:
        html = ("<h3>未找到面板文件</h3><p>请把 index.html 放到 %s，"
                "或用环境变量 DDOS_PANEL 指定。</p>" % PANEL_FILE)
        return Response(html, mimetype="text/html")


@app.before_request
def _json_only_for_write():
    """写操作只接受 application/json：挡住跨站表单（CSRF）直接解封/关自动屏蔽"""
    if request.method == "POST" and not request.is_json:
        return jsonify({"ok": False, "msg": "POST 需要 application/json"}), 415
    return None


@app.route("/api/stats")
def api_stats():
    return jsonify(build_stats())


@app.route("/api/unblock", methods=["POST"])
def api_unblock():
    data = request.get_json(silent=True) or {}
    ip = (data.get("ip") or "").strip()
    if not re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip):
        return jsonify({"ok": False, "msg": "IP 格式不正确"}), 400
    with LOCK:
        info = blocked.get(ip)
    if not info:
        return jsonify({"ok": False, "msg": "%s 当前未被封禁" % ip}), 404
    ok = release_block(ip, info["reason"], info["full"], why="面板手动解封")
    if not ok:
        return jsonify({"ok": False, "msg": "解封 %s 失败，规则可能已被删除，请查看日志" % ip}), 500
    return jsonify({"ok": True, "msg": "已解封 %s" % ip})


@app.route("/api/auto", methods=["POST"])
def api_auto():
    global AUTO_BLOCK
    data = request.get_json(silent=True) or {}
    val = data.get("enabled", None)
    if val is None:
        return jsonify({"ok": False, "msg": "缺少 enabled 参数"}), 400
    if not isinstance(val, bool):
        if hasattr(val, "lower"):                  # py2 的 unicode / py3 的 str
            val = val.lower() in ("1", "true", "on", "yes")
        else:
            val = bool(val)
    with LOCK:
        AUTO_BLOCK = bool(val)
    add_event("自动屏蔽已%s" % ("开启" if AUTO_BLOCK else "关闭"),
              "ok" if AUTO_BLOCK else "warn")
    return jsonify({"ok": True, "auto": AUTO_BLOCK})


# ============================================================================
#                          主入口
# ============================================================================

def check_root():
    if os.geteuid() != 0:
        print("[!] 请使用 root 运行（iptables + scapy 需要）")
        sys.exit(1)


def check_iptables():
    rc, out = run_cmd(["iptables", "-V"])
    if rc != 0:
        print("[!] iptables 不可用: %s" % out.strip())
        sys.exit(1)
    print("[*] %s" % out.strip().splitlines()[0])


def parse_args():
    import argparse
    p = argparse.ArgumentParser(description="DDoS 检测 / 自动封禁 / 审计面板 agent")
    p.add_argument("--iface", default=IFACE, help="嗅探网卡，默认自动探测")
    p.add_argument("--port", type=int, default=LISTEN_PORT, help="面板监听端口，默认 5000")
    p.add_argument("--syn-rate", type=float, default=SYN_RATE_TH, help="SYN 阈值 pps")
    p.add_argument("--udp-rate", type=float, default=UDP_RATE_TH, help="UDP 阈值 pps")
    p.add_argument("--http-rate", type=float, default=HTTP_RATE_TH, help="HTTP 阈值 req/s")
    p.add_argument("--scan-ports", type=int, default=SCAN_PORT_TH, help="扫描端口数阈值")
    p.add_argument("--brute", type=int, default=BRUTE_TH, help="SSH 失败阈值/60s")
    p.add_argument("--ttl", type=int, default=BLOCK_TTL, help="封禁时长（秒）")
    p.add_argument("--max-blocked", type=int, default=MAX_BLOCKED, help="封禁条数上限")
    p.add_argument("--no-auto", action="store_true", help="启动时关闭自动屏蔽")
    p.add_argument("--no-cleanup", action="store_true", help="启动时不清理残留 iptables 规则")
    p.add_argument("--panel", default=PANEL_FILE, help="面板 HTML 路径")
    return p.parse_args()


def _ensure_utf8_stdout():
    """LANG=C 时中文写 stdout 会 UnicodeEncodeError；换成 utf-8/replace 输出"""
    enc = (getattr(sys.stdout, "encoding", "") or "").lower()
    if enc in ("utf-8", "utf8"):
        return
    if hasattr(sys.stdout, "buffer"):
        try:
            sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8",
                                          errors="replace", line_buffering=True)
        except Exception:
            pass


def main():
    global IFACE, LISTEN_PORT, SYN_RATE_TH, UDP_RATE_TH, HTTP_RATE_TH
    global SCAN_PORT_TH, BRUTE_TH, BLOCK_TTL, MAX_BLOCKED, AUTO_BLOCK, PANEL_FILE

    _ensure_utf8_stdout()
    args = parse_args()
    IFACE = args.iface or detect_iface()
    LISTEN_PORT = args.port
    SYN_RATE_TH = args.syn_rate
    UDP_RATE_TH = args.udp_rate
    HTTP_RATE_TH = args.http_rate
    SCAN_PORT_TH = args.scan_ports
    BRUTE_TH = args.brute
    BLOCK_TTL = args.ttl
    MAX_BLOCKED = args.max_blocked
    PANEL_FILE = args.panel
    if args.no_auto:
        AUTO_BLOCK = False

    check_root()
    if not os.path.isdir(LOG_DIR):          # py2 无 os.makedirs(exist_ok=)
        os.makedirs(LOG_DIR)
    print("=" * 70)
    print(" DDoS 检测 agent 启动")
    print("  网卡     : %s" % IFACE)
    print("  面板     : http://%s:%d/  (文件: %s)" % (LISTEN_HOST, LISTEN_PORT, PANEL_FILE))
    print("  日志目录 : %s" % LOG_DIR)
    print("  白名单   : %s" % sorted(WHITELIST))
    if WHITELIST_NETS:
        print("  白名单网段: %s  (来自 %s)" % (sorted(str(n) for n in WHITELIST_NETS), WHITELIST_FILE))
    print("  阈值     : SYN>%s pps, UDP>%s pps, HTTP>%s rps, 扫描>%s 端口, SSH>%s 失败/60s"
          % (SYN_RATE_TH, UDP_RATE_TH, HTTP_RATE_TH, SCAN_PORT_TH, BRUTE_TH))
    print("  封禁     : TTL=%ss, 上限=%d, 每轮最多 %d 个新源" % (BLOCK_TTL, MAX_BLOCKED, MAX_NEW_PER_ROUND))
    print("=" * 70)

    if not args.no_cleanup:
        cleanup_rules()
    check_iptables()

    # 记录本次启动
    add_event("agent 启动，AUTO_BLOCK=%s" % AUTO_BLOCK)

    def _on_term(signum, frame):
        STOP.set()
        raise KeyboardInterrupt

    try:
        signal.signal(signal.SIGTERM, _on_term)
    except Exception:
        pass

    threads = []
    for target, name in ((sniff_worker, "sniff"), (nginx_worker, "nginx"),
                         (secure_worker, "secure"), (blocker_worker, "blocker")):
        th = threading.Thread(target=target, name=name)
        th.daemon = True           # py3.3+ 才支持构造参数 daemon=，py2 只能赋属性
        threads.append(th)
    for th in threads:
        th.start()

    try:
        app.run(host=LISTEN_HOST, port=LISTEN_PORT, threaded=True, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        pass
    finally:
        STOP.set()
        print("\n[*] 正在退出 ...")
        time.sleep(0.5)


if __name__ == "__main__":
    main()
