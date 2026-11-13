# -*- coding: utf-8 -*-
"""探测：LAN 客户端直连 192.168.1.137:25 无认证发信是否被 postfix 放行（仅 ASCII 输出）"""
import smtplib

s = smtplib.SMTP("192.168.1.137", 25, timeout=10)
msg = ("From: probe@ddzt.old\r\nTo: kk@ddzt.old\r\n"
       "Subject: SMTP relay probe\r\n\r\nprobe body\r\n")
try:
    s.sendmail("probe@ddzt.old", ["kk@ddzt.old"], msg)
    print("SMTP_RELAY_OK")
except Exception as e:
    print("SMTP_RELAY_FAIL", type(e).__name__, str(e)[:120])
s.quit()
