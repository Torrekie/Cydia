#!/usr/bin/env python3
"""Finite native-data validation with independently frozen original semantics."""
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
DATA = json.loads((ROOT / 'MobileCydia.app/HomeGuides.json').read_text())
BASELINE = json.loads((ROOT / 'tests/fixtures/ui/home-guides-baseline.json').read_text())
MEMBERS = {'openssh': 'openssh', 'root-password': 'password', 'developer-resources': 'developing',
           'credits': 'credits', 'privacy': 'privacy'}


def rows(member):
    return [r for s in DATA['pages'][member]['sections'] for r in s['rows']]


def links(member):
    result = []
    for row in rows(member):
        if row['kind'] == 'link':
            result.append({'text': row['text'], 'destination': row['destination']})
        result.extend({'text': run['text'], 'destination': run['link']}
                      for run in row.get('runs', []) if 'link' in run)
    return result


def rendered_text(member):
    parts = []
    for section in DATA['pages'][member]['sections']:
        if section.get('title'):
            parts.append(section['title'])
        parts.extend(row['text'] for row in section['rows'])
    return '\n\n'.join(parts)


class HomeGuideContentTests(unittest.TestCase):
    def test_finite_schema_and_native_targets(self):
        self.assertEqual(DATA['schema'], 1)
        self.assertEqual(set(DATA['pages']), set(MEMBERS))
        ids = []
        for member, page in DATA['pages'].items():
            self.assertTrue(page['title_key'].startswith('HOME_'))
            for r in rows(member):
                ids.append(r['id'])
                self.assertRegex(r['id'], r'^[a-z0-9-]+$')
                self.assertIn(r['kind'], ('text', 'link', 'heading', 'terminal'))
                self.assertTrue(r['text'].strip())
                if 'runs' in r:
                    self.assertEqual(''.join(t['text'] for t in r['runs']).strip(), r['text'])
                destinations = ([r['destination']] if 'destination' in r else []) + [
                    run['link'] for run in r.get('runs', []) if 'link' in run]
                for destination in destinations:
                    u = urlsplit(destination)
                    self.assertIn(u.scheme, ('cydia', 'http', 'https', 'mailto'))
                    if u.scheme == 'cydia':
                        self.assertIn(destination, ('cydia://package/openssh', 'cydia://home/openssh', 'cydia://home/root-password'))
                    self.assertNotEqual(u.hostname, 'cydia.saurik.com', 'No owned guide web fallback')
                assets = ([r['icon']] if 'icon' in r else []) + [
                    run['image'] for run in r.get('runs', []) if 'image' in run]
                for asset in assets:
                    path = ROOT / 'MobileCydia.app' / asset
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), BASELINE['icons'][path.name])
        self.assertEqual(len(ids), len(set(ids)))

    def test_original_content_and_link_order_retained(self):
        for member, original in MEMBERS.items():
            baseline = BASELINE['pages'][original]
            self.assertEqual(DATA['pages'][member]['source_sha256'], baseline['sha256'])
            actual_links = links(member)
            self.assertEqual(len(actual_links), len(baseline['links']))
            self.assertEqual([r['text'] for r in actual_links], [l['text'].replace('\x99', '™') for l in baseline['links']])
            for row, link in zip(actual_links, baseline['links']):
                target = link['url']
                if link['kind'] == 'package': target = 'cydia://package/openssh'
                if link['kind'] == 'neighbor-home-root': target = 'cydia://home/' + ('root-password' if '/password.html' in target else 'openssh')
                if link['kind'] != 'donation-form': self.assertEqual(row['destination'], target)
            # Preserve the exact authored paragraphs in order without forcing
            # one table row per paragraph or turning inline anchors into rows.
            text = rendered_text(member)
            cursor = 0
            for paragraph in baseline['paragraphs']:
                paragraph = paragraph.replace('\x99', '™')
                position = text.find(paragraph, cursor)
                self.assertGreaterEqual(position, cursor, (member, paragraph))
                cursor = position + len(paragraph)

    def test_original_blocks_and_inline_anchors(self):
        self.assertEqual(len(DATA['pages']['openssh']['sections'][1]['rows']), 9)
        self.assertEqual([r['text'] for r in rows('openssh') if r['kind'] == 'link'],
                         ['Change Default Password'])
        self.assertEqual(len(rows('credits')), 2)
        names = BASELINE['pages']['credits']['paragraphs'][-1]
        self.assertEqual(rows('credits')[-1]['text'].split('\n\n')[-1], names)
        privacy = DATA['pages']['privacy']['sections']
        self.assertEqual(len(privacy), 10)
        self.assertTrue(all(section.get('title') and len(section['rows']) == 1
                            for section in privacy[1:]))
        self.assertFalse(any(r['kind'] == 'link' for r in rows('privacy')))
        self.assertEqual(sum(run.get('text') == '\ufffc' and bool(run.get('image'))
                             for row in rows('openssh') for run in row.get('runs', [])), 1)
        note = next(run for row in rows('root-password') for run in row.get('runs', [])
                    if run['text'].startswith('Note: this first step'))
        self.assertTrue(note['italic'])

    def test_inert_transcripts_and_obsolete_policy(self):
        transcripts = [r['text'] for r in rows('root-password') if r['kind'] == 'terminal']
        self.assertEqual(len(transcripts), 3)
        for actual, expected in zip(transcripts, BASELINE['terminals']):
            # HTML whitespace after <br> collapses; the freeze includes both
            # the explicit break and source-file newline. Compare rendered lines.
            self.assertEqual([s.strip() for s in actual.splitlines() if s.strip()],
                             [s.strip() for s in expected.splitlines() if s.strip()])
        obsolete = [r['text'] for row in rows('privacy') for r in row.get('runs', []) if r.get('obsolete')]
        self.assertEqual(''.join(obsolete), ''.join(BASELINE['obsolete']))
        donation = next(r for r in rows('credits') if r['kind'] == 'link')
        self.assertEqual(urlsplit(donation['destination']).hostname, 'www.paypal.com')
        self.assertEqual(parse_qs(urlsplit(donation['destination']).query),
                         {k: [v] for k, v in BASELINE['donation'].items()})


if __name__ == '__main__':
    unittest.main()
