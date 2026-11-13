# -*- coding: utf-8 -*-
"""一键上传并执行各主机依赖安装脚本（依据 配置.md 角色映射）。

用法:
  python tools/push_deploy.py <ip>            # 上传 deploy/ 并执行该主机对应脚本
  python tools/push_deploy.py <ip> --check    # 上传后仅执行校验（脚本 --check）
  python tools/push_deploy.py <ip> --upload   # 仅上传不执行
  python tools/push_deploy.py 192.168.3.152 --oa    # 上传并部署 OA+邮件系统 (4_oa_mail_setup.sh)
  python tools/push_deploy.py all             # 三台依次 上传+执行
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ssh_run import connect, run  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPLOY_DIR = os.path.join(ROOT, "deploy")
OA_DIR = os.path.join(ROOT, "oa")
REMOTE_DIR = "/opt/deploy"
OA_REMOTE_DIR = REMOTE_DIR + "/oa"
ENV_FILE = os.path.join(ROOT, "netenv.json")

ROLE_SCRIPT = {"server": "1_server_deps.sh", "client": "2_client_deps.sh",
               "attacker": "3_attacker_deps.sh"}

# 角色映射（配置.md）: IP -> 该主机需要执行的一键依赖脚本
HOST_SCRIPT = {
    "192.168.3.152": "1_server_deps.sh",    # 服务端: OA + 邮件 + DDoS 防御
    "192.168.3.155": "2_client_deps.sh",    # 客户端: 浏览器访问 OA + 邮件
    "192.168.3.153": "3_attacker_deps.sh",  # 攻击端/备用客户端: DDoS 攻击 + 同客户端
}
# OA + 邮件系统部署脚本（仅服务端）
OA_SCRIPT = "4_oa_mail_setup.sh"
OA_HOST = "192.168.3.152"


def script_for(ip):
    """IP -> 部署脚本：先查静态表，再查 netenv.json 的角色（IP 变了也能对上）"""
    if ip in HOST_SCRIPT:
        return HOST_SCRIPT[ip]
    try:
        with open(ENV_FILE, "r", encoding="utf-8") as f:
            hosts = json.load(f).get("hosts", {})
    except (OSError, ValueError):
        return None
    for role, addr in hosts.items():
        if addr == ip:
            return ROLE_SCRIPT.get(role)
    return None

TEXT_EXTS = (".sh", ".md", ".php", ".html", ".css", ".js", ".json", ".conf", ".txt")


def _upload_tree(sftp, local_dir, remote_dir):
    """递归上传目录（文本文件 CRLF->LF，防止弄坏远端脚本/PHP）"""
    try:
        sftp.stat(remote_dir)
    except IOError:
        sftp.mkdir(remote_dir)
    for name in sorted(os.listdir(local_dir)):
        local = os.path.join(local_dir, name)
        remote = remote_dir + "/" + name
        if os.path.isdir(local):
            _upload_tree(sftp, local, remote)
            continue
        with open(local, "rb") as fh:
            data = fh.read()
        if name.endswith(TEXT_EXTS):
            data = data.replace(b"\r\n", b"\n")
        with sftp.open(remote, "wb") as rf:
            rf.write(data)
        print("[upload]", remote)


def upload(ip, with_oa=None):
    if with_oa is None:
        with_oa = (ip == OA_HOST)
    run(ip, "mkdir -p %s" % REMOTE_DIR)
    c = connect(ip)
    try:
        sftp = c.open_sftp()
        for f in sorted(os.listdir(DEPLOY_DIR)):
            if not f.endswith((".sh", ".md")):
                continue
            local = os.path.join(DEPLOY_DIR, f)
            with open(local, "rb") as fh:
                data = fh.read().replace(b"\r\n", b"\n")  # 防止 CRLF 弄坏 bash
            with sftp.open(REMOTE_DIR + "/" + f, "wb") as rf:
                rf.write(data)
            print("[upload]", ip + ":" + REMOTE_DIR + "/" + f)
        if with_oa and os.path.isdir(OA_DIR):
            _upload_tree(sftp, OA_DIR, OA_REMOTE_DIR)
        sftp.close()
    finally:
        c.close()
    code, _out, err = run(ip, "chmod +x %s/*.sh" % REMOTE_DIR)
    if code != 0:
        print("[!] chmod 失败：%s" % err.strip())
    return code == 0


def run_script(ip, check_only, script=None):
    script = script or script_for(ip)
    if not script:
        print("[x] 未知主机 %s：不在 HOST_SCRIPT，也不在 netenv.json 里" % ip)
        return 2
    cmd = "bash %s/%s%s" % (REMOTE_DIR, script, " --check" if check_only else "")
    print("[run]", ip, cmd)
    try:
        code, out, err = run(ip, cmd, timeout=1800)
    except Exception as e:  # noqa: BLE001 - 单台失败不应中断 all
        print("[x] 执行异常：%r" % (e,))
        return 1
    sys.stdout.write(out)
    if err.strip():
        sys.stderr.write("[stderr]\n" + err)
    print("[exit]", code)
    return code


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    target = sys.argv[1]
    opts = set(sys.argv[2:])
    check_only = "--check" in opts
    upload_only = "--upload" in opts
    use_oa = "--oa" in opts

    if use_oa:
        if target != OA_HOST:
            sys.exit("--oa 仅适用于服务端 " + OA_HOST)
        print("=" * 60)
        print("HOST", target, "ROLE-SCRIPT", OA_SCRIPT, "(OA + 邮件系统)")
        upload(target)
        if upload_only:
            return
        code = run_script(target, check_only, script=OA_SCRIPT)
        sys.exit(0 if code == 0 else 1)

    ips = list(HOST_SCRIPT) if target == "all" else [target]
    failed = []
    for ip in ips:
        print("=" * 60)
        print("HOST", ip, "ROLE-SCRIPT", script_for(ip) or "(未知)")
        try:
            ok = upload(ip)
        except Exception as e:  # noqa: BLE001
            print("[x] 上传失败：%r" % (e,))
            ok = False
        if upload_only:
            if not ok:
                failed.append(ip)
            continue
        code = run_script(ip, check_only) if ok else 1
        if code != 0:
            failed.append(ip)
    if failed:
        print("[x] 失败主机：%s" % ", ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
