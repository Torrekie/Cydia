#!/usr/bin/env python3
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

import argparse
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9"
    "Y9ZQmcAAAAASUVORK5CYII="
)


def document(title, body):
    return f"""<!doctype html>
<html><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1\">
<title>{title}</title><style>
html,body{{margin:0;padding:0;width:100%;overflow:hidden;font-family:-apple-system,sans-serif}}
body{{box-sizing:border-box;background:#fff;color:#202020;padding:10px}}
.link{{display:flex;min-height:54px;align-items:center;justify-content:center;border-radius:9px;
background:#e8f1ff;color:#075fc7;font-size:18px;font-weight:600;text-decoration:none;margin-bottom:12px}}
.card{{box-sizing:border-box;border:1px solid #c8c8c8;border-radius:8px;padding:12px;margin:8px 0;
min-height:96px;font-size:17px;line-height:1.35}}
img{{display:block;width:100%;height:110px;object-fit:cover;background:#f2a33a;margin:8px 0}}
.resource-icon{{width:60px;height:60px;object-fit:contain;background:transparent;margin:8px auto}}
iframe{{display:block;border:0;width:100%;height:180px;margin:8px 0}}
@media (prefers-color-scheme:dark){{body{{background:#111;color:#eee}}.card{{border-color:#555}}
.link{{background:#18324e;color:#79b8ff}}}}
</style></head><body>{body}</body></html>""".encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "CydiaDepictionFixture/1"

    def log_message(self, _format, *_args):
        return

    def record(self):
        entry = {
            "method": self.command,
            "path": self.path,
            "headers": {key: value for key, value in self.headers.items()},
        }
        with open(self.server.log_path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")

    def send_bytes(self, status, content_type, payload, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self.record()
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        package = query.get("package", [None])[0]
        package_route = query.get("linkPackage", [None])[0]
        if not package_route:
            package_route = getattr(self.server, "linked_package", None)
        package_route = package_route or package or "linked:iphoneos-arm64"
        if path == "/ready":
            self.send_bytes(200, "text/plain", b"ready\n")
            return
        if path == "/pixel.png":
            self.send_bytes(200, "image/png", PIXEL)
            return
        if path == "/frame":
            self.send_bytes(200, "text/html; charset=utf-8", document(
                "Depiction frame",
                '<div class="card" id="frame-marker">Same-origin iframe content remains inside the depiction.</div>',
            ))
            return
        if path == "/hostile-fired":
            self.send_bytes(204, "text/plain", b"")
            return
        if path == "/short":
            body = """
<a class="link" id="package-link" href="cydia://package/__PACKAGE_ROUTE__">
Open Linked Package</a>
<a class="link" id="external-link" href="cydia://url/https%3A%2F%2Fexample.com%2Fdepiction-external">
Open External Destination</a>
<div class="card" id="bridge-marker">Repository depiction content has no native package chrome.</div>
<div class="card" id="cydia-facade-marker">Facade contract pending</div>
<script>(function(){var marker=document.getElementById('cydia-facade-marker');var c=window.cydia;
var p=c&&c.getPackageById('runtime:iphoneos-arm64');var foreign=c&&c.getPackageById('other:iphoneos-arm64');
var missing=c&&c.getPackageById();var nullArg=c&&c.getPackageById(null);
var malformed=c&&c.getPackageById({});var callbackCalled=false;
var callbackResult=c&&c.getPackageById('runtime:iphoneos-arm64',function(){callbackCalled=true;});
var source=p&&p.source;var values={facade:!!c,package:!!p,foreign:foreign===null,
missing:missing===null,nullArg:nullArg===null,malformed:malformed===null,
callbackIgnored:callbackCalled===false&&callbackResult===p,
field:p&&p.getField('Version')==='2:1.1',tag:p&&p.hasTag('purpose::console')===true,
source:!!source,locale:!!(c&&c.getLocaleIdentifier()),format:c&&c.format('%@',['ok'])==='ok',
reach:c&&c.isReachable(window.location.origin+'/pixel.png')===true,
denied:c&&typeof c.getInstalledPackages==='undefined',
deniedMutation:c&&typeof c.installPackages==='undefined'&&typeof c.setMetadataValue==='undefined',
deniedDevice:c&&typeof c.device==='undefined'&&typeof c.getApplicationInfoValue==='undefined',
deniedFilesystem:c&&typeof c.du==='undefined'&&typeof c.statfs==='undefined',
deniedClipboard:c&&typeof c.setPasteboardString==='undefined',
deniedChrome:c&&typeof c.setButtonTitle==='undefined'&&typeof c.popViewController==='undefined',
deniedPrivileged:c&&typeof c.addBridgedHost==='undefined'&&typeof c.serial==='undefined'};marker.textContent=JSON.stringify(values);})();</script>
<img class="resource-icon" id="cydia-resource"
 src="cydia://section-icon/System" alt="Cydia System section resource">
<img class="resource-icon" id="cydia-resource-rejected"
 src="cydia://section-icon/%2Fetc" alt="Rejected Cydia resource">
<img src="/pixel.png" alt="Depiction image fixture">
<iframe src="/frame" title="Depiction iframe fixture"></iframe>
""".replace("__PACKAGE_ROUTE__", package_route)
            self.send_bytes(200, "text/html; charset=utf-8", document("Short depiction", body))
            return
        if path == "/long":
            cards = "".join(
                f'<div class="card">Long depiction block {index:02d}: deterministic expanded content.</div>'
                for index in range(1, 25)
            )
            body = f"""
<a class="link" id="package-link" href="cydia://package/__PACKAGE_ROUTE__">
Open Linked Package</a>
<img src="/pixel.png" alt="Long depiction image fixture">
<iframe src="/frame" title="Long depiction iframe fixture"></iframe>{cards}
""".replace("__PACKAGE_ROUTE__", package_route)
            self.send_bytes(200, "text/html; charset=utf-8", document("Long depiction", body))
            return
        if path == "/hostile":
            body = """
<a id="automatic-custom" href="cydia://launch/com.apple.Preferences">Automatic custom route</a>
<div class="card">A programmatic link click must not leave the depiction.</div>
<script>setTimeout(function(){var beacon=new Image();beacon.src='/hostile-fired';
document.body.appendChild(beacon);document.getElementById('automatic-custom').click()},100);</script>
"""
            self.send_bytes(200, "text/html; charset=utf-8", document("Hostile depiction", body))
            return
        if path == "/cross-redirect":
            destination = f"http://localhost:{self.server.server_port}/short"
            self.send_bytes(302, "text/plain", b"redirect\n", {"Location": destination})
            return
        if path == "/missing.png":
            self.send_bytes(404, "text/plain", b"missing image\n")
            return
        if path == "/missing-depiction":
            self.send_bytes(404, "text/plain", b"missing depiction\n")
            return
        self.send_bytes(404, "text/plain", b"not found\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--log", required=True)
    parser.add_argument("--linked-package", default=None,
                        help="package identity used by depiction package links")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.log_path = args.log
    server.linked_package = args.linked_package
    server.serve_forever()


if __name__ == "__main__":
    main()
