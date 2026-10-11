#!/usr/bin/env python3
"""Exercise dpkg ownership handoff in disposable installation roots."""

import gzip
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LIBRARY = (ROOT / "Library/shared-config-lifecycle.sh").read_bytes()
DPKG = shutil.which("dpkg")
DIVERT = shutil.which("dpkg-divert")
QUERY = shutil.which("dpkg-query")
CHOWN = shutil.which("chown")
assert DPKG and DIVERT and QUERY and CHOWN, "dpkg, dpkg-divert, dpkg-query, and chown are required"


def tar_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        directories = set()
        for name, _, _ in entries:
            directories.update(str(parent) for parent in Path(name).parents
                               if str(parent) != ".")
        for directory in sorted(directories, key=lambda value: (value.count("/"), value)):
            member = tarfile.TarInfo("./" + directory)
            member.type = tarfile.DIRTYPE
            member.mode = 0o755
            archive.addfile(member)
        for name, contents, mode in entries:
            member = tarfile.TarInfo("./" + name)
            member.mode = mode
            if isinstance(contents, tuple):
                member.type = tarfile.SYMTYPE
                member.linkname = contents[0]
                archive.addfile(member)
            else:
                member.size = len(contents)
                archive.addfile(member, io.BytesIO(contents))
    return gzip.compress(stream.getvalue(), mtime=0)


def write_deb(destination, control, data):
    # Build a deterministic minimal ar package without invoking a host tar or
    # relying on toolchain-specific dpkg-deb build configuration.
    members = [("debian-binary", b"2.0\n"),
               ("control.tar.gz", tar_bytes(control)),
               ("data.tar.gz", tar_bytes(data))]
    with destination.open("wb") as archive:
        archive.write(b"!<arch>\n")
        for name, contents in members:
            header = (f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}"
                      f"{len(contents):<10}`\n").encode()
            assert len(header) == 60
            archive.write(header)
            archive.write(contents)
            if len(contents) % 2:
                archive.write(b"\n")


