#!/usr/bin/env python3
"""Serve frozen legacy guide bytes, rewriting transport URLs only.

Raw inputs are never modified. External hrefs terminate in an inert local
destination whose original URL is visible and logged, not in third-party code.
"""
import argparse
import html
import http.server
import json
import mimetypes
import re
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit, parse_qs

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--assets', type=Path, required=True)
parser.add_argument('--icons', type=Path, required=True)
parser.add_argument('--port', type=int, default=18943)
args = parser.parse_args()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path)
        path = unquote(route.path)
        if path == '/out':
            original = parse_qs(route.query).get('url', [''])[0]
            data = ('<!doctype html><meta name="viewport" content="width=device-width">'
                    '<h1>Guide external destination</h1><p>' + html.escape(original) + '</p>').encode()
            kind = 'text/html'
        else:
            if path.startswith('/upgrading/'):
                name = path.rsplit('/', 1)[-1] or 'index.html'
                file = args.baseline / name
            elif path.startswith('/icon/'):
                file = args.icons / path.rsplit('/', 1)[-1]
            else:
                file = args.assets / path.lstrip('/')
            if '..' in Path(path).parts or not file.is_file():
                self.send_error(404)
                return
            data = file.read_bytes()
            kind = mimetypes.guess_type(str(file))[0] or 'application/octet-stream'
            if file.suffix == '.html':
                text = data.decode()
                text = re.sub(r'href="(https?://[^\"]+)"', lambda m:
                              'href="/out?url=' + quote(html.unescape(m[1]), safe='') + '"', text)
                text = re.sub(r'src="(?:https?:)?//[^\"]*/([^/\"]+\.png)"',
                              r'src="/icon/\1"', text)
                data = text.encode()
        self.send_response(200)
        self.send_header('Content-Type', kind + ('; charset=utf-8' if kind.startswith('text/') else ''))
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *values):
        print(json.dumps({'path': self.path, 'result': format % values}), flush=True)


http.server.HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
