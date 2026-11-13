# -*- coding: utf-8 -*-
"""SSH 小工具：用 paramiko 以 root/root 登录实验机执行命令或上传文件。

用法:
  python tools/ssh_run.py <ip> run  "<命令>"            # 执行远程命令，打印 stdout/stderr/exit
  python tools/ssh_run.py <ip> put  <本地文件> <远程路径> # SFTP 上传
  python tools/ssh_run.py <ip> putd <本地目录>  <远程目录> # 递归上传目录
  python tools/ssh_run.py probe 192.168.1.130 192.168.1.137 ...  # 批量探测系统信息
"""
import os
import sys
import stat
import paramiko

USER = "root"
PASS = "root"
TIMEOUT = 30


def connect(ip):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip, 22, USER, PASS, timeout=TIMEOUT, allow_agent=False, look_for_keys=False)
    return c


def run(ip, cmd, timeout=600):
    c = connect(ip)
    try:
        stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        code = stdout.channel.recv_exit_status()
        return code, out, err
    finally:
        c.close()


def put(ip, local, remote):
    c = connect(ip)
    try:
        sftp = c.open_sftp()
        sftp.put(local, remote)
        sftp.close()
    finally:
        c.close()


def put_dir(ip, local, remote):
    c = connect(ip)
    try:
        sftp = c.open_sftp()
        try:
            sftp.stat(remote)
        except IOError:
            sftp.mkdir(remote)
        for root, dirs, files in os.walk(local):
            rel = os.path.relpath(root, local).replace("\\", "/")
            rdir = remote if rel == "." else remote + "/" + rel
            for d in dirs:
                try:
                    sftp.stat(rdir + "/" + d)
                except IOError:
                    sftp.mkdir(rdir + "/" + d)
            for f in files:
                sftp.put(os.path.join(root, f), rdir + "/" + f)
        sftp.close()
    finally:
        c.close()


PROBE = (
    "echo ===HOST===; hostname; "
    "cat /etc/os-release 2>/dev/null | head -4; "
    "uname -r; "
    "echo ===MGR===; "
    "(command -v dnf && echo HAS_DNF); (command -v yum && echo HAS_YUM); (command -v apt && echo HAS_APT); "
    "echo ===PY===; python3 --version 2>&1; python --version 2>&1; "
    "echo ===NET===; ip -o -4 addr show 2>/dev/null | awk '{print $2, $4}'; "
    "echo ===DISK===; df -h / | tail -1"
)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "probe":
        for ip in sys.argv[2:]:
            print("########", ip)
            try:
                code, out, err = run(ip, PROBE)
                print(out)
                if err.strip():
                    print("[stderr]", err.strip())
                print("[exit]", code)
            except Exception as e:
                print("[connect-fail]", repr(e))
        return
    ip, action = sys.argv[1], sys.argv[2]
    if action == "run":
        code, out, err = run(ip, sys.argv[3])
        sys.stdout.write(out)
        if err.strip():
            sys.stderr.write("[stderr]\n" + err)
        print("[exit]", code)
    elif action == "put":
        put(ip, sys.argv[3], sys.argv[4])
        print("uploaded", sys.argv[3], "->", ip + ":" + sys.argv[4])
    elif action == "putd":
        put_dir(ip, sys.argv[3], sys.argv[4])
        print("uploaded dir", sys.argv[3], "->", ip + ":" + sys.argv[4])
    else:
        sys.exit("unknown action: " + action)


if __name__ == "__main__":
    main()
