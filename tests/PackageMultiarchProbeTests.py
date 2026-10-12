#!/usr/bin/env python3
"""Exercise an already running package-detail simulator probe via its markers.

Usage: PackageMultiarchProbeTests.py APP_DATA/tmp/cydia-package-detail-probe.plist
Launch Cydia with --cydia-appearance-probe --cydia-package-detail-probe first.
This check does not build, launch, install, change dpkg or write probe exports.
"""
import argparse
import json
import pathlib
import plistlib
import re
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("state", type=pathlib.Path)
    parser.add_argument("--locale", default="en", help="Simulator's active Cydia locale")
    args = parser.parse_args()
    assert args.state.name == "cydia-package-detail-probe.plist", "Expected the package-detail probe state"
    assert args.state.is_file(), "Launch the existing package-detail simulator probe first"
    table_path = ROOT / "MobileCydia.app" / (args.locale + ".lproj") / "Actions.strings"
    table = {json.loads(key): json.loads(value) for key, value in ENTRY.findall(table_path.read_text())}

    def read():
        try:
            with args.state.open("rb") as stream:
                return plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException):
            return {}

    def marker(name, predicate):
        path = args.state.parent / ("cydia-package-detail-probe-" + name)
        path.touch(exist_ok=False)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                state = read()
                if not path.exists() and state.get("ready") and predicate(state):
                    return state
                time.sleep(0.1)
            raise AssertionError("Probe did not settle after " + name)
        finally:
            # Remove only the marker created by this invocation if it was not consumed.
            path.unlink(missing_ok=True)

    cases = {
        "arch-native": ("iphoneos-arm64", "PACKAGE_ARCHITECTURE_NATIVE"),
        "arch-foreign": ("iphoneos-arm", "PACKAGE_ARCHITECTURE_FOREIGN"),
        "arch-all": ("all", "PACKAGE_ARCHITECTURE_ALL"),
        "arch-single": ("iphoneos-arm64", None),
        "arch-single-all": ("all", None),
        "arch-unsupported": ("unsupported", "PACKAGE_ARCHITECTURE_UNSUPPORTED_LABEL"),
    }
    for phase, (architecture, key) in cases.items():
        expected = table[key].replace("%@", architecture) if key else ""
        state = marker(phase, lambda value: value.get("phase") == phase)
        assert state["architecture"] == architecture, phase
        assert state["displayName"] == "Runtime Package", "Caption changed raw display name"
        assert state["navigationURL"] == "cydia://package/runtime:" + architecture, phase
        assert state["architectureCaption"] == expected, (phase, state["architectureCaption"])
        assert state["architectureCaptionVisible"] == bool(expected), phase
        assert state["headerLabelsFit"], "Header clipping in " + phase
        if phase == "arch-unsupported":
            assert not state["primaryModifyKey"], "Unsupported fixture offered an install action"
        identifier = "cydia.package.header.architecture"
        assert (identifier in state["accessibilityOrder"]) == bool(expected), phase
        if expected:
            element = next(value for value in state["accessibilityElements"] if value["identifier"] == identifier)
            assert element["label"] == expected, phase
        if phase != "arch-unsupported":
            state = marker("versions", lambda value: value.get("modifySheetVisible"))
            versions = [title for title in state["modifyActionTitles"] if title.startswith("2:0.9")]
            assert len(versions) == 1, (phase, state["modifyActionTitles"])
            if expected:
                assert expected in versions[0], phase
            else:
                assert "iphoneos-" not in versions[0] and " · all" not in versions[0], phase
            marker("dismiss", lambda value: not value.get("modifySheetVisible"))
        print("[package-multiarch-probe] PASS:", phase)

    marker("arch-all", lambda value: value.get("phase") == "arch-all")
    state = marker("accessibility", lambda value: value.get("contentSize") == "accessibility-large")
    assert state["headerLabelsFit"], "Architecture caption clips at accessibility text size"
    print("[package-multiarch-probe] PASS: architecture caption at accessibility text size")
    state = marker("unavailable", lambda value: bool(value.get("unavailableProbe")))
    results = state["unavailableProbe"]
    assert results["passed"], results
    assert len(results["cases"]) == 5, results
    assert state["visibleControllerClass"] == "PackageUnavailableController", state["visibleControllerClass"]
    print("[package-multiarch-probe] PASS: five unavailable states, exact alternatives, accessibility, owned snapshots, reload")


if __name__ == "__main__":
    main()
