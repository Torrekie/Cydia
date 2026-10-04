#!/usr/bin/env python3
"""Finite guide content/asset checks, not rendered UI or dispatch evidence."""
import argparse
import copy
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import struct
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "cydia://home/upgrading-jailbreaking/"
EXPECTED_PAGES = set("root tools news shsh taig pangu8 pangu evasi0n7 p0sixspwn "
                     "evasi0n redsn0w absinthe2 pwnagetool absinthe jailbreakme "
                     "greenpois0n spirit blackra1n purplera1n quickpwn-mac quickpwn-win".split())
BASELINE = json.loads((ROOT / "tests/fixtures/ui/upgrading-guide-baseline.json").read_text())
DOCUMENT = json.loads((ROOT / "MobileCydia.app/UpgradingGuide.json").read_text())
ASSET_DIR = ROOT / "MobileCydia.app/GuideAssets"


def native_destination(href):
    if href.endswith(".html") and "/" not in href:
        return PREFIX + href[:-5]
    if href == "http://cydia.saurik.com/package/com.saurik.impactor":
        return "cydia://package/com.saurik.impactor"
    return href


def validate(document):
    assert document["schema"] == 1
    pages = document["pages"]
    assert set(pages) == EXPECTED_PAGES == set(BASELINE), "finite page set"
    for name, page in pages.items():
        assert page["title"].strip() and page["body"].strip(), (name, "missing content")
        links = page["links"]
        assert [link["destination"] for link in links] == [
            native_destination(href) for href in BASELINE[name]["links"]
        ], (name, "ordered legacy link preservation")
        ids = [link["id"] for link in links]
        assert len(ids) == len(set(ids)), (name, "duplicate action/localization key")
        resources = page.get("displayResources", ids)
        assert len(resources) == len(set(resources)) and set(resources) <= set(ids), (
            name, "unknown or duplicate displayed resource")
        if "bodyParts" in page:
            assert all(part.strip() for part in page["bodyParts"]), (name, "empty article block")
            assert len(page["bodyParts"]) == len(page["bodyRuns"]), (name, "missing rich article runs")
            for part, runs in zip(page["bodyParts"], page["bodyRuns"]):
                assert all(run["text"] in part for run in runs), (name, "rich span outside article")
        assert all(re.fullmatch(r"[a-z0-9-]+", key) for key in ids)
        for link in links:
            assert link["title"].strip(), (name, "missing link label")
            destination = link["destination"]
            if destination.startswith(PREFIX):
                assert destination[len(PREFIX):] in pages, (name, "unknown child")
            else:
                url = urlsplit(destination)
                assert url.scheme in ("https", "http", "cydia") and url.netloc
        assert [link["image"] for link in links if "image" in link] == [
            Path(urlsplit(src).path).stem for src in BASELINE[name]["images"]
        ], (name, "ordered legacy images")
        if "groups" in page:
            groups = page["groups"]
            assert groups and all(group["title"].strip() for group in groups)
            grouped_ids = [identifier for group in groups for identifier in group["links"]]
            assert grouped_ids == [link["id"] for link in links], (name, "ordered groups")
    reachable = {"root"}
    while True:
        expanded = reachable | {link["destination"][len(PREFIX):]
            for name in reachable for link in pages[name]["links"]
            if link["destination"].startswith(PREFIX)}
        if expanded == reachable:
            break
        reachable = expanded
    assert reachable == EXPECTED_PAGES, "unreachable native child"


class InventoryParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links, self.images = [], []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag == "img" and "src" in attrs:
            self.images.append(attrs["src"])


