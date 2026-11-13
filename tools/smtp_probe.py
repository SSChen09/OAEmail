# -*- coding: utf-8 -*-
"""探测：LAN 客户端直连 <server>:25 无认证发信是否被 postfix 放行（仅 ASCII 输出）

判定方法：给「外部域」发信（relay 测试）。postfix 默认只允许 mynetworks 与认证用户
relay，外部域应被 554 拒绝；若能投递成功，说明成了开放中继。

用法:
  python tools/smtp_probe.py [server_ip] [外域收件人]
"""
import smtplib
import sys


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.3.152"
    rcpt = sys.argv[2] if len(sys.argv) > 2 else "probe@example.com"
    try:
        s = smtplib.SMTP(host, 25, timeout=10)
    except Exception as e:  # noqa: BLE001
        print("PROBE_SMTP_UNREACHABLE", type(e).__name__, str(e)[:120])
        return 2
    msg = ("From: probe@ddzt.old\r\nTo: %s\r\n"
           "Subject: SMTP relay probe\r\n\r\nprobe body\r\n" % rcpt)
    try:
        code, detail = s.ehlo()
        s.mail("probe@ddzt.old")
        code, detail = s.rcpt(rcpt)
        if code // 100 == 2:
            s.data(msg)
            print("PROBE_RELAY_OPEN（可从 %s 无认证中继到 %s，需收紧 mynetworks）" % (host, rcpt))
            return 1
        print("PROBE_RELAY_DENIED（%s 拒绝中继 %s：%s %s）" % (host, rcpt, code, detail))
        return 0
    except Exception as e:  # noqa: BLE001
        print("PROBE_RELAY_ERROR", type(e).__name__, str(e)[:120])
        return 2
    finally:
        try:
            s.quit()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    sys.exit(main())
