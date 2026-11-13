#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
 net_sync.py —— IP 变化后的一键自适应工具（Windows 侧运行）
==============================================================================
 用途:
   三台靶场机器用 DHCP，IP 随时可能变。本工具会：
     1) 扫描内网网段，找出开放 SSH 的主机
     2) 用 root/root 登录，读 /etc/ddzt-role 识别「服务端/客户端/攻击端」角色
     3) 把新 IP 写回仓库（agent.py 白名单、attacker.py、deploy 脚本、tools 映射、文档…）
     4) 远程刷新三台的 /etc/hosts、靶机白名单文件、攻击端目标文件，并重启防护服务
   之后只需按提示重跑部署脚本（或直接开测）。

 用法:
   python tools\\net_sync.py                    # 只探测 + 打印变更计划（不动任何东西）
   python tools\\net_sync.py --apply            # 探测 + 改仓库 + 改三台机器
   python tools\\net_sync.py --apply --no-remote # 只改 Windows 侧仓库
   python tools\\net_sync.py --subnet 192.168.4.0/24   # 指定网段（默认读 netenv.json）
   python tools\\net_sync.py --map server=192.168.4.11,client=192.168.4.12,attacker=192.168.4.13
   python tools\\net_sync.py --ignore 192.168.3.155      # 跳过网段里的第四台机器

 前提:
   - 三台机器已部署过仓库脚本（/etc/ddzt-role 由部署脚本写入；缺失时按已装组件推断）
   - Windows 能访问该网段，pip install paramiko