class GuideContentTests(unittest.TestCase):
    baseline_dir = None

    def test_complete_ordered_graph(self):
        validate(DOCUMENT)
        self.assertEqual(len(DOCUMENT["pages"]["root"]["links"]), 7)
        self.assertEqual(len(DOCUMENT["pages"]["tools"]["links"]), 18)

    def test_tools_preserve_description_rows(self):
        links = DOCUMENT["pages"]["tools"]["links"]
        self.assertTrue(all(link.get("detail", "").strip() for link in links))
        self.assertEqual(
            [link["title"] for link in links],
            [
                "TaiG (Windows & Mac)",
                "Pangu 8 (Windows & Mac)",
                "Pangu 7 (Windows & Mac)",
                "evasi0n7 (Windows & Mac)",
                "p0sixspwn (Windows & Mac)",
                "evasi0n (Windows, Mac, & Linux)",
                "redsn0w (Windows & Mac)",
                "Absinthe 2.0 (Windows, Mac, and Linux)",
                "PwnageTool (Mac)",
                "Absinthe 0.4 (Windows, Mac, and Linux)",
                'JailbreakMe.com "Saffron" (Web)',
                "greenpois0n (Windows & Mac)",
                'JailbreakMe.com "Star" (Web)',
                "Spirit (Windows & Mac)",
                "blackra1n (Windows & Mac)",
                "purplera1n (Windows & Mac)",
                "QuickPwn (Mac)",
                "QuickPwn (Windows)",
            ],
        )
        self.assertEqual(
            links[0]["detail"],
            "Untethered jailbreak for 8.0 through 8.4 on all devices.",
        )
        self.assertEqual(links[-1]["detail"], "2.2.1")

    def test_news_preserves_legacy_groups_and_labels(self):
        news = DOCUMENT["pages"]["news"]
        self.assertEqual(
            [(group["title"], group["links"]) for group in news["groups"]],
            [
                ("Forums", ["reddit"]),
                ("News", ["taig", "pangu", "evad3rs"]),
                ("Guides", ["iclarified", "modmyi", "jailbreakqa"]),
            ],
        )
        self.assertEqual(
            [link["title"] for link in news["links"]],
            [
                "reddit.com/r/jailbreak",
                "@TaiG_Jailbreak on Twitter",
                "@PanguTeam on Twitter",
                "@evad3rs on Twitter",
                "iclarified.com/jailbreak",
                "modmyi.com/jailbreak",
                "jailbreakqa.com/faq",
            ],
        )

    def test_shsh_preserves_article_blocks_and_resource_labels(self):
        shsh = DOCUMENT["pages"]["shsh"]
        self.assertEqual(len(shsh["bodyParts"]), 2)
        self.assertTrue(shsh["bodyParts"][0].startswith(
            "Can I downgrade/upgrade to the firmware version I want?\n\nProbably not"
        ))
        self.assertTrue(shsh["bodyParts"][1].startswith(
            "On devices newer than iPhone 4 and on iOS versions newer than iOS 5"
        ))
        self.assertEqual(
            [link["title"] for link in shsh["links"]],
            [
                "Caching Apple's Signature Server",
                "TinyUmbrella",
                "The iPhone Wiki (SHSH)",
                "Wikipedia (SHSH blob)",
            ],
        )

    def test_tool_detail_pages_preserve_legacy_action_labels(self):
        expected = {
            "taig": ["@TaiG_jailbreak", "TaiG"],
            "pangu8": ["@PanguTeam", "Pangu 8.0-8.1"],
            "pangu": ["Pangu 7.1-7.1.2"],
            "evasi0n7": ["evad3rs (evasi0n7)"],
            "p0sixspwn": ["p0sixspwn"],
            "evasi0n": ["evad3rs (evasi0n)"],
            "redsn0w": ["iPhone Dev Team (redsn0w)", "The iPhone Wiki (IPSW files)"],
            "absinthe2": ["Chronic Dev Team (Absinthe 2.0.4)"],
            "pwnagetool": ["iPhone Dev Team (PwnageTool)", "The iPhone Wiki (IPSW files)"],
            "absinthe": ["Chronic Dev Team (Absinthe 0.4)"],
            "jailbreakme": ["jailbreakme.com/star", "redsn0w", "JailbreakMe"],
            "greenpois0n": ["redsn0w", "redsn0w", "Chronic Dev Team (greenpois0n)"],
            "spirit": ["spiritjb.com"],
            "blackra1n": ["iPhone-Dev Blog (3.1.3 firmware)", "blackra1n.com"],
            "purplera1n": ["purplera1n.com"],
            "quickpwn-mac": ["iPhone-Dev Blog"],
            "quickpwn-win": ["iPhone-Dev Blog"],
        }
        self.assertEqual(
            {name: [link["title"] for link in DOCUMENT["pages"][name]["links"]]
             for name in expected},
            expected,
        )

    def test_recursive_articles_preserve_inline_links_and_resource_rows(self):
        pages = DOCUMENT["pages"]
        children = EXPECTED_PAGES - {"root", "tools", "news", "shsh"}
        for name in children:
            page = pages[name]
            with self.subTest(page=name):
                self.assertEqual(len(page["bodyParts"]), 1)
                self.assertEqual(page["bodyParts"][0], page["body"])
                self.assertEqual(page["resourceTitle"], "Resources")
                self.assertNotIn("Historical", page["body"])
                self.assertNotIn("archived workflow", page["body"])
                self.assertTrue(page["bodyRuns"][0])
        self.assertEqual(pages["root"]["displayResources"], ["tools", "news", "shsh"])
        self.assertEqual(pages["shsh"]["displayResources"], ["tinyumbrella", "iphonewiki", "wikipedia"])
        self.assertEqual(pages["taig"]["displayResources"], ["website"])
        self.assertEqual(pages["jailbreakme"]["displayResources"], ["website"])
        self.assertEqual(pages["greenpois0n"]["displayResources"], ["website"])
        self.assertEqual(pages["blackra1n"]["displayResources"], ["firmware", "website"])
        self.assertIn(
            {"text": "@TaiG_jailbreak", "link": "https://twitter.com/taig_jailbreak"},
            pages["taig"]["bodyRuns"][0],
        )
        redsn0w_links = [run for run in pages["greenpois0n"]["bodyRuns"][0]
                        if run.get("link") == PREFIX + "redsn0w"]
        self.assertEqual(len(redsn0w_links), 2)
        self.assertEqual(pages["taig"]["links"][-1]["subtitle"], "http://www.taig.com/en/")

    def test_authored_compatibility_emphasis_and_paragraphs(self):
        tools = DOCUMENT["pages"]["tools"]["links"]
        self.assertEqual(tools[0]["detailRuns"], [
            {"text": "8.0", "bold": True}, {"text": "8.4", "bold": True},
        ])
        self.assertEqual(tools[12]["detailRuns"], [])  # Star versions were not bold.
        self.assertEqual(tools[6]["detail"].count("\n\n"), 2)
        self.assertEqual(tools[-2]["detail"], tools[-1]["detail"])
        self.assertIn("• iPhone 4 (GSM): 4.1 through 4.2.1", DOCUMENT["pages"]["redsn0w"]["body"])

    def test_root_warning_and_primary_navigation(self):
        root = DOCUMENT["pages"]["root"]
        self.assertEqual([link["id"] for link in root["links"][:3]], ["tools", "news", "shsh"])
        self.assertEqual(
            [link["title"] for link in root["links"][:3]],
            [
                "Which free tools can I use to jailbreak eligible iOS versions?",
                "Where can I find reliable jailbreaking news and help?",
                "Can I upgrade/downgrade iOS to any version? What is SHSH?",
            ],
        )
        self.assertEqual(len(root["bodyParts"]), 3)
        self.assertEqual(
            root["bodyParts"][0],
            "If you upgrade iOS with iTunes, your device will be un-jailbroken and "
            "Cydia packages will be deleted. Before upgrading iOS, make sure a jailbreak "
            "is available for the new version.",
        )
        self.assertTrue(root["bodyParts"][1].startswith("As of September 8, 2015"))
        self.assertIn("No jailbreak for 8.4.1", root["bodyParts"][1])
        self.assertTrue(root["bodyParts"][2].startswith("How do I find my current version?"))
        self.assertEqual(root["bodyRuns"][1][1]["scale"], 1.1)
        self.assertEqual(root["bodyRuns"][1][2]["link"],
                         "cydia://package/com.saurik.impactor")
        self.assertEqual(root["bodyRuns"][2][0]["text"], "How do I find my current version?")

    def test_original_assets(self):
        assets = json.loads((ASSET_DIR / "provenance.json").read_text())["assets"]
        self.assertEqual(set(assets), {"reddit", "web", "iclarified", "modmyi"})
        for name, record in assets.items():
            with self.subTest(asset=name):
                data = (ASSET_DIR / (name + ".png")).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                width, height = struct.unpack(">II", data[16:24])
                self.assertGreater(width, 0)
                self.assertGreater(height, 0)

    def test_lost_child_or_link_is_detected(self):
        # Regression controls: counts alone missed Star and external links.
        for page, index in (("tools", 12), ("news", 6), ("greenpois0n", 1)):
            changed = copy.deepcopy(DOCUMENT)
            del changed["pages"][page]["links"][index]
            with self.subTest(page=page), self.assertRaises(AssertionError):
                validate(changed)

    def test_unknown_child_and_missing_body_are_detected(self):
        changed = copy.deepcopy(DOCUMENT)
        changed["pages"]["tools"]["links"][0]["destination"] = PREFIX + "unknown"
        with self.assertRaises(AssertionError):
            validate(changed)
        changed = copy.deepcopy(DOCUMENT)
        changed["pages"]["root"]["body"] = ""
        with self.assertRaises(AssertionError):
            validate(changed)

    def test_snapshot_inventory(self):
        if self.baseline_dir is None:
            self.skipTest("pass --baseline-dir to verify external frozen HTML")
        for name, expected in BASELINE.items():
            with self.subTest(page=name):
                path = self.baseline_dir / (("index" if name == "root" else name) + ".html")
                raw = path.read_bytes()
                self.assertEqual(hashlib.sha256(raw).hexdigest(), expected["sha256"])
                parser = InventoryParser()
                parser.feed(raw.decode("utf-8"))
                self.assertEqual(parser.links, expected["links"])
                self.assertEqual(parser.images, expected["images"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-dir", type=Path)
    options = parser.parse_args()
    GuideContentTests.baseline_dir = options.baseline_dir
    unittest.main(argv=[__file__])
