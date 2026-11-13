# -*- coding: utf-8 -*-
"""上传 ddos/ 项目文件到各端 /root/test/ddos/（角色布局），并可一键执行部署脚本。

角色布局（用户约定：攻击端文件放 232、防护端文件放 137）:
  192.168.1.137 防护端(靶机) : ddos/target/  + ddos/common/  -> target/1_setup_target.sh
  192.168.1.232 攻击端       : ddos/attacker/+ ddos/common/  -> attacker/2_setup_attacker.sh
  192.168.1.130 管理机(客户端): ddos/admin/  + ddos/common/  -> admin/3_setup_admin.sh（仅连通性自检）

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
    "192.168.1.137": {"dirs": ["target", "common"], "script": "target/1_setup_target.sh"},
    "192.168.1.232": {"dirs": ["attacker", "common"], "script": "attacker/2_setup_attacker.sh"},
    "192.168.1.130": {"dirs": ["admin", "common"], "script": "admin/3_setup_admin.sh"},
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
    c = connect(ip)
    try:
        sftp = c.open_sftp()
        try:
            sftp.stat(REMOTE_BASE)
        except IOError:
            sftp.mkdir(REMOTE_BASE)  # /root/test 已存在（依赖脚本阶段建好）
        for d in HOSTS[ip]["dirs"]:
            _upload_tree(sftp, os.path.join(DDOS_DIR, d), REMOTE_BASE + "/" + d)
        sftp.close()
    finally:
        c.close()


def deploy(ip):
    script = HOSTS[ip]["script"]
    remote = "%s/%s" % (REMOTE_BASE, script)
    # 先语法检查再执行
    run(ip, 'bash -n "%s" && echo SYNTAX_OK' % remote)
    print("[run]", ip, "bash", remote)
    out = run(ip, "bash %s" % remote)
    print(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ip = sys.argv[1]
    upload_only = "--upload" in sys.argv
    ips = list(HOSTS) if ip == "all" else [ip]
    for one in ips:
        if one not in HOSTS:
            print("未知主机:", one, "可选:", " ".join(HOSTS))
            sys.exit(1)
        print("=" * 60)
        print("HOST", one, "ROLE-SCRIPT", HOSTS[one]["script"])
        upload(one)
        if not upload_only:
            deploy(one)


if __name__ == "__main__":
    main()
