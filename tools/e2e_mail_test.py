# -*- coding: utf-8 -*-
"""从客户端 192.168.1.130 经 webmail API 做邮件系统端到端验收：
   未登录判定 -> eva 登录 -> 收件箱 -> 读信 -> 发信给 kk -> kk 收到 -> 删除
"""
import time
import requests

BASE = "http://ddzt.old/api/mail.php"

s1 = requests.Session()   # eva
s2 = requests.Session()   # kk


def call(s, action, **kw):
    r = s.post(BASE, data=dict(action=action, **kw), timeout=10)
    return r.json()


# 1. 未登录 me 应为 ok:false
j = call(s1, "me")
assert j["ok"] is False, j
print("[1] 未登录判定 OK")

# 2. eva 登录
j = call(s1, "login", username="eva@ddzt.old", password="eva")
assert j["ok"], j
print("[2] eva 登录 OK:", j["data"]["user"])

# 3. 收件箱非空（含示例邮件）
j = call(s1, "list")
assert j["ok"] and len(j["data"]["messages"]) > 0, j
msgs = j["data"]["messages"]
print("[3] eva 收件箱 %d 封, 最新: %s" % (len(msgs), msgs[0]["subject"]))

# 4. 读最新一封
j = call(s1, "read", uid=msgs[0]["uid"])
assert j["ok"] and j["data"]["body_text"], j
print("[4] 读信 OK, 正文开头: %r" % j["data"]["body_text"][:24])

# 5. eva -> kk 发信
subj = "端到端测试 %d" % int(time.time())
j = call(s1, "send", to="kk@ddzt.old", subject=subj,
         body="这是客户端 130 通过 OA 邮件模块发出的测试邮件。\n-- e2e test")
assert j["ok"], j
print("[5] 发信 OK:", subj)
time.sleep(2)

# 6. kk 登录应收到该邮件
j = call(s2, "login", username="kk@ddzt.old", password="kk")
assert j["ok"], j
j = call(s2, "list")
assert j["ok"], j
hit = [m for m in j["data"]["messages"] if m["subject"] == subj]
assert hit, [m["subject"] for m in j["data"]["messages"]]
print("[6] kk 收到测试邮件 OK (uid=%d)" % hit[0]["uid"])

# 7. kk 删除该邮件
j = call(s2, "delete", uid=hit[0]["uid"])
assert j["ok"], j
j = call(s2, "list")
assert j["ok"] and not [m for m in j["data"]["messages"] if m["subject"] == subj], j
print("[7] 删除 OK")

print("E2E_MAIL_TEST_ALL_PASS")
