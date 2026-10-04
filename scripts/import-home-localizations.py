#!/usr/bin/env python3
"""Emit an apply_patch dump of cached first-party Home translations.

Fetch source pages separately with Accept-Language, naming each downloaded file
<source-locale>.html, then run this importer from the repository root. It never
uses the network or overwrites files; review and apply its printed patch.
Optional Storage downloads are named <source-locale>.storage.html; only their
navigation-button label is translated, so explanatory wording is not imported.
"""

import argparse
import hashlib
import json
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path


SOURCE_URL = "https://cydia.saurik.com/ui/ios~ipad/1.1/home/"
SOURCE_TO_NATIVE = {
    "en-us": "en", "ar": "ar", "de": "de", "el": "el", "es": "es",
    "fr": "fr", "he": "he", "it": "it", "ja": "ja", "ko": "ko",
    "nl": "nl", "pl": "pl", "pt-br": "pt", "pt-pt": "pt-PT", "ru": "ru",
    "sv": "sv", "th": "th", "tr": "tr", "vi": "vi", "zh-cn": "zh-Hans",
    "zh-tw": "zh-Hant",
}
ANCHOR_KEYS = {
    "/featured/": "HOME_FEATURED",
    "/themes/": "HOME_THEMES",
    "/account/": "HOME_MANAGE_ACCOUNT",
    "/upgrading/": "HOME_UPGRADING_HELP",
    "../application/": "HOME_FIND_EXTENSIONS",
    "/sources.html": "MORE_PACKAGE_SOURCES",
    "/questions.html": "FREQUENTLY_ASKED_QUESTIONS",
    "/copying.html": "HOME_COPYING_FILES",
    "/openssh.html": "HOME_OPENSSH_HELP",
    "/password.html": "HOME_ROOT_PASSWORD_HELP",
    "/storage.html": "HOME_STORAGE_INFORMATION",
    "/faq/developing.html": "HOME_DEVELOPER_RESOURCES",
    "/credits.html": "HOME_CREDITS_THANK_YOU",
    "/policy/privacy/": "HOME_PRIVACY_POLICY",
}
VOID_TAGS = frozenset(("area", "base", "br", "col", "embed", "hr", "img",
                       "input", "link", "meta", "param", "source", "track", "wbr"))


@dataclass
class Node:
    tag: str
    attrs: dict = field(default_factory=dict)
    children: list = field(default_factory=list)

    def descendants(self, tag=None):
        for child in self.children:
            if isinstance(child, Node):
                if tag is None or child.tag == tag:
                    yield child
                yield from child.descendants(tag)

    def text(self):
        if self.tag in ("script", "style"):
            return ""
        return "".join(child.text() if isinstance(child, Node) else child
                       for child in self.children)


class HomeParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("document")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs))
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def text(node):
    return re.sub(r"\s+", " ", node.text()).strip()


def only(nodes, description):
    values = list(nodes)
    if len(values) != 1:
        raise ValueError("expected one %s, found %d" % (description, len(values)))
    return values[0]


def extract(data):
    parser = HomeParser()
    parser.feed(data.decode("utf-8"))
    left = only((node for node in parser.root.descendants("panel")
                 if node.attrs.get("class") == "left"), "left Home panel")
    right = only((node for node in parser.root.descendants("panel")
                  if node.attrs.get("class") == "right"), "right Home panel")
    strings = {}
    for href, key in ANCHOR_KEYS.items():
        anchor = only((node for node in left.descendants("a")
                       if node.attrs.get("href") == href), href)
        label = next(anchor.descendants("label"))
        strings[key] = text(label)

    right_headers = [node for node in right.children
                     if isinstance(node, Node) and node.tag == "label"]
    left_headers = [node for node in left.children
                    if isinstance(node, Node) and node.tag == "label"]
    if len(right_headers) != 2 or len(left_headers) != 2:
        raise ValueError("Home section structure changed")
    strings["HOME_IPAD_EXTENSIONS"] = text(right_headers[0])
    strings["HOME_IPAD_PRODUCTS"] = text(right_headers[1])
    strings["USER_GUIDES"] = text(left_headers[0])
    strings["DEVELOPERS_ONLY"] = text(left_headers[1])

    banner = only((node for node in left.descendants("p")
                   if any(anchor.attrs.get("href") == "http://www.saurik.com/"
                          for anchor in node.descendants("a"))), "welcome banner")
    spans = [node for node in banner.children
             if isinstance(node, Node) and node.tag == "span"]
    if len(spans) != 2:
        raise ValueError("Home banner structure changed")
    strings["WELCOME_TO_CYDIA"] = text(spans[0])
    author = only(spans[1].descendants("a"), "banner author")
    if text(author) != "Jay Freeman (saurik)":
        raise ValueError("Home banner author changed")
    # Replace only the brand/person anchor, retaining original adjacent spacing.
    author.children = ["%@"]
    strings["BY"] = text(spans[1])
    badge = only((node for node in left.descendants("label")
                  if node.attrs.get("id") == "badge-featured"), "featured badge")
    strings["HOME_NEW"] = text(badge)
    return dict(sorted(strings.items()))


