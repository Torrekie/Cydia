#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 FIXTURE_OUTPUT_DIR" >&2
    exit 2
fi

output=$1
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P) || exit 2
case "$output" in
    /*) ;;
    *) output=$root/$output ;;
esac
repository=$output/repository
server=$root/scripts/serve-device-cancellation-fixture.py
archive=$repository/com.torrekie.cydia-ui-cancellation-fixture_1.0_iphoneos-arm64.deb
for path in "$server" "$repository/Packages" "$repository/Packages.gz" \
        "$repository/SHA256SUMS" "$archive"; do
    test -f "$path" || {
        echo "missing cancellation fixture artifact: $path" >&2
        exit 2
    }
done
for tool in curl python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required" >&2
        exit 2
    }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/cydia-cancellation-server.XXXXXX") || exit 2
pid=
cleanup() {
    if test -n "$pid" && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

PYTHONPYCACHEPREFIX=$work/pycache python3 -m py_compile "$server"
python3 "$server" --root "$repository" --bind 127.0.0.1 --port 0 \
    --bytes-per-second 32768 --chunk-bytes 4096 \
    --log "$work/transfers.jsonl" --ready "$work/ready.json" \
    >"$work/server.out" 2>"$work/server.err" &
pid=$!

attempt=0
while test ! -s "$work/ready.json"; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 100 || {
        echo "cancellation fixture server did not become ready" >&2
        exit 1
    }
    kill -0 "$pid" 2>/dev/null || {
        echo "cancellation fixture server exited before ready" >&2
        exit 1
    }
    sleep 0.05
done
port=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["port"])' \
    "$work/ready.json")
base=http://127.0.0.1:$port

curl -fsS "$base/Packages" -o "$work/Packages"
cmp -s "$work/Packages" "$repository/Packages"
curl --path-as-is -fsS "$base/./Packages.gz" -o "$work/Packages.gz"
cmp -s "$work/Packages.gz" "$repository/Packages.gz"
curl -fsS -H 'Range: bytes=1024-2047' "$base/$(basename "$archive")" \
    -o "$work/range.bin"
dd if="$archive" of="$work/expected-range.bin" bs=1 skip=1024 count=1024 \
    2>/dev/null
cmp -s "$work/range.bin" "$work/expected-range.bin"

set +e
curl -fsS --max-time 1 "$base/$(basename "$archive")" \
    -o "$work/partial.deb" 2>"$work/curl.err"
curl_status=$?
set -e
test "$curl_status" -eq 28 || {
    echo "throttled archive request did not time out as expected" >&2
    exit 1
}
partial_size=$(wc -c <"$work/partial.deb" | tr -d '[:space:]')
archive_size=$(wc -c <"$archive" | tr -d '[:space:]')
test "$partial_size" -gt 0
test "$partial_size" -lt "$archive_size"

python3 - "$work/transfers.jsonl" "$archive_size" <<'PY'
import json
import sys
import time

path, archive_size = sys.argv[1], int(sys.argv[2])
deadline = time.monotonic() + 3
while True:
    events = []
    try:
        with open(path, encoding="utf-8") as stream:
            events = [json.loads(line) for line in stream if line.strip()]
    except FileNotFoundError:
        pass
    partial = [event for event in events
               if event.get("archive") and event.get("disconnect") is True
               and not event.get("complete")
               and 0 < event.get("bytesSent", 0) < archive_size]
    if partial:
        break
    if time.monotonic() >= deadline:
        raise SystemExit("server did not record a partial archive transfer")
    time.sleep(0.05)
PY

if test -s "$work/server.err"; then
    echo "cancellation fixture server wrote to stderr:" >&2
    sed -n '1,120p' "$work/server.err" >&2
    exit 1
fi
printf '%s\n' '[ ok ] deterministic throttled cancellation fixture'
