#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公告 / 日程内容接口端到端验收（oa/api/content.php）

覆盖：
  * 未登录读取 -> 401
  * 登录用户可读取公告与日程（默认内容存在）
  * 普通账号 eva 新增/修改/删除 -> 403
  * admin 新增公告 -> 出现在列表、置顶排序生效、正文按行分段
  * admin 编辑公告 -> 标题/置顶/正文更新
  * 非法参数（空标题、错误日期）-> 400
  * admin 删除公告 -> 列表消失，重复删除 -> 404
  * admin 新增/编辑/删除日程 -> 持久化生效
  * 新建会话重新登录后数据仍存在（落盘校验）

用法：
    python tools/e2e_content_test.py [http://ddzt.old/api/content.php]
"""

import sys
import time

import requests

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://ddzt.old/api/content.php"
AUTH_BASE = BASE.rsplit("/", 1)[0] + "/auth.php"
SUFFIX = str(int(time.time()))
NOTICE_TITLE = "E2E 公告 " + SUFFIX
NOTICE_TITLE_2 = "E2E 公告（已编辑）" + SUFFIX
SCHEDULE_DAY = "E2E 测试日 " + SUFFIX
SCHEDULE_TITLE = "E2E 日程 " + SUFFIX
SCHEDULE_TITLE_2 = "E2E 日程（已编辑）" + SUFFIX

FAILS = []


def check(ok, msg):
    print(("[ok] " if ok else "[FAIL] ") + msg)
    if not ok:
        FAILS.append(msg)


def login(email, password):
    s = requests.Session()
    r = s.post(AUTH_BASE, data={"action": "login", "username": email, "password": password})
    if r.status_code != 200 or not r.json().get("ok"):
        raise RuntimeError("登录失败: %s %s" % (email, r.text))
    return s


def read(session):
    return session.get(BASE, params={"action": "data"})


def post(session, action, **fields):
    data = {"action": action}
    data.update(fields)
    return session.post(BASE, data=data)


def find_notice(session, title):
    data = read(session).json().get("data") or {}
    for n in data.get("notices") or []:
        if n.get("title") == title:
            return n
    return None


def find_schedule(session, title):
    data = read(session).json().get("data") or {}
    for it in data.get("schedule") or []:
        if it.get("title") == title:
            return it
    return None


def main():
    s = requests.Session()
    r = read(s)
    check(r.status_code == 401, "未登录读取公告/日程返回 401")

    eva = login("eva@ddzt.old", "rei")
    r = read(eva)
    check(r.status_code == 200, "eva 登录后可读取公告/日程")
    data = r.json().get("data") or {}
    check(len(data.get("notices") or []) >= 6, "默认公告不少于 6 条")
    check(len(data.get("schedule") or []) >= 15, "默认日程不少于 15 条")
    first = (data.get("notices") or [{}])[0]
    check(bool(first.get("title")) and "body" in first, "公告字段完整（title/body）")

    r = post(eva, "notice_save", title="x", dept="x", date="2026-01-01")
    check(r.status_code == 403, "普通账号新增公告被拒绝（403）")

    admin = login("admin@ddzt.old", "admin")
    notice_id = None
    schedule_id = None
    try:
        r = post(admin, "notice_save", title=NOTICE_TITLE, dept="测试部",
                 date="2026-12-01", pinned=1, body="第一段\n第二段")
        check(r.status_code == 200 and r.json().get("ok"), "admin 新增公告成功")
        notice_id = (r.json().get("data") or {}).get("id")
        found = find_notice(admin, NOTICE_TITLE)
        check(bool(found), "新增公告出现在列表")
        check(found and len(found.get("body") or []) == 2, "公告正文按行拆成两段")
        check(found and int(found.get("pinned") or 0) == 1, "公告置顶标记已保存")
        data = read(admin).json().get("data") or {}
        check(bool(data.get("notices")) and data["notices"][0].get("title") == NOTICE_TITLE,
              "置顶公告排在列表首位")

        r = post(admin, "notice_save", id=notice_id, title="", dept="测试部", date="2026-12-01")
        check(r.status_code == 400, "空公告标题返回 400")
        r = post(admin, "notice_save", id=notice_id, title="x", dept="测试部", date="2026-13-40")
        check(r.status_code == 400, "非法日期返回 400")

        r = post(admin, "notice_save", id=notice_id, title=NOTICE_TITLE_2, dept="测试部",
                 date="2026-12-02", pinned=0, body="修改后的正文")
        check(r.status_code == 200, "admin 编辑公告成功")
        found = find_notice(admin, NOTICE_TITLE_2)
        check(bool(found) and int(found.get("pinned") or 0) == 0, "公告修改已生效（标题/置顶）")
        check(found and found.get("body") == ["修改后的正文"], "公告正文修改已生效")

        r = post(eva, "notice_delete", id=notice_id)
        check(r.status_code == 403, "普通账号删除公告被拒绝（403）")

        r = post(admin, "schedule_save", day=SCHEDULE_DAY, time="09:00-10:00",
                 title=SCHEDULE_TITLE, place="测试会议室")
        check(r.status_code == 200, "admin 新增日程成功")
        schedule_id = (r.json().get("data") or {}).get("id")
        found = find_schedule(admin, SCHEDULE_TITLE)
        check(bool(found) and found.get("day") == SCHEDULE_DAY, "新增日程出现在列表")

        r = post(admin, "schedule_save", id=schedule_id, day=SCHEDULE_DAY,
                 time="10:00-11:00", title=SCHEDULE_TITLE_2, place="二号会议室")
        check(r.status_code == 200, "admin 编辑日程成功")
        found = find_schedule(admin, SCHEDULE_TITLE_2)
        check(bool(found) and found.get("time") == "10:00-11:00", "日程修改已生效")

        # 落盘校验：新会话重新登录仍能读到
        admin2 = login("admin@ddzt.old", "admin")
        check(bool(find_schedule(admin2, SCHEDULE_TITLE_2)), "新会话仍能读到新建日程（已落盘）")

        r = post(admin2, "schedule_delete", id=schedule_id)
        check(r.status_code == 200, "admin 删除日程成功")
        check(find_schedule(admin2, SCHEDULE_TITLE_2) is None, "删除后日程不再出现")
        schedule_id = None

        r = post(admin2, "notice_delete", id=notice_id)
        check(r.status_code == 200, "admin 删除公告成功")
        check(find_notice(admin2, NOTICE_TITLE_2) is None, "删除后公告不再出现")
        notice_id = None

        r = post(admin2, "notice_delete", id=99999999)
        check(r.status_code == 404, "重复删除公告返回 404")
    finally:
        # 失败时清理测试数据
        try:
            if notice_id:
                post(admin, "notice_delete", id=notice_id)
            if schedule_id:
                post(admin, "schedule_delete", id=schedule_id)
        except Exception:
            pass

    print()
    if FAILS:
        print("E2E_CONTENT_TEST_FAILED: %d 项失败" % len(FAILS))
        return 1
    print("E2E_CONTENT_TEST_ALL_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
