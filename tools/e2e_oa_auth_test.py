#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OA 账号登录接口端到端验收（oa/api/auth.php）

覆盖：
  * 未登录 me -> 401
  * 错误密码 / 不存在的账号 -> 401
  * 仅接受邮箱账号：短账号 eva、外域 eva@example.com 一律 401
  * eva@ddzt.old/rei、kk@ddzt.old/zmjjkk、admin@ddzt.old/admin 登录成功，me 返回同一邮箱与角色
  * 登录 OA 后同一会话访问 mail.php?action=me 已自动关联对应邮箱
  * 退出后 me -> 401，邮箱会话同时失效
  * login 只允许 POST（GET -> 405）
  * 文档中心写权限：未登录上传/删除 401；eva 上传/删除 403；admin 上传/删除 200

用法：
    python tools/e2e_oa_auth_test.py [http://ddzt.old/api/auth.php]
"""

import sys

import requests

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://ddzt.old/api/auth.php"
MAIL_BASE = BASE.rsplit("/", 1)[0] + "/mail.php"
FILES_BASE = BASE.rsplit("/", 1)[0] + "/files.php"
ACCOUNTS = [
    ("eva@ddzt.old", "rei", "user"),
    ("kk@ddzt.old", "zmjjkk", "user"),
    ("admin@ddzt.old", "admin", "admin"),
]

FAILS = []


def check(ok, msg):
    print(("[ok] " if ok else "[FAIL] ") + msg)
    if not ok:
        FAILS.append(msg)


def call(session, action, **fields):
    data = {"action": action}
    data.update(fields)
    return session.post(BASE, data=data)


def main():
    s = requests.Session()

    r = call(s, "me")
    check(r.status_code == 401, "未登录访问 me 返回 401")

    r = requests.post(MAIL_BASE, data={"action": "me"})
    check(not r.json().get("ok"), "未登录时邮箱会话为空")

    r = call(s, "login", username="eva@ddzt.old", password="wrong-pass")
    check(r.status_code == 401 and not r.json().get("ok"), "错误密码被拒绝")

    r = call(s, "login", username="nobody@ddzt.old", password="whatever")
    check(r.status_code == 401, "不存在的邮箱账号被拒绝")

    r = call(s, "login", username="eva", password="rei")
    check(r.status_code == 401, "短账号 eva 被拒绝（必须用邮箱登录）")

    r = call(s, "login", username="eva@example.com", password="rei")
    check(r.status_code == 401, "非 ddzt.old 域邮箱被拒绝")

    r = call(s, "login", username="eva@ddzt.old", password="")
    check(r.status_code == 400, "空密码被拒绝")

    for user, password, role in ACCOUNTS:
        sess = requests.Session()
        r = call(sess, "login", username=user, password=password)
        body = r.json()
        check(r.status_code == 200 and body.get("ok"), "邮箱账号 %s 登录成功" % user)
        check(body.get("data", {}).get("user") == user, "登录返回邮箱 %s" % user)
        check(body.get("data", {}).get("role") == role, "%s 登录返回角色 %s" % (user, role))

        r = call(sess, "me")
        check(r.status_code == 200 and r.json().get("data", {}).get("user") == user,
              "%s 会话保持（me）" % user)
        check(r.json().get("data", {}).get("role") == role, "%s me 返回角色 %s" % (user, role))

        r = sess.post(MAIL_BASE, data={"action": "me"})
        mail_user = r.json().get("data", {}).get("user", "")
        check(r.json().get("ok") and mail_user == user,
              "%s 登录 OA 后邮箱自动关联（%s）" % (user, mail_user or "未关联"))

        r = call(sess, "logout")
        check(r.status_code == 200 and r.json().get("ok"), "%s 退出登录" % user)
        r = call(sess, "me")
        check(r.status_code == 401, "%s 退出后会话失效" % user)
        r = sess.post(MAIL_BASE, data={"action": "me"})
        check(not r.json().get("ok"), "%s 退出后邮箱会话同时失效" % user)

    # 文档中心写权限：未登录 401、普通账号 403、管理员 200
    r = requests.post(FILES_BASE, data={"action": "delete", "id": 1})
    check(r.status_code == 401, "未登录删除文件返回 401")
    r = requests.post(FILES_BASE, data={"action": "upload"},
                      files={"file": ("anon.txt", b"x", "text/plain")})
    check(r.status_code == 401, "未登录上传文件返回 401")

    eva = requests.Session()
    call(eva, "login", username="eva@ddzt.old", password="rei")
    r = eva.post(FILES_BASE, data={"action": "upload"},
                 files={"file": ("eva.txt", b"x", "text/plain")})
    check(r.status_code == 403 and "仅管理员" in r.json().get("error", ""),
          "普通账号上传文件被拒绝（403）")
    r = eva.post(FILES_BASE, data={"action": "delete", "id": 1})
    check(r.status_code == 403, "普通账号删除文件被拒绝（403）")

    adm = requests.Session()
    call(adm, "login", username="admin@ddzt.old", password="admin")
    r = adm.post(FILES_BASE, data={"action": "upload"},
                 files={"file": ("admin-only.txt", b"admin upload ok", "text/plain")})
    body = r.json()
    check(r.status_code == 200 and body.get("ok"), "管理员上传文件成功")
    f = body.get("data", {}).get("file", {})
    fid = f.get("id")
    check(f.get("uploader") == "admin@ddzt.old", "上传记录的 uploader 为当前管理员")
    r = adm.post(FILES_BASE, data={"action": "delete", "id": fid})
    check(r.status_code == 200 and r.json().get("ok"), "管理员删除文件成功")
    rows = adm.post(FILES_BASE, data={"action": "list"}).json().get("data", {}).get("files", [])
    check(all(item.get("id") != fid for item in rows), "删除后文件不再出现在列表中")

    r = s.get(BASE, params={"action": "login", "username": "eva@ddzt.old", "password": "rei"})
    check(r.status_code == 405, "login 拒绝 GET 请求")

    print()
    if FAILS:
        print("E2E_OA_AUTH_FAILED (%d)" % len(FAILS))
        return 1
    print("E2E_OA_AUTH_ALL_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
