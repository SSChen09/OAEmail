# -*- coding: utf-8 -*-
"""从客户端/攻击端验证文件共享下载链路（下载 md5 与大小）。

用法:
    python test_clients.py                # 默认 client=192.168.3.155 attacker=192.168.3.153 server=192.168.3.152
    python test_clients.py <server> [client ...]
环境变量: SERVER_IP / CLIENT_IP / ATTACKER_IP 也可覆盖默认值。
"""
import os
import sys

import paramiko

SERVER = os.environ.get("SERVER_IP", "192.168.3.152")
CLIENTS = [os.environ.get("CLIENT_IP", "192.168.3.155"),
           os.environ.get("ATTACKER_IP", "192.168.3.153")]


def run(host, cmd):
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(host, 22, "root", "root", timeout=8,
                    allow_agent=False, look_for_keys=False)
    except Exception as e:
        return -1, "", "连接失败: %s" % e
    try:
        _i, out, err = cli.exec_command(cmd, timeout=30)
        rc = out.channel.recv_exit_status()
        return (rc,
                out.read().decode("utf-8", "replace").strip(),
                err.read().decode("utf-8", "replace").strip())
    finally:
        cli.close()


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else SERVER
    hosts = sys.argv[2:] or CLIENTS
    url = "http://%s/api/files.php?action=download&id=1" % server
    for host in hosts:
        print("=" * 12, host)
        rc, out, err = run(
            host,
            "curl -s -o /tmp/oa_dl.bin '%s' && md5sum /tmp/oa_dl.bin | awk '{print $1}'"
            " && stat -c %%s /tmp/oa_dl.bin" % url)
        print("download:", rc, out or err)
        rc, out, err = run(
            host,
            "curl -s -o /tmp/oa_dl2.bin '%s' -w 'code=%%{http_code} bytes=%%{size_download}'" % url)
        print("meta:", out or err)
    return 0


if __name__ == "__main__":
    sys.exit(main())
