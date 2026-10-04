#!/usr/bin/env python3
"""Serve frozen Application Extensions HTML unchanged, except package transport."""
import argparse
import html
import http.server
import json
import mimetypes
from pathlib import Path
import re
from urllib.parse import quote, unquote, urlsplit, parse_qs

parser = argparse.ArgumentParser()
parser.add_argument("--baseline", required=True, type=Path)
parser.add_argument("--port", type=int, default=18944)
args = parser.parse_args()
root = args.baseline.resolve()

class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self, data, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        if self.path != "/api/application":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        self.respond((root / "api-application.json").read_bytes(), "application/json")
    def do_GET(self):
        route = urlsplit(self.path)
        path = unquote(route.path)
        pages = {"/ui/ios~iphone/1.1/application/": "iphone.html",
                 "/ui/ios~ipad/1.1/application/": "ipad.html",
                 "/application/com.apple.mobilesafari/": "safari.html",
                 "/application/com.apple.mobilemail/": "mail.html"}
        if path == "/out":
            url = parse_qs(route.query).get("url", [""])[0]
            data = ('<!doctype html><meta name="viewport" content="width=device-width">'
                    '<h1>Application extension destination</h1><p>' + html.escape(url) + '</p>').encode()
            self.respond(data, "text/html; charset=utf-8")
            return
        file = root / pages[path] if path in pages else root / "assets" / path.lstrip("/")
        if ".." in Path(path).parts or not file.is_file():
            self.send_error(404)
            return
        data = file.read_bytes()
        if file.suffix == ".html":
            # No cydia shim, DOM rewrite or invented rows. Production Safari's
            # missing bridge is part of the actual baseline.
            data = re.sub(rb'href="(http://cydia.saurik.com/package/[^"]+)"',
                          lambda m: ('href="/out?url=' + quote(m[1].decode(), safe="") + '"').encode(), data)
        self.respond(data, (mimetypes.guess_type(str(file))[0] or "application/octet-stream"))
    def log_message(self, format, *values):
        print(json.dumps({"path": self.path, "result": format % values}), flush=True)

http.server.HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
