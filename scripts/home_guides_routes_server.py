#!/usr/bin/env python3
"""Inert outgoing transport allowlisted from the exact bundled native document."""
import argparse
import html
import http.server
import json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--document', required=True, type=Path)
parser.add_argument('--port', type=int, default=18948)
args = parser.parse_args()
document = json.loads(args.document.read_text())
allowed = {r['destination'] for page in document['pages'].values()
           for section in page['sections'] for r in section['rows'] if r['kind'] == 'link'
           and urlsplit(r['destination']).scheme in ('http', 'https')}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path)
        original = parse_qs(path.query).get('url', [''])[0]
        if path.path != '/out' or original not in allowed:
            self.send_error(400)
            return
        data = ('<!doctype html><meta name="viewport" content="width=device-width">'
                '<h1>Frozen native guide destination</h1><p>' + html.escape(original) + '</p>'
                '<p>No payment, mail or external request occurred.</p>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)
        print(json.dumps(dict(event='destination', url=original)), flush=True)

    def log_message(self, fmt, *values):
        print(json.dumps(dict(path=self.path, result=fmt % values)), flush=True)


http.server.HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
