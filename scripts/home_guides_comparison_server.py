#!/usr/bin/env python3
"""Bounded, offline before transport; exact page bodies apart from URL transport."""
import argparse
import html
import http.server
import json
import mimetypes
from pathlib import Path
import re
from urllib.parse import parse_qs, quote, unquote, urljoin, urlsplit

p = argparse.ArgumentParser()
p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--port', type=int, default=18947)
args = p.parse_args()
root = args.baseline.resolve()
frozen = json.loads((root / 'frozen-inputs.json').read_text())
pages = {page['path']: page for page in frozen['pages']}
allowed = {link['url'] for page in pages.values() for link in page['links']}
asset_routes = {'/assets/' + urlsplit(url).netloc + urlsplit(url).path: asset
                for url, asset in frozen['assets'].items()}
donation = next(page for page in pages.values() if page['name'] == 'credits')['forms'][0]


def fixture_page(page):
    raw = (root / page['file']).read_text()

    def resource(match):
        absolute = urljoin(page['original_url'], html.unescape(match[2]))
        assert absolute in frozen['assets']
        return match[1] + '/assets/' + urlsplit(absolute).netloc + urlsplit(absolute).path + '"'

    raw = re.sub(r'(<(?:img|script)\b[^>]*?\bsrc=")([^"]+)"', resource, raw)
    raw = re.sub(r'(<link\b[^>]*?\bhref=")([^"]+)"', resource, raw)

    def anchor(match):
        if match[2] == '#':
            return match[0]  # The original onclick still submits the local form.
        absolute = urljoin(page['original_url'], html.unescape(match[2]))
        assert absolute in allowed
        return match[1] + '/out?url=' + quote(absolute, safe='') + '"'

    raw = re.sub(r'(<a\b[^>]*?\bhref=")([^"]+)"', anchor, raw)
    raw = raw.replace('action="https://www.paypal.com/cgi-bin/webscr"', 'action="/donation"')
    return raw.encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def send(self, data, kind='text/html'):
        self.send_response(200)
        self.send_header('Content-Type', kind + ('; charset=utf-8' if kind.startswith('text/') else ''))
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        route = urlsplit(self.path)
        path = unquote(route.path)
        if path == '/out':
            original = parse_qs(route.query).get('url', [''])[0]
            if original not in allowed:
                self.send_error(400)
                return
            self.send(('<!doctype html><meta name="viewport" content="width=device-width">'
                       '<h1>Frozen guide destination</h1><p>' + html.escape(original) + '</p>').encode())
        elif path in pages:
            self.send(fixture_page(pages[path]))
        elif path in asset_routes:
            file = root / asset_routes[path]['file']
            self.send(file.read_bytes(), mimetypes.guess_type(str(file))[0] or 'application/octet-stream')
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if self.path != '/donation' or not 0 < length < 8192:
            self.send_error(400)
            return
        fields = parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        expected = {field['name']: [field['value']] for field in donation['fields']}
        if fields != expected:
            self.send_error(400, 'Unexpected donation fields')
            return
        print(json.dumps(dict(event='inert-donation', fields=fields)), flush=True)
        self.send(b'<!doctype html><meta name="viewport" content="width=device-width">'
                  b'<h1>Frozen donation submission</h1><p>No payment or external request occurred.</p>')

    def log_message(self, fmt, *values):
        print(json.dumps(dict(path=self.path, result=fmt % values)), flush=True)


if __name__ == '__main__':
    for page in pages.values():
        (root / ('served-' + page['file'])).write_bytes(fixture_page(page))
    http.server.HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
