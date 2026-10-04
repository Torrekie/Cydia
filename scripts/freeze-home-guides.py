#!/usr/bin/env python3
"""Freeze the finite remaining Home guide/legal roots, never follow page links."""
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urljoin, urlsplit
from urllib.request import urlopen

ORIGIN = 'https://cydia.saurik.com'
PAGES = {'openssh': '/openssh.html', 'password': '/password.html',
         'developing': '/faq/developing.html', 'credits': '/credits.html',
         'privacy': '/policy/privacy/'}
SOURCE = '306a5c397fc92cbbcb2932d01130f80f68c25651'


class Page(HTMLParser):
    def __init__(self, name, path):
        super().__init__(convert_charrefs=True)
        self.name, self.url = name, ORIGIN + path
        self.assets, self.links, self.nodes, self.forms, self.events = set(), [], [], [], []
        self.stack, self.script, self.scripts = [], None, []

    def handle_starttag(self, tag, pairs):
        a = dict(pairs)
        resource = a.get('src') if tag in ('img', 'script') else a.get('href') if tag == 'link' else None
        if resource:
            self.assets.add(urljoin(self.url, resource))
        for key, value in pairs:
            if key.startswith('on'):
                assert self.name == 'credits' and key == 'onclick' and value == 'donate.submit(); return false'
                self.events.append(dict(tag=tag, attribute=key, value=value))
        assert tag not in ('button', 'iframe', 'select', 'textarea'), 'Review new interactive scope'
        if tag == 'form':
            assert self.name == 'credits' and a['action'] == 'https://www.paypal.com/cgi-bin/webscr'
            self.forms.append(dict(attributes=a, fields=[]))
        if tag == 'input':
            assert self.name == 'credits' and a['type'] == 'hidden'
            self.forms[-1]['fields'].append(a)
        if tag == 'a' and 'href' in a:
            url = urljoin(self.url, a['href'])
            parsed = urlsplit(url)
            if a.get('onclick'):
                kind = 'donation-form'
            elif parsed.netloc == 'cydia.saurik.com' and parsed.path.startswith('/package/'):
                kind = 'package'
            elif parsed.netloc == 'cydia.saurik.com':
                assert parsed.path in PAGES.values(), 'Unreviewed owned child'
                kind = 'neighbor-home-root'
            elif parsed.scheme == 'mailto':
                kind = 'external-mail'
            else:
                assert parsed.scheme in ('http', 'https')
                kind = 'external-browser'
            node = dict(tag=tag, attributes=a, text='', url=url, kind=kind)
            self.links.append(node)
            self.stack.append(node)
        elif tag in ('p', 'pre'):
            node = dict(tag=tag, attributes=a, text='')
            self.nodes.append(node)
            self.stack.append(node)
        elif tag in ('span', 'strong', 'em', 'label', 'fieldset'):
            # Keep all semantic/style spans, including partial obsolete text and
            # terminal blocks. Native authored content must not flatten these.
            node = dict(tag=tag, attributes=a, text='')
            self.nodes.append(node)
            self.stack.append(node)
        elif tag == 'br':
            self.handle_data('\n')
        if tag == 'script' and not resource:
            self.script = []

    def handle_data(self, data):
        for node in self.stack:
            node['text'] += data
        if self.script is not None:
            self.script.append(data)

    def handle_endtag(self, tag):
        if self.stack and self.stack[-1]['tag'] == tag:
            node = self.stack.pop()
            node['text'] = node['text'].strip()
        if tag == 'script' and self.script is not None:
            self.scripts.append(''.join(self.script))
            self.script = None


def main():
    root = Path(sys.argv[1]).resolve()
    assert not (root / 'frozen-inputs.json').exists(), 'Preserve sealed inputs'
    pages, pending, assets = [], set(), {}
    for name, path in PAGES.items():
        raw = (root / (name + '.html')).read_bytes()
        page = Page(name, path)
        page.feed(raw.decode())
        assert not page.stack
        assert len(page.scripts) == 1 and 'document.title=title.substring(0,dot)' in page.scripts[0]
        pending.update(page.assets)
        pages.append(dict(name=name, path=path, original_url=page.url, file=name + '.html',
                          sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw),
                          links=page.links, nodes=page.nodes, forms=page.forms,
                          events=page.events, inline_scripts=page.scripts,
                          assets=sorted(page.assets), owned_children=[]))
    while pending:
        url = sorted(pending)[0]
        pending.remove(url)
        if url in assets:
            continue
        parsed = urlsplit(url)
        assert parsed.scheme == 'https' and parsed.netloc in ('cydia.saurik.com', 'cache.saurik.com')
        assert len(assets) < 32 and '..' not in Path(parsed.path).parts
        with urlopen(url, timeout=20) as response:
            assert urlsplit(response.url).netloc == parsed.netloc
            data = response.read(2 * 1024 * 1024 + 1)
            assert len(data) <= 2 * 1024 * 1024
            relative = 'assets/' + parsed.netloc + parsed.path
            dest = root / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            dest.with_name(dest.name + '.headers').write_text(str(response.headers))
        assets[url] = dict(file=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        if parsed.path.endswith('.css'):
            for candidate in re.findall(r'url\([\s\"\']*([^\)\"\']+)', data.decode()):
                if not candidate.startswith('data:'):
                    pending.add(urljoin(url, candidate.strip()))
    result = dict(source=SOURCE, pages=pages, assets=assets, owned_pages=list(PAGES.values()),
                  owned_children=[], commands='Inert documentation; never execute',
                  donation='Preserve exact POST fields; local fixture only, never payment',
                  privacy='Preserve 2018 context, obsolete spans and update annotations')
    (root / 'frozen-inputs.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(pages=len(pages), children=0, assets=len(assets),
                         links={p['name']: len(p['links']) for p in pages})))


if __name__ == '__main__':
    main()
