#!/usr/bin/env python3
"""One-time reviewed migration: frozen markup -> native data, never runtime HTML.

Prints an apply_patch document. It does not fetch URLs or execute tutorial text.
Artwork is copied separately byte-for-byte from the sealed input packet.
"""
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlencode, urljoin, urlsplit

baseline = Path(sys.argv[1])
repo = Path(__file__).resolve().parent.parent
frozen = json.loads((baseline / 'frozen-inputs.json').read_text())
names = {'openssh': ('openssh', 'HOME_OPENSSH_HELP', 'OpenSSH Access How-To'),
         'password': ('root-password', 'HOME_ROOT_PASSWORD_HELP', 'Root Password How-To'),
         'developing': ('developer-resources', 'HOME_DEVELOPER_RESOURCES', 'Developer Resources'),
         'credits': ('credits', 'HOME_CREDITS_THANK_YOU', 'Credits / Thank You'),
         'privacy': ('privacy', 'HOME_PRIVACY_POLICY', 'Privacy Policy')}


class Tree(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = dict(tag='root', attrs={}, children=[])
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = dict(tag=tag, attrs=dict(attrs), children=[])
        self.stack[-1]['children'].append(node)
        if tag not in ('meta', 'link', 'img', 'input', 'br', 'hr'):
            self.stack.append(node)

    def handle_endtag(self, tag):
        assert self.stack[-1]['tag'] == tag, tag
        self.stack.pop()

    def handle_data(self, data):
        self.stack[-1]['children'].append(data)


def nodes(node, tag):
    if isinstance(node, str):
        return []
    return ([node] if node['tag'] == tag else []) + sum((nodes(c, tag) for c in node['children']), [])


def runs(node, flags=None):
    flags = dict(flags or {})
    if isinstance(node, str):
        return [dict(text=re.sub(r'\s+', ' ', node).replace('\x99', '™'), **flags)]
    if node['tag'] == 'br':
        return [dict(text='\n', **flags)]
    a = node['attrs']
    if node['tag'] == 'strong' or 'font-weight:bold' in a.get('style', '') or a.get('class') == 'update':
        flags['bold'] = True
    if node['tag'] == 'em':
        flags['italic'] = True
    if a.get('class') == 'obsolete':
        flags['obsolete'] = True
    return sum((runs(c, flags) for c in node['children']), [])


def text(node):
    return ''.join(r['text'] for r in runs(node)).strip()


pages = {}
for page in frozen['pages']:
    raw = (baseline / page['file']).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == page['sha256']
    tree = Tree()
    tree.feed(raw.decode())
    member, title_key, title = names[page['name']]
    sections = []
    serial = [0]

    def row(kind, node=None, body=None, **extra):
        serial[0] += 1
        value = dict(id='%s-%03d' % (member, serial[0]), kind=kind,
                     text=text(node) if node is not None else body, **extra)
        if node is not None and kind in ('text', 'heading'):
            value['runs'] = runs(node)
        return value

    def action(anchor):
        url = urljoin(page['original_url'], anchor['attrs']['href'])
        if anchor['attrs'].get('onclick'):
            fields = {f['name']: f['value'] for f in page['forms'][0]['fields']}
            url = page['forms'][0]['attributes']['action'] + '?' + urlencode(fields)
        elif urlsplit(url).path == '/password.html' and urlsplit(url).hostname == 'cydia.saurik.com':
            url = 'cydia://home/root-password'
        elif urlsplit(url).path == '/openssh.html' and urlsplit(url).hostname == 'cydia.saurik.com':
            url = 'cydia://home/openssh'
        elif urlsplit(url).path.startswith('/package/') and urlsplit(url).hostname == 'cydia.saurik.com':
            url = 'cydia://package/' + urlsplit(url).path.split('/')[-1]
        images = nodes(anchor, 'img')
        icon = {'icon': 'HomeGuideAssets/' + Path(images[0]['attrs']['src']).name} if images else {}
        return row('link', anchor, destination=url, **icon)

    def render(node):
        if isinstance(node, str):
            assert not node.strip()
            return []
        if node['tag'] == 'fieldset' and node['attrs'].get('class') == 'terminal':
            # Preserve original command transcript line breaks, never execute.
            return [row('terminal', body='\n'.join(line.strip() for line in text(node).splitlines()))]
        if node['tag'] == 'a' and 'href' in node['attrs']:
            return [action(node)]
        if node['tag'] == 'p':
            links = nodes(node, 'a')
            if member == 'credits' and len(links) == 25:
                targets = {text(a): a for a in links}
                return [action(targets[name]) if name in targets else row('text', body=name)
                        for name in text(node).split(', ')]
            heading = len(node['children']) == 1 and not isinstance(node['children'][0], str) and node['children'][0]['tag'] == 'strong'
            value = row('heading' if heading else 'text', node)
            images = nodes(node, 'img')
            if images:
                value['icon'] = 'HomeGuideAssets/' + Path(images[0]['attrs']['src']).name
                value['image_description'] = 'Network details button'
            return [value] + [action(a) for a in links]
        if node['tag'] == 'label':
            return [row('heading', node)]
        return sum((render(c) for c in node['children']), [])

    if member in ('openssh', 'root-password'):
        sections.append(dict(rows=[row('text', body='Historical Cydia instructions. Account names, passwords and supported tools depend on your jailbreak. These examples are documentation only; Cydia does not run them or change passwords. Verify a new SSH host key before accepting it.')]))
    elif member == 'privacy':
        sections.append(dict(rows=[row('text', body='Original Cydia privacy policy by Jay Freeman (saurik), updated May 24, 2018. Historical statements, struck-out obsolete passages and later annotations are preserved below; they are not new claims about this fork or third-party services.')]))
    for child in nodes(tree.root, 'panel')[0]['children']:
        rows = render(child)
        if rows:
            sections.append(dict(rows=rows))
    pages[member] = dict(title=title, title_key=title_key, source_url=page['original_url'],
                         source_sha256=page['sha256'], sections=sections)

document = dict(schema=1, attribution='Original guide, credits and policy content: Jay Freeman (saurik) / Cydia. Native arrangement and historical context: Torrekie.', pages=pages)
target = repo / 'MobileCydia.app/HomeGuides.json'
assert not target.exists(), 'Review existing data instead of overwriting it'
print('*** Begin Patch\n*** Add File: ' + str(target))
print('\n'.join('+' + line for line in json.dumps(document, indent=2, ensure_ascii=False).splitlines()))
print('*** End Patch')
