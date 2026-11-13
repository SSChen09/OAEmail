# -*- coding: utf-8 -*-
"""文件共享/服务端体检（服务端存储、PHP 错误日志、下载响应头、客户端下载链路）。

用法: python final_check.py [server_ip] [client_ip ...]
默认: server=192.168.3.152 client=192.168.3.155 attacker=192.168.3.153
环境变量 SERVER_IP / CLIENT_IP / ATTACKER_IP 可覆盖。
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
        return -1, "连接失败: %s" % e, ""
    try:
        _i, out, err = cli.exec_command(cmd, timeout=30)
        rc = out.channel.recv_exit_status()
        return (rc,
                out.read().decode("utf-8", "replace").strip(),
                err.read().decode("utf-8", "replace").strip())
    finally:
        cli.close()


SQL_CMD = (
    "sqlite3 /var/www/oa-share/data/files.sqlite "
    "'select id,name,size,type,uploader from files;' 2>&1 || "
    "php -r '$p=new PDO(\"sqlite:/var/www/oa-share/data/files.sqlite\");"
    "foreach($p->query(\"select id,name,size,type,uploader from files\") as $r) "
    "echo implode(\" | \",[$r[0],$r[1],$r[2],$r[3],$r[4]]),PHP_EOL;'"
)


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else SERVER
    hosts = sys.argv[2:] or CLIENTS

    print("### %s 服务端检查" % server)
    for cmd in [
        "ls -l /var/www/oa-share/files",
        SQL_CMD,
        "tail -n 8 /var/log/php-fpm/www-error.log 2>/dev/null || "
        "tail -n 8 /var/log/php-fpm/error.log 2>/dev/null || echo no-log",
        "curl -s -I 'http://127.0.0.1/api/files.php?action=download&id=2' | sed -n '1,6p'",
        "df -h /var/www | tail -1",
    ]:
        print("---", cmd[:60])
        print(run(server, cmd)[1][:900])

    for host in hosts:
        print("###", host)
        print(run(
            host,
            "curl -s -o /tmp/demo.txt 'http://%s/api/files.php?action=download&id=2' "
            "-w 'code=%%{http_code} bytes=%%{size_download}' && echo && head -c 60 /tmp/demo.txt"
            % server)[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
