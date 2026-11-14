# -*- coding: utf-8 -*-
"""OA 文件共享 API 端到端测试。

覆盖：
  - 未登录不可列表 / 上传 / 下载（401）
  - 登录用户上传，服务端记录上传者、上传时间、大小、说明、到期时间
  - 列表返回完整元数据，上传者可删除自己的文件
  - 普通用户不能删除他人文件（403），管理员可删除任意文件
  - 过期文件列表标注 expired，下载返回 410，但记录仍保留
  - 说明超长、到期时间格式非法时给出明确错误
  - 数据落盘：新会话重新登录后仍能看到文件

用法：
    python tools/e2e_share_test.py [http://192.168.3.152]
"""
import sys
import time

import requests

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://192.168.3.152").rstrip("/")
AUTH = BASE + "/api/auth.php"
FILES = BASE + "/api/files.php"

FAILS = []


def check(cond, label):
    if cond:
        print("  [PASS] " + label)
    else:
        print("  [FAIL] " + label)
        FAILS.append(label)


def login(sess, user, password):
    r = sess.post(AUTH, data={"action": "login", "username": user, "password": password})
    check(r.status_code == 200 and r.json().get("ok"), "登录 %s" % user)
    return r


def upload(sess, name, content, note="", expires=""):
    return sess.post(
        FILES,
        data={"action": "upload", "note": note, "expires_at": expires},
        files={"file": (name, content, "application/octet-stream")},
    )


def rows_of(sess):
    r = sess.post(FILES, data={"action": "list"})
    check(r.status_code == 200 and r.json().get("ok"), "读取文件列表")
    return r.json().get("data", {}).get("files", [])


def find(rows, fid):
    return next((x for x in rows if x.get("id") == fid), None)


def main():
    stamp = time.strftime("%H%M%S")
    created = []

    print("== 未登录访问 ==")
    anon = requests.Session()
    check(anon.post(FILES, data={"action": "list"}).status_code == 401, "未登录列表返回 401")
    check(anon.post(FILES, data={"action": "upload"},
                    files={"file": ("anon.txt", b"x", "text/plain")}).status_code == 401,
          "未登录上传返回 401")
    check(anon.get(FILES, params={"action": "download", "id": 1}).status_code == 401,
          "未登录下载返回 401")

    print("== 普通用户上传与元数据 ==")
    eva = requests.Session()
    login(eva, "eva@ddzt.old", "rei")
    payload = (b"share-body-" + stamp.encode()) * 50
    note = "共享说明：第一行\n第二行 " + stamp
    r = upload(eva, "共享测试-%s.txt" % stamp, payload, note, "2099-12-31T23:59")
    body = r.json()
    check(r.status_code == 200 and body.get("ok"), "eva 上传文件成功")
    f = body.get("data", {}).get("file", {})
    fid = f.get("id")
    if fid:
        created.append(fid)
    check(f.get("uploader") == "eva@ddzt.old", "上传者为 eva@ddzt.old")
    check(f.get("size") == len(payload), "文件大小记录准确")
    check(f.get("note") == note, "文件说明按原文保存（含换行）")
    check(f.get("expires_at") == "2099-12-31 23:59", "到期时间规范化为 Y-m-d H:i")
    check(f.get("expired") is False, "未到期文件 expired=false")
    check(bool(f.get("created_at")), "上传时间已记录")

    rows = rows_of(eva)
    row = find(rows, fid)
    check(row is not None, "列表中能看到刚上传的文件")
    check(row and row.get("uploader") == "eva@ddzt.old", "列表返回上传者")
    check(row and row.get("note") == note, "列表返回说明")
    check(row and row.get("expires_at") == "2099-12-31 23:59", "列表返回到期时间")
    check(rows and rows[0].get("id") == fid, "最新文件排在最前")

    r = eva.get(FILES, params={"action": "download", "id": fid})
    check(r.status_code == 200 and r.content == payload, "下载内容与上传逐字节一致")
    row = find(rows_of(eva), fid)
    check(row and row.get("downloads") == 1, "下载次数已累加")

    print("== 参数校验 ==")
    r = upload(eva, "bad-expire.txt", b"x", "", "2020/01/01")
    check(r.json().get("ok") is False and "格式不正确" in r.json().get("error", ""),
          "非法到期时间被拒绝")
    r = upload(eva, "long-note.txt", b"x", "说" * 201, "")
    check(r.json().get("ok") is False and "说明最多" in r.json().get("error", ""),
          "超过 200 字的说明被拒绝")

    print("== 删除权限 ==")
    adm = requests.Session()
    login(adm, "admin@ddzt.old", "admin")
    r = upload(adm, "管理员文件-%s.txt" % stamp, b"admin file", "管理员上传")
    adm_file = r.json().get("data", {}).get("file", {})
    adm_id = adm_file.get("id")
    if adm_id:
        created.append(adm_id)
    check(r.status_code == 200 and adm_file.get("uploader") == "admin@ddzt.old", "管理员上传成功")

    r = eva.post(FILES, data={"action": "delete", "id": adm_id})
    check(r.status_code == 403 and "只能删除自己" in r.json().get("error", ""),
          "普通用户不能删除他人文件（403）")
    r = eva.post(FILES, data={"action": "delete", "id": fid})
    check(r.status_code == 200 and r.json().get("ok"), "上传者可以删除自己的文件")
    created = [x for x in created if x != fid]
    r = adm.post(FILES, data={"action": "delete", "id": adm_id})
    check(r.status_code == 200 and r.json().get("ok"), "管理员可以删除任意文件")
    created = [x for x in created if x != adm_id]
    check(find(rows_of(eva), fid) is None, "删除后文件不再出现在列表")

    print("== 到期文件 ==")
    r = upload(eva, "已过期-%s.txt" % stamp, b"expired", "到期测试", "2020-01-01T00:00")
    exp = r.json().get("data", {}).get("file", {})
    exp_id = exp.get("id")
    check(r.status_code == 200 and exp.get("expired") is True, "过去时间上传后立即标记过期")
    if exp_id:
        created.append(exp_id)
    r = eva.get(FILES, params={"action": "download", "id": exp_id})
    check(r.status_code == 410, "过期文件下载返回 410")
    check("已过期" in r.text, "下载错误提示包含过期时间")
    erow = find(rows_of(eva), exp_id)
    check(erow is not None and erow.get("expired") is True, "过期文件仍保留在列表并标注")
    eva.post(FILES, data={"action": "delete", "id": exp_id})
    created = [x for x in created if x != exp_id]

    print("== 数据落盘 ==")
    r = upload(eva, "落盘-%s.txt" % stamp, b"persist", "新会话可见")
    pid = r.json().get("data", {}).get("file", {}).get("id")
    if pid:
        created.append(pid)
    fresh = requests.Session()
    login(fresh, "eva@ddzt.old", "rei")
    check(find(rows_of(fresh), pid) is not None, "新的登录会话仍能看到文件（已落盘）")

    print("== 清理 ==")
    for x in created:
        eva.post(FILES, data={"action": "delete", "id": x})
    left = set(x.get("id") for x in rows_of(eva)) & set(created)
    check(not left, "测试文件已清理")

    print()
    if FAILS:
        print("E2E_SHARE_TEST_FAILED (%d)" % len(FAILS))
        return 1
    print("E2E_SHARE_TEST_ALL_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
