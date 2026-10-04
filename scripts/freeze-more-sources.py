#!/usr/bin/env python3
"""Freeze one captured page and bounded same-origin assets; never crawl links."""
import ast
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urljoin, urlsplit
from urllib.request import urlopen

class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.assets, self.rows, self.blocks = set(), [], []
        self.row = self.block = self.paragraph = None
    def handle_starttag(self, tag, pairs):
        a = dict(pairs)
        asset = a.get('src') if tag in ('img', 'script') else a.get('href') if tag == 'link' else None
        if asset: self.assets.add(asset)
        if tag == 'a':
            assert a.get('href') == '#', 'Changed child/link scope'
            m = re.fullmatch(r"add\('([^']+)', '([^']+)', '([^']+)', (\[[^]]+\])\); return false", a['onclick'])
            assert m, 'Changed original action shape'
            self.row = dict(identifier=a['id'], name=m[1], rooturi=m[2], distribution=m[3], components=ast.literal_eval(m[4]))
        if tag == 'img' and self.row is not None: self.row['icon'] = a['src']
        if tag == 'block': self.block = []
        if tag == 'p' and self.block is not None: self.paragraph = []
    def handle_data(self, text):
        if self.paragraph is not None: self.paragraph.append(text)
    def handle_endtag(self, tag):
        if tag == 'a' and self.row is not None:
            self.rows.append(self.row); self.row = None
        if tag == 'p' and self.paragraph is not None:
            self.block.append(''.join(self.paragraph).strip()); self.paragraph = None
        if tag == 'block': self.blocks.append(self.block); self.block = None

root = Path(sys.argv[1]).resolve()
assert (root / 'sources.html').is_file() and not (root / 'frozen-inputs.json').exists()
raw = (root / 'sources.html').read_bytes()
page = Page(); page.feed(raw.decode())
assert [x['identifier'] for x in page.rows] == ['bigboss', 'modmyi', 'zodttd']
assert [len(b) for b in page.blocks] == [6, 1]
origin = 'https://cydia.saurik.com'
pending, done = sorted(page.assets), {}
while pending:
    asset = pending.pop(0)
    if asset in done: continue
    assert len(done) < 32 and asset.startswith('/') and '..' not in Path(asset).parts
    with urlopen(origin + asset, timeout=20) as response:
        data = response.read(2 * 1024 * 1024 + 1)
        assert len(data) <= 2 * 1024 * 1024 and urlsplit(response.url).netloc == 'cydia.saurik.com'
        dest = root / 'assets' / asset.lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(data)
        dest.with_name(dest.name + '.headers').write_text(str(response.headers))
        done[asset] = dict(path=asset, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    if asset.endswith('.css'):
        for candidate in re.findall(r'url\([\s\"\']*([^\)\"\']+)', data.decode()):
            if candidate.startswith('data:'): continue
            url = urlsplit(urljoin(origin + asset, candidate.strip()))
            assert url.netloc == 'cydia.saurik.com'; pending.append(url.path)
result = dict(source='fd2388825c0df3049be23bc1ee1d820d3b4ab19e', original_url=origin + '/sources.html',
    html_sha256=hashlib.sha256(raw).hexdigest(), owned_pages=['/sources.html'], owned_children=[],
    rows=page.rows, blocks=page.blocks, assets=list(done.values()),
    behavior='Exact rooturi/distribution matching with old ModMyi alias; Confirm addSource(tuple), refreshSources, deferred unload; Cancel no calls; CydiaReloadData reload. No package destination.')
(root / 'frozen-inputs.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(dict(pages=1, children=0, default_rows=3, text_blocks=2, assets=len(done))))
