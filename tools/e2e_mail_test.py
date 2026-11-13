# -*- coding: utf-8 -*-
"""邮件系统端到端验收：未登录判定 -> eva 登录 -> 收件箱 -> 读信 -> 发信给 kk -> kk 收到 -> 删除
                          -> 带附件发信 -> kk 查看/下载收件附件 -> eva 已发送箱查看/下载附件

用法:
  python tools/e2e_mail_test.py [base_url]
  python tools/e2e_mail_test.py http://192.168.3.152/api/mail.php   # Windows hosts 没配时

注意：所有断言都显式检查并累计失败数，不依赖 assert（python -O 会剥离 assert，
     曾导致失败也打印 ALL_PASS 并退出 0）。
"""
import os
import sys
import time

import requests

BASE = "http://ddzt.old/api/mail.php"
FAILS = []


def check(cond, label, detail=""):
    if cond:
        print("[ok] %s" % label)
    else:
        print("[x ] %s  %s" % (label, detail))
        FAILS.append(label)
    return cond


def call(s, action, **kw):
    r = s.post(BASE, data=dict(action=action, **kw), timeout=10)
    r.raise_for_status()          # 502/HTML 错误页直接报错，而不是 JSON 解析异常
    return r.json()


def send_with_files(s, subject, attachments, to="kk@ddzt.old", body="带附件的端到端测试邮件"):
    """attachments: [(文件名, 原始字节, MIME)]，走 multipart/form-data 的 attachments[] 字段"""
    files = [("attachments[]", (name, content, mime)) for name, content, mime in attachments]
    r = s.post(BASE, data={"action": "send", "to": to, "subject": subject, "body": body},
               files=files, timeout=60)
    r.raise_for_status()
    return r.json()


def download(s, folder, uid, part):
    """GET action=attachment，返回原始 Response 以便比对字节/状态码"""
    return s.get(BASE, params={"action": "attachment", "folder": folder,
                               "uid": uid, "part": part}, timeout=60)


def pick_base():
    if len(sys.argv) > 1:
        return sys.argv[1]
    env = os.environ.get("MAIL_API")
    if env:
        return env
    # Windows 侧没有 /etc/hosts 的 ddzt.old 时，退回直连服务端 + Host 头不可行，
    # 因此这里给出提示，仍按原域名尝试
    return BASE


