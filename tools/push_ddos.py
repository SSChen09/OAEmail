# -*- coding: utf-8 -*-
"""上传 ddos/ 项目文件到各端 /root/test/ddos/（角色布局），并可一键执行部署脚本。

角色布局（用户约定：攻击端文件放 232、防护端文件放 137）:
  192.168.3.152 防护端(靶机) : ddos/target/  + ddos/common/  -> target/1_setup_target.sh
  192.168.3.153 攻击端       : ddos/attacker/+ ddos/common/  -> attacker/2_setup_attacker.sh
  192.168.3.155 管理机(客户端): ddos/admin/  + ddos/common/  -> admin/3_setup_admin.sh（仅连通性自检）

目录结构保持 ddos/ 原样（脚本用 ../common/ 相对引用），运行时部署到 /opt/ddos/。

用法:
  python tools/push_ddos.py <ip> --upload     # 仅上传
  python tools/push_ddos.py <ip>              # 上传 + 执行该端部署脚本
  python tools/push_ddos.py all --upload
  python tools/push_ddos.py all
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ssh_run import connect, run  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DDOS_DIR = os.path.join(ROOT, "ddos")
REMOTE_BASE = "/root/test/ddos"

HOSTS = {
    "192.168.3.152": {"dirs": ["target", "common"], "script": "target/1_setup_target.sh"},
    "192.168.3.153": {"dirs": ["attacker", "common"], "script": "attacker/2_setup_attacker.sh"},
    "192.168.3.155": {"dirs": ["admin", "common"], "script": "admin/3_setup_admin.sh"},
}

TEXT_EXTS = (".sh", ".md", ".py", ".html", ".conf", ".service", ".txt", ".json", ".jsonl")
SKIP_NAMES = {"__pycache__", "_testlog", ".DS_Store"}


def _upload_tree(sftp, local_dir, remote_dir):
    """递归上传目录（文本文件 CRLF->LF，防止弄坏远端 bash/python）"""
    try:
        sftp.stat(remote_dir)
    except IOError:
        sftp.mkdir(remote_dir)
    for name in sorted(os.listdir(local_dir)):
        if name in SKIP_NAMES:
            continue
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


def upload(ip):
    code, _out, err = run(ip, "mkdir -p %s" % REMOTE_BASE)
    if code != 0:
        print("[x] 创建目录失败 %s: %s" % (REMOTE_BASE, err.strip()))
        return False
    c = connect(ip)
    try:
        sftp = c.open_sftp()
        try:
            for d in HOSTS[ip]["dirs"]:
                _upload_tree(sftp, os.path.join(DDOS_DIR, d), REMOTE_BASE + "/" + d)
        finally:
            sftp.close()
    finally:
        c.close()
    return True


def deploy(ip):
    script = HOSTS[ip]["script"]
    remote = "%s/%s" % (REMOTE_BASE, script)
    # 先语法检查再执行；两者都必须看返回码，否则失败也打印成功
    code, _out, err = run(ip, 'bash -n "%s"' % remote, timeout=120)
    if code != 0:
        print("[x] 语法检查失败 %s: %s" % (ip, err.strip()[:500]))
        return False
    print("[run]", ip, "bash", remote)
    code, out, err = run(ip, "bash %s" % remote, timeout=1800)
    print(out)
    if err.strip():
        print("[stderr]", err.strip()[:2000])
    if code != 0:
        print("[x] 部署脚本失败 rc=%s" % code)
        return False
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]
    upload_only = "--upload" in sys.argv
    ips = list(HOSTS) if ip == "all" else [ip]
    failed = []
    for one in ips:
        if one not in HOSTS:
            print("未知主机:", one, "可选:", " ".join(HOSTS))
            sys.exit(1)
        print("=" * 60)
        print("HOST", one, "ROLE-SCRIPT", HOSTS[one]["script"])
        ok = upload(one)
        if ok and not upload_only:
            ok = deploy(one)
        if not ok:
            failed.append(one)
    if failed:
        print("[x] 失败主机：%s" % ", ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
