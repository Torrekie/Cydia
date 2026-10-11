#!/usr/bin/env python3
"""Link the package-action fixture with the existing native APT objects.

Cydia uses private APT APIs hidden from the native shared library. Reuse the
same built objects and dependency libraries rather than changing visibility
or building a second version of APT for this test.
"""
import os
import pathlib
import re
import shlex
import subprocess


def main():
    project = pathlib.Path(__file__).resolve().parent.parent
    build = pathlib.Path(os.environ["APT_INTEGRATION_TESTS_BUILD_DIR"]).resolve()
    commands = subprocess.check_output(
        ["ninja", "-C", str(build), "-t", "commands", "apt-pkg"], text=True
    ).splitlines()
    link = next(shlex.split(line) for line in reversed(commands) if " -shared " in line)
    start = link.index("-shared") + 1
    end = link.index("&&", start) if "&&" in link[start:] else len(link)
    link = link[start:end]
    inputs = [token for index, token in enumerate(link) if (index == 0 or link[index - 1] != "-o") and
              (token.endswith(".o") or
              token.startswith(("-l", "-L")) or re.search(r"\.(?:a|so)(?:\.\d+)*$", token))]
    assert any(token.endswith(".o") for token in inputs), "Native APT object files were not found"
    sources = ["tests/AptBackendPolicyTests.cpp", "Cydia/AptBackend.cpp",
               "Cydia/AptBackendOperations.cpp", "Cydia/AptCompatibility.cpp",
               "Cydia/AptVersionPolicy.cpp", "Cydia/PackageIdentity.cpp",
               "Cydia/RepositorySecurityPolicy.cpp"]
    command = shlex.split(os.environ.get("CXX", "c++")) + [
        "-std=c++17", "-g", "-fsanitize=address", "-fno-omit-frame-pointer",
        "-Wall", "-Wextra", "-I" + str(project),
        "-I" + str(build / "include"),
        "-I" + str(project / "apt64"),
    ] + [str(project / source) for source in sources] + inputs + [
        "-pthread", "-o", str(build / "cydia-package-actions")
    ]
    subprocess.run(command, cwd=build, check=True)


if __name__ == "__main__":
    main()
