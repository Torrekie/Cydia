#!/usr/bin/env python3
"""Finite Copying Files content checks; no UI, routing, or network evidence."""
import copy
import json
from pathlib import Path
import re
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DOCUMENT = json.loads((ROOT / "MobileCydia.app/CopyingFilesGuide.json").read_text())
BASELINE = json.loads((ROOT / "tests/fixtures/ui/copying-files-baseline.json").read_text())
SECTION_IDS = ["intro", "packages", "desktop"]


def normalized(value):
    return re.sub(r"\s+", " ", value).strip()


def validate(document):
    assert document["schema"] == 1
    sections = document["sections"]
    assert [section["id"] for section in sections] == SECTION_IDS
    assert all(len(section["rows"]) == 1 for section in sections)
    rows = [section["rows"][0] for section in sections]
    assert [row["id"] for row in rows] == ["copying-files-" + key for key in SECTION_IDS]
    assert all(row["kind"] == "text" for row in rows), "Inline links must not become invented cells"
    for row in rows:
        assert row["text"] == "".join(run["text"] for run in row["runs"])

    # Compare actual first-party prose, not the former migration's paraphrases.
    paragraphs = [paragraph for row in rows for paragraph in row["text"].split("\n\n")]
    assert [normalized(value) for value in paragraphs] == [
        normalized(value) for value in BASELINE["original_paragraphs"]]
    assert len(paragraphs) == 14
    runs = [run for row in rows for run in row["runs"]]
    actual_targets = [run["link"] for run in runs if "link" in run]
    expected_targets = ["cydia://package/" + link["package"] if link["kind"] == "package"
                        else "cydia://home/root-password" if link["kind"] == "neighbor-home-root"
                        else link["url"] for link in BASELINE["original_links"]]
    assert actual_targets == expected_targets
    assert len(actual_targets) == 12
    for target in actual_targets:
        parsed = urlsplit(target)
        assert (parsed.scheme == "cydia" and (parsed.netloc == "package" or
                target == "cydia://home/root-password")) or (
            parsed.scheme in ("http", "https") and parsed.netloc)

    bold = [run["text"] for run in runs if run.get("bold")]
    for label in ["Getting Files to/from Your Device", "Cydia Packages",
                  "Secure Copy Protocol", "Apple Filing Protocol", "On Device",
                  "Desktop Applications", "DiskAid", "iExplorer", "iPhoneBrowser",
                  "Phone Disk", "PhoneView"]:
        assert any(label in value for value in bold), "Lost emphasis: " + label
    assert any(run.get("italic") and "If you jailbroke" in run["text"] for run in runs)
    assert "\nCyberduck (Mac):" in rows[1]["text"]
    assert "\nWinSCP (Windows):" in rows[1]["text"]


class CopyingFilesGuideContentTests(unittest.TestCase):
    def test_exact_ordered_rich_content(self):
        validate(DOCUMENT)

    def test_lost_link_or_emphasis_is_detected(self):
        changed = copy.deepcopy(DOCUMENT)
        linked = next(run for run in changed["sections"][1]["rows"][0]["runs"] if "link" in run)
        del linked["link"]
        with self.assertRaises(AssertionError):
            validate(changed)
        changed = copy.deepcopy(DOCUMENT)
        for run in changed["sections"][0]["rows"][0]["runs"]:
            run.pop("bold", None)
        with self.assertRaises(AssertionError):
            validate(changed)

    def test_invented_standalone_action_is_detected(self):
        changed = copy.deepcopy(DOCUMENT)
        changed["sections"][1]["rows"].append({"id": "openssh", "kind": "link",
            "text": "OpenSSH", "destination": "cydia://package/openssh"})
        with self.assertRaises(AssertionError):
            validate(changed)


if __name__ == "__main__":
    unittest.main()