==============================================================================
"""

import argparse
import base64
import ipaddress
import json
import os
import re
import socket
import sys
from concurrent.futures import ThreadPoolExecutor

try:
    import paramiko
except ImportError:  # pragma: no cover - 仅远程操作需要，dry-run 不依赖
    paramiko = None


def _ssh_mod():
    if paramiko is None:
        sys.exit("[!] 需要 paramiko：pip install paramiko")
    return paramiko

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_FILE = os.path.join(ROOT, "netenv.json")
ROLES = ("server", "client", "attacker")
ROLE_CN = {"server": "服务端/靶机", "client": "客户端/管理机", "attacker": "攻击端"}
TEXT_EXT = {".py", ".sh", ".md", ".json", ".html", ".conf", ".txt", ".service", ".cfg", ".ini", ".yml", ".yaml"}
SKIP_DIRS = {".git", "__pycache__", ".idea", ".vscode", "node_modules"}

PROBE_CMD = (
    'ROLE=$(cat /etc/ddzt-role 2>/dev/null | head -1); HN=$(hostname); '
    'A=no; B=no; [ -f /opt/ddos/agent.py ] && A=yes; [ -f /opt/ddos/attacker.py ] && B=yes; '
    'echo "ROLE=$ROLE;HN=$HN;AGENT=$A;ATTACKER=$B"'
)


# ----------------------------------------------------------------------------
# 配置读写
# ----------------------------------------------------------------------------
def load_env():
    with open(ENV_FILE, "r", encoding="utf-8") as f:
        env = json.load(f)
    hosts = env.setdefault("hosts", {})
    for r in ROLES:
        hosts.setdefault(r, "")
    env.setdefault("subnet", "")
    env.setdefault("ssh", {"user": "root", "password": "root", "port": 22})
    env.setdefault("domains", ["ddzt.old", "mail.ddzt.old", "www.ddzt.old", "oa.ddzt.old"])
    return env


def save_env(env):
    with open(ENV_FILE, "w", encoding="utf-8", newline="\n") as f:
        json.dump(env, f, ensure_ascii=False, indent=2)
        f.write("\n")


# ----------------------------------------------------------------------------
# 网络探测
# ----------------------------------------------------------------------------
def tcp_open(ip, port=22, timeout=0.4):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def scan_subnet(subnet, workers=64, timeout=0.4):
    net = ipaddress.ip_network(subnet, strict=False)
    ips = [str(h) for h in net.hosts()]
    print("[*] 扫描 %s（%d 个地址，探测 22 端口）..." % (subnet, len(ips)))
    with ThreadPoolExecutor(max_workers=workers) as ex:
        flags = list(ex.map(lambda ip: tcp_open(ip, 22, timeout), ips))
    alive = [ip for ip, ok in zip(ips, flags) if ok]
    print("[*] 发现 %d 台开放 SSH：%s" % (len(alive), ", ".join(alive) or "无"))
    return alive


def ssh_connect(ip, cfg, timeout=4):
    mod = _ssh_mod()
    cli = mod.SSHClient()
    cli.set_missing_host_key_policy(mod.AutoAddPolicy())
    cli.connect(ip, port=int(cfg.get("port", 22)), username=cfg.get("user", "root"),
                password=cfg.get("password", "root"), timeout=timeout,
                allow_agent=False, look_for_keys=False)
    return cli


def ssh_run(cli, cmd, timeout=15):
    try:
        _, out, err = cli.exec_command(cmd, timeout=timeout)
        return out.channel.recv_exit_status(), out.read().decode("utf-8", "ignore").strip(), \
            err.read().decode("utf-8", "ignore").strip()
    except Exception as e:  # noqa: BLE001 - 网络异常统一降级为返回码 -1
        return -1, "", str(e)


def detect_role(ip, cfg):
    """登录并返回 (role, hostname, info)；role 可能为 None（无法判定）"""
    try:
        cli = ssh_connect(ip, cfg)
    except Exception as e:  # noqa: BLE001
        print("    [!] %s 登录失败：%s" % (ip, e))
        return None, "", {}
    try:
        rc, out, err = ssh_run(cli, PROBE_CMD)
        info = {}
        for kv in out.split(";"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                info[k.strip()] = v.strip()
        role = (info.get("ROLE") or "").lower()
        hostname = info.get("HN", "")
        if role not in ROLES:
            role = None
            if info.get("AGENT") == "yes":
                role = "server"
            elif info.get("ATTACKER") == "yes":
                role = "attacker"
            elif "client" in hostname.lower() or "admin" in hostname.lower():
                role = "client"
        print("    [>] %-15s hostname=%-16s role=%s" % (ip, hostname or "?",
                                                       role or "无法判定"))
        return role, hostname, info
    finally:
        cli.close()


def discover(subnet, cfg, workers, ignore=None, timeout=0.4):
    ignore = ignore or set()
    alive = scan_subnet(subnet, workers=workers, timeout=timeout)
    skipped = [ip for ip in alive if ip in ignore]
    if skipped:
        print("[i] 按 --ignore 跳过：%s" % ", ".join(skipped))
    alive = [ip for ip in alive if ip not in ignore]
    found = {}
    for ip in alive:
        role, hostname, info = detect_role(ip, cfg)
        if role and role in found:
            print("    [!] 角色 %s 重复（%s 与 %s），请用 --map 手工指定"
                  % (role, found[role][0], ip))
            continue
        if role:
            found[role] = (ip, hostname, info)
    return found


# ----------------------------------------------------------------------------
# 仓库文件改写
# ----------------------------------------------------------------------------
def iter_text_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            if os.path.splitext(name)[1].lower() not in TEXT_EXT:
                continue
            if name == "netenv.json":
                continue
            yield os.path.join(dirpath, name)


def _ip_pattern(ip):
    """整 IP 匹配：前后不能紧邻数字或点，避免 192.168.3.15 改到 192.168.3.155 里"""
    return re.compile(r"(?<![\d.])" + re.escape(ip) + r"(?![\d.])")


def _replacement_plan(old_hosts, new_hosts, old_subnet, new_subnet):
    pairs = [(old_hosts[r], new_hosts[r]) for r in ROLES
             if old_hosts.get(r) and new_hosts.get(r) and old_hosts[r] != new_hosts[r]]
    pfx = None
    if old_subnet and new_subnet and old_subnet != new_subnet:
        old_pfx = old_subnet.split("/")[0].rsplit(".", 1)[0] + "."
        new_pfx = new_subnet.split("/")[0].rsplit(".", 1)[0] + "."
        if old_pfx != new_pfx:
            pfx = (re.compile(r"(?<![\d.])" + re.escape(old_pfx)), new_pfx)
    return pairs, pfx


def _rewrite_text(text, pairs, pfx):
    for old, new in pairs:
        text = _ip_pattern(old).sub(new, text)
    if pfx:
        text = pfx[0].sub(pfx[1], text)
    return text


def plan_repo_changes(old_hosts, new_hosts, old_subnet, new_subnet):
    """返回 {文件: 替换次数}，不写盘"""
    pairs, pfx = _replacement_plan(old_hosts, new_hosts, old_subnet, new_subnet)
    if not pairs and not pfx:
        return {}
    hits = {}
    for path in iter_text_files():
        try:
            with open(path, "r", encoding="utf-8", newline="") as f:
                text = f.read()
        except (UnicodeDecodeError, OSError):
            continue
        n = 0
        for old, _new in pairs:
            n += len(_ip_pattern(old).findall(text))
        if pfx:
            n += len(pfx[0].findall(text))
        if n:
            hits[path] = n
    return hits


def apply_repo_changes(old_hosts, new_hosts, old_subnet, new_subnet):
    hits = plan_repo_changes(old_hosts, new_hosts, old_subnet, new_subnet)
    pairs, pfx = _replacement_plan(old_hosts, new_hosts, old_subnet, new_subnet)
    failed = []
    for path in hits:
        try:
            with open(path, "r", encoding="utf-8", newline="") as f:
                text = f.read()
            new_text = _rewrite_text(text, pairs, pfx)
            tmp = path + ".netsync.tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as f:
                f.write(new_text)
            os.replace(tmp, path)          # 原子替换：中断不会留下半截文件
        except OSError as e:
            failed.append("%s: %s" % (os.path.relpath(path, ROOT), e))
            try:
                os.unlink(path + ".netsync.tmp")
            except OSError:
                pass
    return hits, failed


# ----------------------------------------------------------------------------
# 远程落地
# ----------------------------------------------------------------------------
def remote_hosts(cli, env, server_ip):
    domains = " ".join(env.get("domains") or ["ddzt.old"])
    cmd = ("sed -i '/ddzt\\.old/d' /etc/hosts; "
           "printf '%%s %s\\n' %s >> /etc/hosts; "
           "grep -n 'ddzt' /etc/hosts") % (domains, server_ip)
    rc, out, err = ssh_run(cli, cmd)
    return rc == 0, out or err


def remote_write(cli, path, content):
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    cmd = "install -d %s; echo %s | base64 -d > %s" % (os.path.dirname(path), b64, path)
    rc, out, err = ssh_run(cli, cmd)
    return rc == 0, out or err


def remote_apply(env, restart=True):
    cfg = env["ssh"]
    server_ip = env["hosts"]["server"]
    results = {}
    for role in ROLES:
        ip = env["hosts"].get(role)
        if not ip:
            continue
        print("[*] 同步 %s(%s) ..." % (ROLE_CN[role], ip))
        try:
            cli = ssh_connect(ip, cfg)
        except Exception as e:  # noqa: BLE001
            results[role] = False
            print("    [!] 登录失败：%s" % e)
            continue
        try:
            ok, msg = remote_hosts(cli, env, server_ip)
            print("    [%s] /etc/hosts -> %s" % ("OK" if ok else "X", server_ip))
            # 顺手补齐角色标记：客户端经常没跑过 deps 脚本，缺了它下次扫描会
            # 显示 "role=无法判定"，只能靠 --map 手工指定
            okm, _ = remote_write(cli, "/etc/ddzt-role", role + "\n")
            print("    [%s] /etc/ddzt-role = %s" % ("OK" if okm else "X", role))
            ok = ok and okm
            if role == "server":
                # 合并旧白名单而不是整文件覆盖：手工加过的 CIDR / 第四台机器不会被抹掉
                _, old_wl, _ = ssh_run(cli, "cat /etc/ddos/whitelist.txt 2>/dev/null")
                merged = []
                for item in [env["hosts"][r] for r in ROLES if env["hosts"].get(r)] + \
                        [ln.strip() for ln in (old_wl or "").splitlines()
                         if ln.strip() and not ln.strip().startswith("#")]:
                    if item not in merged:
                        merged.append(item)
                wl = "# 由 tools/net_sync.py 维护；每行一个 IP 或 CIDR\n"
                wl += "\n".join(merged) + "\n"
                ok2, msg2 = remote_write(cli, "/etc/ddos/whitelist.txt", wl)
                print("    [%s] /etc/ddos/whitelist.txt" % ("OK" if ok2 else "X"))
                if restart:
                    rc, out, err = ssh_run(cli, "systemctl restart ddos-agent && sleep 2 && systemctl is-active ddos-agent")
                    print("    [%s] ddos-agent 重启：%s" % ("OK" if rc == 0 else "X", (out or err)[:120]))
                    ok = ok and ok2 and rc == 0
                else:
                    ok = ok and ok2
            elif role == "attacker":
                ok2, _ = remote_write(cli, "/etc/ddos/target", server_ip + "\n")
                print("    [%s] /etc/ddos/target -> %s" % ("OK" if ok2 else "X", server_ip))
                # 兼容旧版包装脚本（把烧死的 --target IP 改成新靶机）
                ssh_run(cli, "sed -i -E 's#--target [0-9][0-9.]*#--target %s#' /usr/local/bin/ddos-attack 2>/dev/null" % server_ip)
                ok = ok and ok2
            results[role] = ok
        finally:
            cli.close()
    return results


def verify_panel(server_ip, timeout=5):
    """从 Windows 侧确认面板可达（服务端 IP 变更后的最终验证）"""
    import urllib.request
    try:
        with urllib.request.urlopen("http://%s:5000/api/stats" % server_ip, timeout=timeout) as r:
            data = json.load(r)
        return True, "auto=%s blocked=%d" % (data.get("auto"), len(data.get("blocked") or []))
    except Exception as e:  # noqa: BLE001
        return False, str(e)


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
def parse_ignore(spec):
    """'a,b;c' -> {'a','b','c'}：扫描时跳过的地址（第四台机器/NAS 等）"""
    return {s.strip() for s in (spec or "").replace(";", ",").split(",") if s.strip()}


def parse_map(spec):
    m = {}
    bad = []
    for part in (spec or "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            k, v = k.strip(), v.strip()
            if k not in ROLES:
                continue
            try:
                ipaddress.ip_address(v)
            except ValueError:
                bad.append("%s=%s" % (k, v))
                continue
            m[k] = v
    if bad:
        print("[x] --map 的值不是合法 IP：%s" % ", ".join(bad))
    return m, bad


def main():
    ap = argparse.ArgumentParser(description="IP 变化后自动同步靶场三台机器与仓库配置")
    ap.add_argument("--subnet", default="", help="扫描网段，默认取 netenv.json 的 subnet")
    ap.add_argument("--map", default="", help="跳过探测，直接指定 server=IP,client=IP,attacker=IP")
    ap.add_argument("--ignore", default="",
                    help="扫描时跳过这些地址（逗号分隔），如 --ignore 192.168.3.155")
    ap.add_argument("--apply", action="store_true", help="真正执行修改（默认只打印计划）")
    ap.add_argument("--no-remote", action="store_true", help="只改 Windows 侧仓库，不动三台机器")
    ap.add_argument("--no-repo", action="store_true", help="只同步三台机器，不改仓库文件")
    ap.add_argument("--no-restart", action="store_true", help="不重启 ddos-agent")
    ap.add_argument("--workers", type=int, default=64, help="扫描并发数")
    ap.add_argument("--timeout", type=float, default=0.4, help="单地址 TCP 探测超时（秒）")
    ap.add_argument("--allow-stale", action="store_true",
                    help="允许沿用未探测到的角色旧 IP（默认直接中止，避免把配置写到错误的机器）")
    args = ap.parse_args()

    env = load_env()
    old_hosts = dict(env["hosts"])
    old_subnet = env.get("subnet", "")

    print("=" * 72)
    print(" 当前记录：")
    for r in ROLES:
        print("   %-9s %s" % (r, old_hosts.get(r) or "(未记录)"))
    print(" 网段    : %s" % (old_subnet or "(未记录)"))
    print("=" * 72)

    # ---------- 1) 确定新 IP ----------
    manual, bad = parse_map(args.map)
    if bad:
        return 2
    new_hosts = dict(old_hosts)
    new_hosts.update(manual)
    confirmed = set(manual)          # 这些角色的 IP 是本次明确确认过的

    missing_roles = [r for r in ROLES if not manual.get(r)]
    if missing_roles:
        subnet = args.subnet or old_subnet or ""
        if not subnet:
            srv = old_hosts.get("server")
            if not srv:
                print("[x] 未记录旧 IP，请用 --subnet 指定扫描网段（如 10.0.0.0/24），"
                      "或用 --map 直接指定三台 IP")
                return 2
            subnet = ".".join(srv.split(".")[:3]) + ".0/24"
        try:
            net = ipaddress.ip_network(subnet, strict=False)
        except ValueError as e:
            print("[x] 网段不合法：%s（%s）" % (subnet, e))
            return 2
        if net.num_addresses > 4096:
            print("[x] 网段太大（%d 个地址），请用 /20 或更小的网段" % net.num_addresses)
            return 2
        found = discover(subnet, env["ssh"], args.workers, parse_ignore(args.ignore),
                         timeout=args.timeout)
        for r in missing_roles:
            if r in found:
                new_hosts[r] = found[r][0]
                confirmed.add(r)
                print("   -> %-9s = %s (%s)" % (r, found[r][0], found[r][1]))

    stale = [r for r in ROLES if r not in confirmed and new_hosts.get(r)]
    if stale:
        print("[!] 以下角色本次未探测到，将沿用旧 IP：%s" % ", ".join(
            "%s=%s" % (r, new_hosts[r]) for r in stale))
        if not args.allow_stale:
            print("[x] 为避免把白名单/hosts 写到错误的机器，已中止。")
            print("    确认这些机器 IP 没变，加 --allow-stale 继续；")
            print("    或用 --map %s" % ",".join("%s=<IP>" % r for r in stale))
            return 2

    if new_hosts.get("server"):
        new_subnet = ".".join(new_hosts["server"].split(".")[:3]) + ".0/24"
    else:
        new_subnet = old_subnet

    lacking = [r for r in ROLES if not new_hosts.get(r)]
    if lacking:
        print("[x] 未能确定角色：%s" % ", ".join(lacking))
        print("    请手工指定：--map server=IP,client=IP,attacker=IP")
        return 2

    changed = any(new_hosts[r] != old_hosts.get(r) for r in ROLES)
    print("-" * 72)
    for r in ROLES:
        mark = "*" if new_hosts[r] != old_hosts.get(r) else " "
        print(" %s %-9s %-15s -> %s" % (mark, r, old_hosts.get(r) or "-", new_hosts[r]))
    print("-" * 72)
    if not changed and new_subnet == old_subnet:
        print("[=] IP 未变化，无需同步。可直接执行部署校验。")
        return 0

    # ---------- 2) 打印/执行仓库改写 ----------
    hits = plan_repo_changes(old_hosts, new_hosts, old_subnet, new_subnet)
    print("[*] 仓库待改文件 %d 个：" % len(hits))
    for p in sorted(hits):
        print("     %s  (%d 处)" % (os.path.relpath(p, ROOT), hits[p]))

    if not args.apply:
        print("\n[i] 以上为 dry-run。加 --apply 真正执行（改仓库 + 同步三台机器）。")
        return 0

    if not args.no_repo:
        hits, failed = apply_repo_changes(old_hosts, new_hosts, old_subnet, new_subnet)
        if failed:
            for msg in failed:
                print("[X] 仓库文件写入失败：%s" % msg)
            print("[X] 已中止，未改远端（避免仓库与机器配置不一致）")
            return 1
        env["hosts"] = new_hosts
        env["subnet"] = new_subnet
        save_env(env)
        print("[OK] 仓库配置已更新（%d 个文件），netenv.json 已记录新 IP" % len(hits))
    else:
        env["hosts"] = new_hosts
        env["subnet"] = new_subnet

    # ---------- 3) 远程落地 ----------
    remote_failed = []
    if not args.no_remote:
        res = remote_apply(env, restart=not args.no_restart)
        for r in ROLES:
            print("[%s] %-9s %s" % ("OK" if res.get(r) else "X", r, new_hosts[r]))
            if not res.get(r):
                remote_failed.append(r)
        ok, detail = verify_panel(new_hosts["server"])
        print("[%s] 面板验证：%s" % ("OK" if ok else "X", detail))

    # ---------- 4) 后续动作提示 ----------
    print("""
=========== 同步完成，后续动作 ===========
 1) 重新上传仓库到三台（本机仓库已更新）：
      python tools\\push_deploy.py all --upload
      python tools\\push_ddos.py %s --upload
      python tools\\push_ddos.py %s --upload
      python tools\\push_ddos.py %s --upload
 2) 若改了 agent.py / attacker.py / 部署脚本，按新 IP 重跑：
      服务端: bash /opt/deploy/1_setup_target.sh  (+ /opt/deploy/4_oa_mail_setup.sh)
      攻击端: bash /opt/deploy/2_setup_attacker.sh
      客户端: bash /root/test/2_client_deps.sh
 3) 开测：客户端浏览器 http://ddzt.old/  →  攻击端 ddos-attack dry-run
==========================================
""" % (new_hosts["server"], new_hosts["client"], new_hosts["attacker"]))
    if remote_failed:
        print("[X] 以下角色同步失败：%s" % ", ".join(remote_failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
