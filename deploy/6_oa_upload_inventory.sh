#!/usr/bin/env bash
# 列出 OA 服务端全部“上传文件”的路径与大小：
#   1) 文件共享区的文件实体（/var/www/oa-share/files）
#   2) 邮件附件（各用户 Maildir 中每封邮件的 MIME 附件，解码后大小）
#
# 用法:
#   oa-upload-inventory                 # 表格输出
#   oa-upload-inventory --json          # JSON 输出
#   oa-upload-inventory --no-mail       # 只看文件共享
#   oa-upload-inventory --share-dir DIR --mail-root DIR
#
# 说明: 邮件附件不是独立文件，而是编码在整封邮件里，因此“位置”显示
#      邮件文件路径 + #part=N（MIME 部件序号），大小按解码后字节数统计。
#      SHARE 行的 ID 是文件共享数据库中的 id，可用于接口删除：
#      curl -b cookie.txt -d 'action=delete&id=12' http://127.0.0.1/api/files.php
set -u
exec python3 - "$@" <<'PY'
# -*- coding: utf-8 -*-
import glob
import json
import os
import sqlite3
import sys
import time
from email import policy
from email.parser import BytesParser

SHARE_DIR = "/var/www/oa-share/files"
SHARE_DB = "/var/www/oa-share/data/files.sqlite"
MAIL_ROOT = "/home"


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            if unit == "B":
                return "%d B" % int(n)
            return "%.1f %s" % (n, unit)
        n /= 1024.0


def parse_args(argv):
    opts = {"json": False, "share": True, "mail": True,
            "share_dir": SHARE_DIR, "mail_root": MAIL_ROOT}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            opts["json"] = True
        elif a == "--no-mail":
            opts["mail"] = False
        elif a == "--no-share":
            opts["share"] = False
        elif a == "--share-dir" and i + 1 < len(argv):
            i += 1
            opts["share_dir"] = argv[i]
        elif a == "--mail-root" and i + 1 < len(argv):
            i += 1
            opts["mail_root"] = argv[i]
        elif a in ("-h", "--help"):
            print(__doc__ if __doc__ else "usage: oa-upload-inventory [--json] [--no-mail] [--no-share]")
            sys.exit(0)
        else:
            sys.stderr.write("未知参数: %s\n" % a)
            sys.exit(2)
        i += 1
    return opts


def share_meta(db_path):
    """stored 文件名 -> (原始文件名, 上传者, 文件 ID)"""
    meta = {}
    if not os.path.exists(db_path):
        return meta
    try:
        con = sqlite3.connect(db_path)
        cur = con.cursor()
        cur.execute("SELECT stored, name, uploader, id FROM files")
        for stored, name, uploader, fid in cur.fetchall():
            meta[stored] = (name, uploader or "-", fid)
        con.close()
    except Exception as exc:  # 数据库损坏时仍列出实体文件
        sys.stderr.write("警告: 读取共享数据库失败: %s\n" % exc)
    return meta


def collect_share(share_dir):
    rows = []
    meta = share_meta(SHARE_DB)
    if not os.path.isdir(share_dir):
        sys.stderr.write("警告: 共享目录不存在: %s\n" % share_dir)
        return rows
    for name in sorted(os.listdir(share_dir)):
        path = os.path.join(share_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        original, uploader, fid = meta.get(name, (name, "-", None))
        rows.append({"category": "SHARE", "size": size, "owner": uploader,
                     "filename": original, "path": path, "part": None, "id": fid})
    return rows


def decode_name(part):
    name = part.get_filename()
    if not name:
        return None
    return name


def collect_mail(mail_root):
    rows = []
    if not os.path.isdir(mail_root):
        sys.stderr.write("警告: 邮件根目录不存在: %s\n" % mail_root)
        return rows
    for home in sorted(glob.glob(os.path.join(mail_root, "*"))):
        md = os.path.join(home, "Maildir")
        if not os.path.isdir(md):
            continue
        owner = os.path.basename(home)
        for dirpath, dirnames, filenames in os.walk(md):
            base = os.path.basename(dirpath)
            if base not in ("new", "cur"):
                continue
            mailbox = os.path.basename(os.path.dirname(dirpath))
            for fn in sorted(filenames):
                if fn.startswith("dovecot") or fn.startswith("."):
                    continue
                msg_path = os.path.join(dirpath, fn)
                try:
                    with open(msg_path, "rb") as fh:
                        msg = BytesParser(policy=policy.default).parse(fh)
                except Exception:
                    continue
                part_no = 0
                for part in msg.walk():
                    if part.is_multipart():
                        continue
                    part_no += 1
                    name = decode_name(part)
                    disp = str(part.get("Content-Disposition") or "").lower()
                    if not name and "attachment" not in disp:
                        continue
                    payload = part.get_payload(decode=True)
                    if payload is None:
                        raw = part.get_payload()
                        payload = raw.encode("utf-8", "replace") if isinstance(raw, str) else b""
                    rows.append({"category": "MAIL", "size": len(payload),
                                 "owner": owner + "@ddzt.old", "filename": name or "(未命名)",
                                 "path": msg_path, "part": part_no, "mailbox": mailbox, "id": None})
    return rows


def main():
    opts = parse_args(sys.argv[1:])
    rows = []
    if opts["share"]:
        rows += collect_share(opts["share_dir"])
    if opts["mail"]:
        rows += collect_mail(opts["mail_root"])
    share_rows = [r for r in rows if r["category"] == "SHARE"]
    mail_rows = [r for r in rows if r["category"] == "MAIL"]

    if opts["json"]:
        out = {
            "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "rows": rows,
            "totals": {
                "all": {"count": len(rows), "size": sum(r["size"] for r in rows)},
                "share": {"count": len(share_rows), "size": sum(r["size"] for r in share_rows)},
                "mail": {"count": len(mail_rows), "size": sum(r["size"] for r in mail_rows)},
            },
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return

    print("%-5s %-10s %-6s %-22s %s" % ("类型", "大小", "ID", "上传者/邮箱", "路径（邮件附件=邮件文件#part=N）"))
    print("-" * 106)
    for r in rows:
        loc = r["path"]
        if r["category"] == "MAIL":
            loc += "#part=%d" % r["part"]
        fid = ("#" + str(r["id"])) if r.get("id") is not None else "-"
        print("%-5s %-10s %-6s %-22s %s  «%s»" % (
            r["category"], human(r["size"]), fid, r["owner"], loc, r["filename"]))
    print("-" * 106)
    print("合计: 共享文件 %d 个 / %s；邮件附件 %d 个 / %s；全部 %d 个 / %s" % (
        len(share_rows), human(sum(r["size"] for r in share_rows)),
        len(mail_rows), human(sum(r["size"] for r in mail_rows)),
        len(rows), human(sum(r["size"] for r in rows))))


if __name__ == "__main__":
    main()
PY
