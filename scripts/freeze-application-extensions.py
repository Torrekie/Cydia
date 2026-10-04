#!/usr/bin/env python3
"""Freeze only the two Application Extensions layouts and their asset inputs.

Root HTML and count JSON are captured separately with response headers. Child
samples are complete pages, not trimmed package lists. This is not a site crawl.
"""
import concurrent.futures
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request

class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.assets, self.rows = set(), []
        self.row, self.field, self.text = None, None, []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("img", "script") and attrs.get("src", "").startswith("/"):
            self.assets.add(attrs["src"])
        if tag == "link" and attrs.get("href", "").startswith("/"):
            self.assets.add(attrs["href"])
        if tag == "a" and attrs.get("href", "").startswith("http://cydia.saurik.com/package/"):
            self.row = {"package": attrs["href"].rsplit("/", 1)[-1], "url": attrs["href"]}
        if self.row is not None:
            if tag == "img":
                self.row["icon"] = attrs.get("src")
            if tag in ("label", "span"):
                self.field = attrs.get("class", "").split()[0]
                self.text = []
    def handle_data(self, data):
        if self.row is not None and self.field:
            self.text.append(data)
    def handle_endtag(self, tag):
        if tag in ("label", "span") and self.row is not None and self.field:
            self.row[self.field] = "".join(self.text).strip()
            self.field = None
        if tag == "a" and self.row is not None:
            self.rows.append(self.row)
            self.row, self.field = None, None

def main():
    root = Path(sys.argv[1]).resolve()
    if not (root / "iphone.html").is_file() or (root / "frozen-inputs.json").exists():
        raise SystemExit("Require captured root; never overwrite a sealed freeze")
    pages, assets = {}, {"/cytyle/closebox@2x.png"}
    for name in ("iphone", "ipad", "safari", "mail"):
        parser = Page()
        parser.feed((root / (name + ".html")).read_text())
        pages[name] = parser.rows
        assets.update(parser.assets)
    def fetch(path):
        output = root / "assets" / path.lstrip("/")
        output.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request("https://cydia.saurik.com" + path)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                data = response.read(4 * 1024 * 1024 + 1)
                if len(data) > 4 * 1024 * 1024:
                    raise ValueError("oversized asset")
                output.write_bytes(data)
                return {"path": path, "status": response.status,
                        "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        except (urllib.error.URLError, ValueError) as error:
            return {"path": path, "error": str(error)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(fetch, sorted(assets)))
    counts = json.loads((root / "api-application.json").read_text())
    assert len(pages["safari"]) == counts["com.apple.mobilesafari"]
    assert len(pages["mail"]) == counts["com.apple.mobilemail"]
    assert all(row.get("title") and row.get("package") for rows in pages.values() for row in rows)
    result = {"source": "aeed89135c616453064d6e73f532b83f0a9a2fc5",
              "root_html_identical": (root / "iphone.html").read_bytes() == (root / "ipad.html").read_bytes(),
              "catalog_app_count": len(counts), "pages": pages, "assets": results}
    (root / "frozen-inputs.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"catalog_apps": len(counts), "safari_rows": len(pages["safari"]),
                      "mail_rows": len(pages["mail"]), "assets": len(results),
                      "asset_errors": [x for x in results if "error" in x]}, indent=2))
if __name__ == "__main__":
    main()