def extract_storage(data):
    parser = HomeParser()
    parser.feed(data.decode("utf-8"))
    panel = only(parser.root.descendants("panel"), "Storage panel")
    block = only(panel.descendants("block"), "Storage explanation")
    paragraphs = [text(node) for node in block.descendants("p")]
    if len(paragraphs) != 3:
        raise ValueError("Storage explanation structure changed")
    anchor = only((node for node in panel.descendants("a")
                   if node.attrs.get("href") == "/ui/ios/1.1/storage/"), "Storage button")
    return {
        "heading": paragraphs[0], "intro": paragraphs[1],
        "warning": paragraphs[2], "button": text(only(anchor.descendants("label"),
                                                       "Storage button label")),
    }


def strings_text(strings):
    def quote(value):
        return json.dumps(value, ensure_ascii=False)
    lines = ["/* Imported from first-party Home HTML; English entries preserve partial coverage. */"]
    lines.extend("%s = %s;" % (quote(key), quote(value))
                 for key, value in strings.items())
    return "\n".join(lines) + "\n"


def emit_patch(path, content):
    previous = path.read_text(encoding="utf-8") if path.exists() else None
    if previous == content:
        return
    if previous is None:
        print("*** Add File: %s" % path.as_posix())
    else:
        print("*** Update File: %s\n@@" % path.as_posix())
        for line in previous.splitlines():
            print("-" + line)
    for line in content.splitlines():
        print("+" + line)


