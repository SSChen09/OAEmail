#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""个人待办端到端回归（服务端 SQLite，按账号隔离）

覆盖：
  1. 未登录读取/写入/删除 -> 401
  2. eva、kk 各自初始化默认待办，列表互不包含
  3. eva 新增（含截止日期）、编辑文字/状态/日期、删除
  4. kk 修改/删除 eva 的待办 -> 404；eva 列表不受影响
  5. 空内容、超长内容、非法日期 -> 400
  6. 新会话重新登录后数据仍在（服务端落盘）
  7. 清理测试数据

用法：
  python tools/e2e_todos_test.py [BASE_URL]
  BASE_URL 默认 http://ddzt.old/api/todos.php
"""
import sys

import requests

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://ddzt.old/api/todos.php"
AUTH = BASE.rsplit("/", 1)[0] + "/auth.php"

PASSED = 0
FAILED = 0


def check(name, cond, extra=""):
    global PASSED, FAILED
    if cond:
        PASSED += 1
        print("  [PASS] %s" % name)
    else:
        FAILED += 1
        print("  [FAIL] %s %s" % (name, extra))


def login(username, password):
    s = requests.Session()
    r = s.post(AUTH, data={"action": "login", "username": username, "password": password}, timeout=10)
    if r.status_code != 200 or not r.json().get("ok"):
        raise SystemExit("登录失败：%s %s" % (username, r.text[:200]))
    return s


def api(session, action, **kw):
    if action == "list":
        return session.get(BASE, params={"action": "list"}, timeout=10)
    data = {"action": action}
    data.update(kw)
    return session.post(BASE, data=data, timeout=10)


def todos(resp):
    return resp.json()["data"]["todos"]


def find(items, tid):
    return [t for t in items if t["id"] == tid]


def main():
    print("== 未登录 ==")
    anon = requests.Session()
    check("未登录 list 401", api(anon, "list").status_code == 401)
    check("未登录 save 401", api(anon, "save", id=0, text="x", done=0, due="").status_code == 401)
    check("未登录 delete 401", api(anon, "delete", id=1).status_code == 401)
    check("GET save 405", anon.get(BASE, params={"action": "save"}, timeout=10).status_code == 405)

    print("== 账号隔离与默认数据 ==")
    eva = login("eva@ddzt.old", "rei")
    kk = login("kk@ddzt.old", "zmjjkk")
    eva0 = todos(api(eva, "list"))
    kk0 = todos(api(kk, "list"))
    check("eva 有默认待办", len(eva0) >= 8, len(eva0))
    check("kk 有默认待办", len(kk0) >= 8, len(kk0))
    eva_ids = {t["id"] for t in eva0}
    kk_ids = {t["id"] for t in kk0}
    check("两人待办 ID 不重叠", not (eva_ids & kk_ids), str(eva_ids & kk_ids))

    created = []
    try:
        print("== 新增 / 编辑 / 校验 ==")
        r = api(eva, "save", id=0, text="E2E 待办-新增", done=0, due="2026-12-31")
        check("eva 新增 200", r.status_code == 200, r.text[:200])
        items = todos(r)
        row = [t for t in items if t["text"] == "E2E 待办-新增"]
        check("新增出现在列表", len(row) == 1)
        tid = row[0]["id"]
        created.append(tid)
        check("新增截止日期正确", row[0]["due"] == "2026-12-31", row[0])
        check("新增默认未完成", row[0]["done"] is False)

        r = api(eva, "save", id=tid, text="E2E 待办-已编辑", done=1, due="2027-01-15")
        check("eva 编辑 200", r.status_code == 200, r.text[:200])
        row = find(todos(r), tid)[0]
        check("文字/状态/日期已更新", row["text"] == "E2E 待办-已编辑" and row["done"] is True and row["due"] == "2027-01-15", row)

        check("空内容 400", api(eva, "save", id=0, text="   ", done=0, due="").status_code == 400)
        check("超长内容 400", api(eva, "save", id=0, text="长" * 201, done=0, due="").status_code == 400)
        check("非法日期 400", api(eva, "save", id=0, text="日期错误", done=0, due="2026-13-40").status_code == 400)
        check("非法 id 编辑 404", api(eva, "save", id=99999999, text="x", done=0, due="").status_code == 404)

        print("== 越权隔离 ==")
        r = api(kk, "save", id=tid, text="kk 篡改", done=0, due="")
        check("kk 编辑 eva 待办 404", r.status_code == 404, r.text[:200])
        check("kk 删除 eva 待办 404", api(kk, "delete", id=tid).status_code == 404)
        eva_now = todos(api(eva, "list"))
        row = find(eva_now, tid)
        check("eva 待办未被篡改", len(row) == 1 and row[0]["text"] == "E2E 待办-已编辑")

        print("== 落盘（新会话） ==")
        eva2 = login("eva@ddzt.old", "rei")
        persisted = find(todos(api(eva2, "list")), tid)
        check("新会话仍能读到", len(persisted) == 1 and persisted[0]["text"] == "E2E 待办-已编辑")

        r = api(eva2, "delete", id=tid)
        check("eva 删除 200", r.status_code == 200, r.text[:200])
        check("删除后列表无该项", not find(todos(api(eva2, "list")), tid))
        check("重复删除 404", api(eva2, "delete", id=tid).status_code == 404)
        created.remove(tid)

        print("== 默认数据未被测试破坏 ==")
        check("eva 默认待办仍在", len(todos(api(eva2, "list"))) >= 8)
        check("kk 默认待办仍在", len(todos(api(kk, "list"))) >= 8)
    finally:
        for tid in created:
            api(eva, "delete", id=tid)

    print()
    if FAILED:
        print("E2E_TODOS_TEST_FAILED  PASS=%d FAIL=%d" % (PASSED, FAILED))
        return 1
    print("E2E_TODOS_TEST_ALL_PASS  (%d checks)" % PASSED)
    return 0


if __name__ == "__main__":
    sys.exit(main())
