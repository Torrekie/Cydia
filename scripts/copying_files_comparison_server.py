#!/usr/bin/env python3
"""Original guide bytes except documented transport-only anchor substitution."""
import argparse
import html
import http.server
import json
import mimetypes
from pathlib import Path
import re
from urllib.parse import parse_qs, quote, unquote, urljoin, urlsplit

p = argparse.ArgumentParser(); p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--port', type=int, default=18946)
args = p.parse_args(); root = args.baseline.resolve()
frozen = json.loads((root / 'frozen-inputs.json').read_text())
allowed = {link['url'] for link in frozen['links']}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path); path = unquote(route.path)
        if path == '/out':
            original = parse_qs(route.query).get('url', [''])[0]
            if original not in allowed: self.send_error(400); return
            data = ('<!doctype html><meta name="viewport" content="width=device-width">'
                    '<h1>Frozen guide destination</h1><p>' + html.escape(original) + '</p>').encode()
            kind = 'text/html'
        else:
            if '..' in Path(path).parts: self.send_error(400); return
            file = root / 'copying.html' if path == '/copying.html' else root / 'assets' / path.lstrip('/')
            if not file.is_file() or file.name.endswith('.headers'): self.send_error(404); return
            data = file.read_bytes(); kind = mimetypes.guess_type(str(file))[0] or 'application/octet-stream'
            if path == '/copying.html':
                def anchor(match):
                    original = urljoin(frozen['original_url'], html.unescape(match[2]))
                    assert original in allowed
                    return match[1] + '/out?url=' + quote(original, safe='') + '"'
                data = re.sub(r'(<a\s+href=")([^\"]+)"', anchor, data.decode()).encode()
        self.send_response(200); self.send_header('Content-Type', kind + ('; charset=utf-8' if kind.startswith('text/') else ''))
        self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(data)
    def log_message(self, fmt, *values):
        print(json.dumps(dict(path=self.path, result=fmt % values)), flush=True)
http.server.HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
