#!/usr/bin/env python3
"""Freeze one guide and bounded assets. Adjacent Home roots are not crawled."""
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
        self.assets, self.links, self.paragraphs, self.scripts = set(), [], [], []
        self.link = self.paragraph = self.script = None
    def handle_starttag(self, tag, pairs):
        a = dict(pairs)
        assert not any(k.startswith('on') for k in a), 'New event behavior needs review'
        resource = a.get('src') if tag in ('img', 'script') else a.get('href') if tag == 'link' else None
        if resource: self.assets.add(resource)
        if tag == 'a': self.link = dict(href=a['href'], text=[])
        if tag == 'p': self.paragraph = []
        if tag == 'br' and self.paragraph is not None: self.paragraph.append('\n')
        if tag == 'script' and not resource: self.script = []
        assert tag not in ('form', 'input', 'button', 'iframe'), 'New interactive scope'
    def handle_data(self, data):
        if self.link is not None: self.link['text'].append(data)
        if self.paragraph is not None: self.paragraph.append(data)
        if self.script is not None: self.script.append(data)
    def handle_endtag(self, tag):
        if tag == 'a' and self.link is not None:
            self.link['text'] = ''.join(self.link['text']).strip()
            url = urljoin('https://cydia.saurik.com/copying.html', self.link['href'])
            parsed = urlsplit(url)
            self.link['url'] = url
            if parsed.netloc == 'cydia.saurik.com' and parsed.path.startswith('/package/'):
                self.link['kind'] = 'package'; self.link['package'] = parsed.path.split('/')[-1]
            elif parsed.netloc == 'cydia.saurik.com':
                assert parsed.path == '/password.html', 'Unknown owned child needs review'
                self.link['kind'] = 'neighbor-home-root'; self.link['member'] = 'root-password'
            else: self.link['kind'] = 'external-browser'
            self.links.append(self.link); self.link = None
        if tag == 'p' and self.paragraph is not None:
            self.paragraphs.append(''.join(self.paragraph).strip()); self.paragraph = None
        if tag == 'script' and self.script is not None:
            self.scripts.append(''.join(self.script)); self.script = None

root = Path(sys.argv[1]).resolve()
assert not (root / 'frozen-inputs.json').exists()
raw = (root / 'copying.html').read_bytes()
page = Page(); page.feed(raw.decode())
assert len(page.paragraphs) == 14 and len(page.links) == 12
assert [l['package'] for l in page.links if l['kind'] == 'package'] == ['openssh', 'netatalk', 'eu.heinelt.ifile', 'com.saurik.afc2d']
assert len(page.scripts) == 1 and 'document.title=title.substring(0,dot)' in page.scripts[0]
origin = 'https://cydia.saurik.com'; pending, done = sorted(page.assets), {}
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
result = dict(source='543b80448890667e787580bdc60614ea196c300a', original_url=origin + '/copying.html',
    html_sha256=hashlib.sha256(raw).hexdigest(), owned_pages=['/copying.html'], owned_children=[],
    neighboring_home_edges=['/password.html'], paragraphs=page.paragraphs, links=page.links,
    inline_scripts=page.scripts, assets=list(done.values()),
    behavior='Informational guide with12 anchors:4 package references,7 desktop-tool browser links,1 adjacent Root Password Home member. No data/command/mutation controls; inline script shortens title for Cydia user agent. Shared cytyle JavaScript conditionally rewrites package URLs to cydia://package/ when a Cydia bridge exists; Safari before renderer lacks that bridge. Preserve package targets natively. Historical tool compatibility/prices are original claims, not current recommendations.')
(root / 'frozen-inputs.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(dict(pages=1, children=0, paragraphs=14, package_links=4, external_links=7, neighbor_edges=1, assets=len(done))))