def main():
    args_parser = argparse.ArgumentParser(description=__doc__)
    args_parser.add_argument("--html-dir", required=True, type=Path,
                             help="directory containing <source-locale>.html downloads")
    args_parser.add_argument("--app-root", default=Path("MobileCydia.app"), type=Path,
                             help="existing application resource directory")
    args_parser.add_argument("--storage-dir", type=Path,
                             help="optional directory containing <source-locale>.storage.html downloads")
    args = args_parser.parse_args()
    downloaded = {}
    hashes = {}
    for path in sorted(args.html_dir.glob("*.html")):
        downloaded[path.stem.lower()] = extract(path.read_bytes())
        hashes[path.stem.lower()] = hashlib.sha256(path.read_bytes()).hexdigest()
    missing = sorted(set(SOURCE_TO_NATIVE) - set(downloaded))
    if missing:
        raise SystemExit("missing required Home downloads: " + ", ".join(missing))
    english = downloaded["en-us"]
    english_aliases = sorted(locale for locale, values in downloaded.items()
                             if values == english)
    datasets = []
    for source_locale, native_locale in SOURCE_TO_NATIVE.items():
        if not (args.app_root / (native_locale + ".lproj")).is_dir():
            raise SystemExit("missing existing native locale: " + native_locale)
        values = downloaded[source_locale]
        datasets.append({
            "source_locale": source_locale,
            "native_locale": native_locale,
            "source_sha256": hashes[source_locale],
            "equivalent_requested_locales": sorted(locale for locale, other in downloaded.items()
                                                   if other == values),
            "translated_keys": [key for key in values if values[key] != english[key]],
            "untranslated_keys": [key for key in values if values[key] == english[key]],
        })
    catalog = {
        "schema_version": 1,
        "source_url": SOURCE_URL,
        "request": {"header": "Accept-Language", "value": "source_locale"},
        "inventory": {
            "method": "Compare extracted visible Home labels against en-us, excluding the echoed footer locale.",
            "requested_locale_count": len(downloaded),
            "iso_639_1_code_count": len([locale for locale in downloaded if len(locale) == 2
                                         and locale not in ("iw", "in", "ji")]),
            "translated_dataset_count": len(datasets) - 1,
            "requested_locales": sorted(downloaded),
            "english_or_untranslated_requests": english_aliases,
        },
        "notes": [
            "The source footer echoes the requested locale even when its text falls back to English; it is not support evidence.",
            "The source uses the first Accept-Language item; later weighted fallback items do not select a translation.",
            "Untranslated keys are retained as explicit English fallback entries, including partial Japanese content.",
            "The original Home application-discovery label and iPad recommendation descriptions remain English; section headings can be translated.",
            "Recommendation descriptions, brand/package names, destinations and URLs are not rewritten by this import.",
            "Native Chinese script identifiers map to source zh-cn/zh-tw; source zh/zh-hans/zh-hant/zh-hk return English.",
            "Source pt equals pt-pt; native pt stores the separate Brazilian pt-br translation.",
        ],
        "keys": sorted(english),
        "locales": datasets,
    }
    if args.storage_dir is not None:
        storage_files = {}
        for source_locale in SOURCE_TO_NATIVE:
            requested_locale = source_locale
            path = args.storage_dir / (source_locale + ".storage.html")
            if not path.exists() and source_locale == "pt-pt":
                requested_locale = "pt"
                path = args.storage_dir / "pt.storage.html"
            if not path.exists():
                raise SystemExit("missing required Storage download: " + path.name)
            storage_files[source_locale] = (requested_locale, path.read_bytes())
        source_english = extract_storage(storage_files["en-us"][1])
        storage_locales = []
        for source_locale, native_locale in SOURCE_TO_NATIVE.items():
            requested_locale, data = storage_files[source_locale]
            values = extract_storage(data)
            if source_locale != "en-us" and values["button"] != downloaded[source_locale]["HOME_STORAGE_INFORMATION"]:
                raise SystemExit("Storage button differs from Home label: " + source_locale)
            for key in ("heading", "intro", "warning"):
                if values[key] != source_english[key]:
                    raise SystemExit("Storage prose has a new translation: " + source_locale)
            storage_locales.append({
                "source_locale": requested_locale,
                "native_locale": native_locale,
                "source_sha256": hashlib.sha256(data).hexdigest(),
                "button_text": values["button"],
                "translated_keys": (["HOME_STORAGE_INFORMATION"]
                                    if values["button"] != source_english["button"] else []),
                "untranslated_content": ["heading", "intro", "warning"],
            })
        catalog["storage"] = {
            "source_url": "https://cydia.saurik.com/storage.html",
            "coverage": "Navigation-button label only; all checked explanatory text remains English.",
            "reused_key": "HOME_STORAGE_INFORMATION",
            "reuse_note": "All 20 non-English button labels equal the corresponding Home label. English Storage differs from Home's Storage Information; it is recorded here, not used to overwrite the native Home label.",
            "english_explanatory_text": {key: source_english[key]
                                         for key in ("heading", "intro", "warning")},
            "locales": storage_locales,
            "metrics_source_url": "https://cydia.saurik.com/ui/ios/1.1/storage/",
            "metrics_notes": "Checked en-us and zh-cn retain English System/Private prose and hardcoded JavaScript category labels; native measurement/status labels are not invented by this import.",
        }
        catalog["other_checked_home_roots"] = {
            "coverage": "English source text for all 20 translated Home datasets; this statement covers direct roots, not recursively linked subpages.",
            "source_urls": [
                "https://cydia.saurik.com/upgrading/",
                "https://cydia.saurik.com/ui/ios~ipad/1.1/application/",
                "https://cydia.saurik.com/sources.html",
                "https://cydia.saurik.com/questions.html",
                "https://cydia.saurik.com/copying.html",
                "https://cydia.saurik.com/openssh.html",
                "https://cydia.saurik.com/password.html",
                "https://cydia.saurik.com/faq/developing.html",
                "https://cydia.saurik.com/credits.html",
                "https://cydia.saurik.com/policy/privacy/",
            ],
        }
        catalog["notes"].append("Storage's non-English translated button reuses the exact Home label; untranslated explanations and metric labels are not new translated content.")
    print("*** Begin Patch")
    for source_locale, native_locale in SOURCE_TO_NATIVE.items():
        emit_patch(args.app_root / (native_locale + ".lproj") / "Home.strings",
                   strings_text(downloaded[source_locale]))
    emit_patch(args.app_root / "HomeLocalizationCatalog.json",
               json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print("*** End Patch")


if __name__ == "__main__":
    main()
