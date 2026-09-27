#!/usr/bin/env python3
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

"""Serve the disposable cancellation fixture through a throttled flat repo."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


PACKAGE_PATTERN = re.compile(
    r"com\.torrekie\.cydia-ui-cancellation-fixture_1\.0_iphoneos-arm64\.deb"
)
METADATA_NAMES = frozenset({"Packages", "Packages.gz", "SHA256SUMS"})
RANGE_PATTERN = re.compile(r"bytes=(\d+)-(\d*)")


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], root: Path, log_path: Path,
                 bytes_per_second: int, chunk_bytes: int) -> None:
        super().__init__(address, FixtureHandler)
        self.root = root
        self.log_path = log_path
        self.bytes_per_second = bytes_per_second
        self.chunk_bytes = chunk_bytes
        self.log_lock = threading.Lock()

    def record(self, payload: dict[str, object]) -> None:
        payload = dict(payload)
        payload["timestamp"] = time.time()
        line = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        with self.log_lock:
            with self.log_path.open("a", encoding="utf-8") as stream:
                stream.write(line + "\n")


class FixtureHandler(BaseHTTPRequestHandler):
    server: FixtureServer
    protocol_version = "HTTP/1.1"
    server_version = "CydiaCancellationFixture/1"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _resolve(self) -> tuple[str, Path] | None:
        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            return None
        decoded_path = unquote(parsed.path)
        if not decoded_path.startswith("/"):
            return None
        raw_name = decoded_path[1:]
        name = raw_name[2:] if raw_name.startswith("./") else raw_name
        if "/" in name or name in {"", ".", ".."}:
            return None
        if name not in METADATA_NAMES and not PACKAGE_PATTERN.fullmatch(name):
            return None
        try:
            path = (self.server.root / name).resolve(strict=True)
        except FileNotFoundError:
            return None
        if not path.is_file() or path.parent != self.server.root:
            return None
        return name, path

    def _range(self, size: int) -> tuple[int, int, bool] | None:
        header = self.headers.get("Range")
        if header is None:
            return 0, size - 1, False
        match = RANGE_PATTERN.fullmatch(header.strip())
        if match is None:
            return None
        start = int(match.group(1))
        end = int(match.group(2)) if match.group(2) else size - 1
        if start >= size or end < start:
            return None
        return start, min(end, size - 1), True

    def _serve(self, include_body: bool) -> None:
        resolved = self._resolve()
        if resolved is None:
            self.send_error(404)
            return
        name, path = resolved
        size = path.stat().st_size
        requested = self._range(size)
        if requested is None:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start, end, partial = requested
        length = end - start + 1
        is_archive = PACKAGE_PATTERN.fullmatch(name) is not None

        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/vnd.debian.binary-package"
                         if is_archive else "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        self.close_connection = True

        event: dict[str, object] = {
            "event": "transfer",
            "method": self.command,
            "path": name,
            "rangeStart": start,
            "rangeEnd": end,
            "totalBytes": size,
            "requestedBytes": length,
            "bytesSent": 0,
            "complete": not include_body,
            "archive": is_archive,
        }
        if not include_body:
            self.server.record(event)
            return

        sent = 0
        started = time.monotonic()
        try:
            with path.open("rb") as stream:
                stream.seek(start)
                remaining = length
                while remaining:
                    chunk = stream.read(min(self.server.chunk_bytes, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent += len(chunk)
                    remaining -= len(chunk)
                    if is_archive and remaining:
                        target = started + sent / self.server.bytes_per_second
                        delay = target - time.monotonic()
                        if delay > 0:
                            time.sleep(delay)
            event["complete"] = sent == length
        except (BrokenPipeError, ConnectionResetError):
            event["complete"] = False
            event["disconnect"] = True
        finally:
            event["bytesSent"] = sent
            event["durationSeconds"] = round(time.monotonic() - started, 6)
            self.server.record(event)

    def do_GET(self) -> None:
        self._serve(True)

    def do_HEAD(self) -> None:
        self._serve(False)


def write_ready(path: Path, server: FixtureServer) -> None:
    payload = {
        "bind": server.server_address[0],
        "port": server.server_address[1],
        "pid": os.getpid(),
        "root": str(server.root),
        "bytesPerSecond": server.bytes_per_second,
        "chunkBytes": server.chunk_bytes,
    }
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n",
                         encoding="utf-8")
    os.replace(temporary, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--bytes-per-second", type=int, default=65536)
    parser.add_argument("--chunk-bytes", type=int, default=16384)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.root.resolve(strict=True)
    if not root.is_dir() or args.bytes_per_second <= 0 or args.chunk_bytes <= 0:
        raise SystemExit("invalid fixture server configuration")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.ready.parent.mkdir(parents=True, exist_ok=True)
    args.log.write_text("", encoding="utf-8")
    server = FixtureServer((args.bind, args.port), root, args.log,
                           args.bytes_per_second, args.chunk_bytes)
    write_ready(args.ready, server)

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
