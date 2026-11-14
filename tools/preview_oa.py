#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地预览 OA 前端：静态文件取本地 oa/，/api/* 与 /ddos/ 反向代理到服务端。

用法:
    python tools/preview_oa.py                 # http://127.0.0.1:8123
    python tools/preview_oa.py --port 8091
    python tools/preview_oa.py --upstream 192.168.3.152:80

这样改 oa/static/*.js、*.css、index.html 后刷新即可看到效果，
登录、公告、文件共享、邮件等接口仍走真实服务端，不需要本地装 PHP。
"""
import argparse
import http.client
import http.server
import os
import posixpath
import sys
import urllib.parse

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "oa")

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
}


class Handler(http.server.BaseHTTPRequestHandler):
    upstream_host = "192.168.3.152"
    upstream_port = 80
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))

    def do_GET(self):
        self.dispatch()

    def do_HEAD(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PUT(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def dispatch(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path.startswith("/api/") or parsed.path.startswith("/ddos/"):
            self.proxy(parsed)
        else:
            self.serve_static(parsed.path)

    # ---------- 静态文件 ----------
    def serve_static(self, path):
        path = urllib.parse.unquote(path)
        if path in ("", "/"):
            path = "/index.html"
        rel = posixpath.normpath(path).lstrip("/")
        full = os.path.realpath(os.path.join(ROOT, rel))
        if os.path.commonpath([ROOT, full]) != ROOT or not os.path.isfile(full):
            self.send_error(404, "Not Found")
            return
        ext = os.path.splitext(full)[1].lower()
        ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(full, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    # ---------- API 反向代理 ----------
    def proxy(self, parsed):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        headers = {}
        for key in ("Cookie", "Content-Type", "Accept", "Accept-Language",
                    "Accept-Encoding", "User-Agent", "Referer", "Origin"):
            value = self.headers.get(key)
            if value:
                headers[key] = value
        headers["Host"] = "%s:%d" % (self.upstream_host, self.upstream_port)
        if body is not None:
            headers["Content-Length"] = str(len(body))

        target = parsed.path
        if parsed.query:
            target += "?" + parsed.query

        try:
            conn = http.client.HTTPConnection(self.upstream_host, self.upstream_port, timeout=120)
            conn.request(self.command, target, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except Exception as exc:
            message = ("上游服务不可达: %s\n%s\n" % (self.upstream_host, exc)).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)
            return

        self.send_response(resp.status, resp.reason)
        for key, value in resp.getheaders():
            low = key.lower()
            if low in ("transfer-encoding", "connection", "content-length", "keep-alive"):
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="本地预览 OA（静态本地 + API 代理到服务端）")
    parser.add_argument("--port", type=int, default=8123, help="本地监听端口，默认 8123")
    parser.add_argument("--bind", default="127.0.0.1", help="监听地址，默认 127.0.0.1")
    parser.add_argument("--upstream", default="192.168.3.152:80", help="上游 host:port")
    args = parser.parse_args()

    host, _, port = args.upstream.partition(":")
    Handler.upstream_host = host
    Handler.upstream_port = int(port or 80)

    if not os.path.isfile(os.path.join(ROOT, "index.html")):
        sys.stderr.write("找不到 oa/index.html: %s\n" % ROOT)
        return 2

    server = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    server.daemon_threads = True
    print("OA 本地预览: http://%s:%d/" % (args.bind, args.port))
    print("静态目录  : %s" % ROOT)
    print("API/DDoS 上游: http://%s:%d/" % (Handler.upstream_host, Handler.upstream_port))
    print("按 Ctrl+C 退出")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


if __name__ == "__main__":
    sys.exit(main())