class Fixture:
    def __init__(self, directory, prefix=""):
        self.directory = Path(directory)
        self.root = self.directory / "installation"
        self.admin = self.directory / "database"
        self.root.mkdir()
        (self.admin / "info").mkdir(parents=True)
        (self.admin / "updates").mkdir()
        (self.admin / "status").write_bytes(b"")
        self.prefix = prefix
        self.source = prefix + "/etc/apt/sources.list.d/cydia.list"
        self.pin = prefix + "/etc/apt/preferences.d/cydia"
        self.key = prefix + "/etc/apt/trusted.gpg.d/legacy.gpg"
        self.paths = (self.source, self.pin, self.key)
        self.environment = dict(os.environ)
        # Explicit tools precede the ordinary system search path. No test
        # changes the host dpkg database or requires privilege escalation.
        tools = dict.fromkeys(str(Path(tool).parent) for tool in (DPKG, DIVERT, QUERY, CHOWN))
        self.environment["PATH"] = ":".join(tools) + os.pathsep + os.defpath
        self.environment["DPKG_ROOT"] = str(self.root)
        self.environment["DPKG_ADMINDIR"] = str(self.admin)
        self.environment.pop("CYDIA", None)
        self.environment.pop("APT_CONFIG", None)
        self.old = self.directory / "old.deb"
        self.new = self.directory / "new.deb"
        self.saved = {}

    def physical(self, path):
        return self.root / path.lstrip("/")

    def run(self, arguments, expected=0):
        result = subprocess.run(arguments, env=self.environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        if expected == 0:
            assert result.returncode == 0, result.stdout
        else:
            assert result.returncode != 0, result.stdout
        return result.stdout

    def dpkg(self, *arguments, expected=0):
        return self.run([DPKG, "--root=" + str(self.root),
                         "--admindir=" + str(self.admin), "--force-not-root", "--force-bad-path",
                         "--force-script-chrootless", *map(str, arguments)], expected)

    def diversion(self, *arguments, expected=0):
        return self.run([DIVERT, "--instdir", str(self.root), "--admindir", str(self.admin),
                         *arguments], expected).strip()

    def lifecycle(self, script, phase, expected=0):
        return self.run(["/bin/bash", str(ROOT / "Library/shared-config-lifecycle.sh"),
                         "--cydia-shared-config-lifecycle", script, phase], expected)

    def package(self, version, data=(), conffiles=(), postinst=None):
        control = (f"Package: cydia\nVersion: {version}\nArchitecture: all\n"
                   "Maintainer: Package Test <package@example.invalid>\n"
                   "Description: Shared configuration lifecycle fixture\n").encode()
        entries = [("control", control, 0o644)]
        if conffiles:
            entries.append(("conffiles", ("\n".join(conffiles) + "\n").encode(), 0o644))
        if version == "2":
            for name in ("preinst", "prerm", "postrm"):
                entries.append((name, LIBRARY + b"\n" + (ROOT / name).read_bytes(), 0o755))
            entries.append(("cydia-shared-config-lifecycle", LIBRARY, 0o755))
            native_bridge_fixture = (b"#!/bin/bash\n"
                                    b'exec /bin/bash "${0%/*}/cydia.cydia-shared-config-lifecycle" '
                                    b'--cydia-shared-config-lifecycle postinst "$@"\n')
            entries.append(("postinst", postinst or native_bridge_fixture, 0o755))
        destination = self.new if version == "2" else self.old
        write_deb(destination, entries, data)
        return destination

    def install_old(self, conffiles=False, symlink=False):
        data = [(path.lstrip("/"), b"old payload\n", 0o644) for path in self.paths]
        if symlink:
            data[0] = (self.source.lstrip("/"), ("../shared-source",), 0o777)
        self.package("1", data, (self.source,) if conffiles else ())
        self.dpkg("--install", self.old)
        if symlink:
            self.physical(self.prefix + "/etc/apt/shared-source").write_bytes(
                b"deb https://shared.example.invalid stable main\n")
        for path in self.paths:
            if self.physical(path).is_symlink():
                self.saved[path] = ("symlink", os.readlink(self.physical(path)))
            else:
                contents = ("administrator retained " + path + "\n").encode()
                self.physical(path).write_bytes(contents)
                self.saved[path] = ("file", contents)
        other = self.physical(self.prefix + "/etc/apt/sources.list.d/bootstrap.sources")
        other.write_bytes(b"Types: deb\nURIs: https://bootstrap.example.invalid\nSuites: stable\n")
        self.saved[self.prefix + "/etc/apt/sources.list.d/bootstrap.sources"] = ("file", other.read_bytes())

    def assert_preserved(self):
        for path, (kind, contents) in self.saved.items():
            physical = self.physical(path)
            if kind == "symlink":
                assert physical.is_symlink() and os.readlink(physical) == contents, path
            else:
                assert physical.is_file() and physical.read_bytes() == contents, path

    def records(self):
        return sorted((self.admin / "cydia-shared-config-handoff").glob("*.record"))

    def assert_clean(self):
        assert not self.records(), "handoff records remain"
        for path in self.paths:
            assert not self.diversion("--listpackage", path), path
            assert self.diversion("--truename", path) == path, path
        assert not list(self.root.rglob("*.distrib")), "unexpected payload backups"


def ordinary_upgrade(directory, prefix=""):
    fixture = Fixture(directory, prefix)
    fixture.install_old()
    fixture.package("2")
    fixture.dpkg("--unpack", fixture.new)
    fixture.assert_preserved()
    assert len(fixture.records()) == 3
    for path in fixture.paths:
        assert fixture.diversion("--listpackage", path) == "LOCAL"
    # Retry configure after an interrupted unpack, with no active-file gap.
    fixture.dpkg("--configure", "cydia")
    fixture.assert_preserved()
    fixture.assert_clean()
    fixture.dpkg("--remove", "cydia")
    fixture.assert_preserved()
    assert not (fixture.admin / "info/cydia.cydia-shared-config-lifecycle").exists()
    fixture.dpkg("--purge", "cydia")
    fixture.assert_preserved()
    fixture.assert_clean()


def conffile_upgrade(directory):
    fixture = Fixture(directory)
    fixture.install_old(conffiles=True)
    fixture.package("2")
    fixture.dpkg("--install", fixture.new)
    fixture.assert_preserved()
    fixture.assert_clean()
    fixture.dpkg("--remove", "cydia")
    fixture.dpkg("--purge", "cydia")
    fixture.assert_preserved()
    fixture.assert_clean()


def fresh_install(directory):
    fixture = Fixture(directory)
    fixture.package("2")
    fixture.dpkg("--install", fixture.new)
    for path in fixture.paths:
        assert not fixture.physical(path).exists()
    assert not (fixture.admin / "cydia-shared-config-handoff").exists()
    fixture.dpkg("--purge", "cydia")
    fixture.assert_clean()


def foreign_diversion(directory, prefix="", rename=False, symlink=False):
    fixture = Fixture(directory, prefix)
    fixture.install_old(symlink=symlink)
    destination = fixture.source + ".bootstrap-owned"
    original = fixture.saved[fixture.source]
    fixture.diversion("--package", "bootstrap-fixture", "--rename" if rename else "--no-rename", "--divert",
                      destination, "--add", fixture.source)
    if rename:
        fixture.saved[destination] = original
        fixture.physical(fixture.source).write_bytes(b"bootstrap active source\n")
        fixture.saved[fixture.source] = ("file", b"bootstrap active source\n")
    fixture.package("2")
    fixture.dpkg("--unpack", fixture.new)
    # The other frontend's active configuration never has a missing-file gap.
    assert fixture.physical(fixture.source).exists()
    fixture.dpkg("--configure", "cydia")
    fixture.assert_preserved()
    assert fixture.diversion("--listpackage", fixture.source) == "bootstrap-fixture"
    assert fixture.diversion("--truename", fixture.source) == destination
    assert not fixture.records()
    assert not list((fixture.admin / "cydia-shared-config-handoff").glob("*.payload"))
    fixture.dpkg("--remove", "cydia")
    fixture.dpkg("--purge", "cydia")
    fixture.assert_preserved()
    assert fixture.diversion("--listpackage", fixture.source) == "bootstrap-fixture"


def foreign_interrupted_restore(directory, collision=False):
    fixture = Fixture(directory)
    fixture.install_old()
    destination = fixture.key + ".bootstrap-owned"
    original = fixture.saved[fixture.key]
    fixture.diversion("--package", "bootstrap-fixture", "--rename", "--divert", destination, "--add", fixture.key)
    fixture.saved[destination] = original
    fixture.physical(fixture.key).write_bytes(b"bootstrap active key\n")
    fixture.saved[fixture.key] = ("file", b"bootstrap active key\n")
    fixture.lifecycle("preinst", "upgrade")
    fixture.physical(destination).unlink()
    if collision:
        fixture.physical(destination).write_bytes(b"newer administrator backing file\n")
    fixture.lifecycle("postrm", "abort-upgrade", expected=1 if collision else 0)
    assert fixture.physical(fixture.key).read_bytes() == b"bootstrap active key\n"
    assert fixture.diversion("--listpackage", fixture.key) == "bootstrap-fixture"
    if collision:
        assert fixture.physical(destination).read_bytes() == b"newer administrator backing file\n"
        assert fixture.records(), "conflict discarded the original private copy"
    else:
        fixture.assert_preserved()
        assert not fixture.records()


def foreign_conffile_refusal(directory):
    fixture = Fixture(directory)
    fixture.install_old(conffiles=True)
    destination = fixture.source + ".bootstrap-owned"
    fixture.diversion("--package", "bootstrap-fixture", "--no-rename", "--divert", destination, "--add", fixture.source)
    fixture.package("2")
    fixture.dpkg("--unpack", fixture.new, expected=1)
    fixture.assert_preserved()
    assert fixture.diversion("--truename", fixture.source) == destination
    assert not fixture.records()


def pending_record_retry(directory):
    fixture = Fixture(directory)
    fixture.install_old()
    fixture.lifecycle("preinst", "upgrade")
    fixture.assert_preserved()
    record = fixture.records()[0]
    fields = dict(line.split("=", 1) for line in record.read_text().splitlines())
    fixture.diversion("--local", "--no-rename", "--divert", fields["divert"],
                      "--remove", fields["path"])
    # An intent record persisted before dpkg-divert is safe to resume.
    fixture.lifecycle("preinst", "upgrade")
    assert fixture.diversion("--truename", fields["path"]) == fields["divert"]
    fixture.lifecycle("postrm", "abort-upgrade")
    fixture.assert_preserved()
    fixture.assert_clean()


def unexpected_payload(directory):
    fixture = Fixture(directory)
    fixture.install_old()
    fixture.lifecycle("preinst", "upgrade")
    record = fixture.records()[0]
    fields = dict(line.split("=", 1) for line in record.read_text().splitlines())
    foreign = fixture.physical(fields["divert"])
    foreign.write_bytes(b"unrecognized payload\n")
    fixture.lifecycle("postrm", "abort-upgrade", expected=1)
    assert record.exists() and foreign.read_bytes() == b"unrecognized payload\n"
    assert fixture.diversion("--truename", fields["path"]) == fields["divert"]
    fixture.assert_preserved()


def unsafe_journal(directory):
    fixture = Fixture(directory)
    fixture.install_old()
    journal = fixture.admin / "cydia-shared-config-handoff"
    journal.mkdir(mode=0o777)
    journal.chmod(0o777)
    fixture.lifecycle("preinst", "upgrade", expected=1)
    fixture.assert_preserved()
    for path in fixture.paths:
        assert not fixture.diversion("--listpackage", path)


def symlink_upgrade(directory):
    fixture = Fixture(directory)
    fixture.install_old(symlink=True)
    target = fixture.physical("/etc/apt/shared-source").read_bytes()
    fixture.package("2")
    fixture.dpkg("--install", fixture.new)
    fixture.assert_preserved()
    assert fixture.physical("/etc/apt/shared-source").read_bytes() == target
    fixture.dpkg("--purge", "cydia")
    fixture.assert_preserved()
    fixture.assert_clean()


def deleted_configuration(directory):
    fixture = Fixture(directory)
    fixture.install_old()
    fixture.physical(fixture.source).unlink()
    del fixture.saved[fixture.source]
    unowned = fixture.physical("/etc/apt/trusted.gpg.d/bootstrap.gpg")
    unowned.write_bytes(b"separately managed keyring\n")
    fixture.package("2")
    fixture.dpkg("--install", fixture.new)
    fixture.assert_preserved()
    assert not fixture.physical(fixture.source).exists()
    assert unowned.read_bytes() == b"separately managed keyring\n"
    fixture.assert_clean()


def unexpected_new_ownership(directory):
    fixture = Fixture(directory)
    fixture.install_old()
    fixture.package("2", [(fixture.source.lstrip("/"), b"unexpected new payload\n", 0o644)])
    fixture.dpkg("--unpack", fixture.new)
    fixture.assert_preserved()
    fixture.dpkg("--configure", "cydia", expected=1)
    fixture.assert_preserved()
    assert fixture.records(), "failed configuration lost its preservation journal"
    assert fixture.diversion("--listpackage", fixture.source) == "LOCAL"


def main():
    cases = [fresh_install, ordinary_upgrade, conffile_upgrade, foreign_diversion,
             pending_record_retry, unexpected_payload, unsafe_journal, symlink_upgrade,
             deleted_configuration, unexpected_new_ownership,
             lambda directory: ordinary_upgrade(directory, "/var/jb"),
             lambda directory: foreign_diversion(directory, rename=True),
             lambda directory: foreign_diversion(directory, "/var/jb", rename=True),
             lambda directory: foreign_diversion(directory, rename=True, symlink=True),
             foreign_interrupted_restore,
             lambda directory: foreign_interrupted_restore(directory, collision=True),
             foreign_conffile_refusal]
    for case in cases:
        with tempfile.TemporaryDirectory(prefix="cydia-lifecycle-") as directory:
            case(directory)
    print(f"[shared-config-lifecycle] PASS ({len(cases)} isolated dpkg fixtures)")


if __name__ == "__main__":
    main()