def main():
    global BASE
    BASE = pick_base()
    s1, s2 = requests.Session(), requests.Session()
    try:
        j = call(s1, "me")
        check(j.get("ok") is False, "未登录判定")

        j = call(s1, "login", username="eva@ddzt.old", password="rei")
        check(j.get("ok"), "eva 登录", j)

        j = call(s1, "list")
        msgs = (j.get("data") or {}).get("messages") or []
        check(j.get("ok") and msgs, "eva 收件箱非空", "messages=%d" % len(msgs))

        if msgs:
            j = call(s1, "read", uid=msgs[0]["uid"])
            body = ((j.get("data") or {}).get("body_text") or "")
            check(j.get("ok") and bool(body), "读信有正文", "body_len=%d" % len(body))

        subj = "端到端测试 %d" % int(time.time())
        marker = "正文往返校验 %d" % int(time.time())
        j = call(s1, "send", to="kk@ddzt.old", subject=subj,
                 body=marker + "\n这是客户端通过 OA 邮件模块发出的测试邮件。\n-- e2e test")
        check(j.get("ok"), "eva -> kk 发信", j)

        j = call(s2, "login", username="kk@ddzt.old", password="zmjjkk")
        check(j.get("ok"), "kk 登录", j)

        hit = None
        for _ in range(10):            # 轮询最多 10s，而不是固定 sleep 2（投递慢时 flaky）
            j = call(s2, "list")
            msgs2 = (j.get("data") or {}).get("messages") or []
            hit = [m for m in msgs2 if m.get("subject") == subj]
            if hit:
                break
            time.sleep(1)
        check(bool(hit), "kk 收到测试邮件", "未在 10s 内出现")

        if hit:
            j = call(s2, "read", uid=hit[0]["uid"])
            got_body = ((j.get("data") or {}).get("body_text") or "")
            check(j.get("ok") and marker in got_body, "读信正文内容正确",
                  "body=%r" % got_body[:80])
            j = call(s2, "delete", uid=hit[0]["uid"])
            check(j.get("ok"), "kk 删除测试邮件", j)
            j = call(s2, "list")
            left = [m for m in ((j.get("data") or {}).get("messages") or [])
                    if m.get("subject") == subj]
            check(not left, "删除后不再出现")

        # ---------- 附件：发送 -> 收件方查看/下载 -> 发件箱查看/下载 ----------
        att1_name = "测试 附件.txt"
        att1_data = "中文附件内容 hello attachment\n".encode("utf-8")
        att2_name = "binary.dat"
        att2_data = bytes(range(256)) * 8
        att_subj = "附件往返测试 %d" % int(time.time())

        j = send_with_files(s1, att_subj,
                            [(att1_name, att1_data, "text/plain"),
                             (att2_name, att2_data, "application/octet-stream")])
        check(j.get("ok"), "eva 发送带附件邮件", j)
        echoed = (j.get("data") or {}).get("attachments") or []
        check(len(echoed) == 2, "发信接口回显 2 个附件", echoed)

        hit2 = None
        for _ in range(10):
            j = call(s2, "list")
            msgs2 = (j.get("data") or {}).get("messages") or []
            hit2 = [m for m in msgs2 if m.get("subject") == att_subj]
            if hit2:
                break
            time.sleep(1)
        check(bool(hit2), "kk 收到带附件邮件", "未在 10s 内出现")

        if hit2:
            m = hit2[0]
            check(m.get("has_attachment") is True, "收件列表含附件标记", m)
            check(m.get("attachment_count") == 2, "收件列表附件数=2", m.get("attachment_count"))
            j = call(s2, "read", uid=m["uid"])
            rd = j.get("data") or {}
            atts = rd.get("attachments") or []
            check(j.get("ok") and len(atts) == 2, "读信返回 2 个附件元数据", atts)
            check("带附件的端到端测试邮件" in (rd.get("body_text") or ""),
                  "带附件邮件正文可读", (rd.get("body_text") or "")[:80])
            names = set(a.get("filename") for a in atts)
            check(names == set([att1_name, att2_name]), "附件文件名正确（含中文）", names)
            by_name = dict((a.get("filename"), a) for a in atts)
            for name, expected in ((att1_name, att1_data), (att2_name, att2_data)):
                a = by_name.get(name)
                if not a:
                    check(False, "缺少附件 %s" % name)
                    continue
                r = download(s2, "INBOX", m["uid"], a["part"])
                check(r.status_code == 200, "收件方下载 %s 状态 200" % name, r.status_code)
                check(r.content == expected, "收件方下载 %s 字节一致" % name,
                      "len %d != %d" % (len(r.content), len(expected)))
                # 元数据大小是展示用的近似值，允许几字节误差
                check(abs((a.get("size") or 0) - len(expected)) <= 4,
                      "附件大小元数据接近实际值 (%s)" % name,
                      "%s vs %d" % (a.get("size"), len(expected)))

            # 未登录用户不能下载附件
            anon = requests.Session()
            try:
                a = by_name.get(att1_name)
                if a:
                    r = download(anon, "INBOX", m["uid"], a["part"])
                    check(r.status_code == 401, "未登录下载附件被拒绝", r.status_code)
            finally:
                anon.close()

            j = call(s2, "delete", uid=m["uid"])
            check(j.get("ok"), "kk 删除带附件测试邮件", j)

        # 已发送箱：查看/下载自己发出的附件
        j = call(s1, "list", folder="Sent")
        sent_msgs = (j.get("data") or {}).get("messages") or []
        sent_hit = [m for m in sent_msgs if m.get("subject") == att_subj]
        check(j.get("ok") and bool(sent_hit), "已发送箱含带附件邮件", "n=%d" % len(sent_msgs))
        if sent_hit:
            sm = sent_hit[0]
            check(sm.get("has_attachment") is True, "已发送列表含附件标记", sm)
            j = call(s1, "read", uid=sm["uid"], folder="Sent")
            srd = j.get("data") or {}
            check(j.get("ok") and srd.get("folder") == "Sent", "读取已发送邮件", j)
            satts = srd.get("attachments") or []
            check(len(satts) == 2, "已发送邮件附件数=2", satts)
            s_by_name = dict((a.get("filename"), a) for a in satts)
            a = s_by_name.get(att1_name)
            if a:
                r = download(s1, "Sent", sm["uid"], a["part"])
                check(r.status_code == 200 and r.content == att1_data,
                      "从已发送箱下载附件字节一致", "status=%s" % r.status_code)
            j = call(s1, "delete", uid=sm["uid"], folder="Sent")
            check(j.get("ok"), "删除已发送测试邮件", j)
    except requests.RequestException as e:
        check(False, "HTTP 请求失败", repr(e))
    finally:
        s1.close()
        s2.close()

    if FAILS:
        print("E2E_MAIL_TEST_FAILED（%d 项）：%s" % (len(FAILS), ", ".join(FAILS)))
        return 1
    print("E2E_MAIL_TEST_ALL_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
