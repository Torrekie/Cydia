#!/bin/sh
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
    echo "usage: $0 journal.jsonl run-id runtime-version operation effect-kind cancelled\|effect\|authority-rejected\|presentation-rejected [expected-process-id]" >&2
    exit 2
fi
journal=$1
expected_pid=${7-}
[ -f "$journal" ] && [ ! -L "$journal" ] || exit 1
[ "$(wc -c < "$journal")" -le 262144 ] || exit 1
# The last durable record must end in a newline, not a partial JSON write.
[ "$(tail -c 1 "$journal" | od -An -tu1 | tr -d ' ')" = 10 ] || exit 1
if [ -n "$expected_pid" ]; then
    case "$expected_pid" in *[!0-9]*|'0') echo "invalid expected process id" >&2; exit 2;; esac
fi
jq -e -s --arg run "$2" --arg version "$3" --arg operation "$4" \
    --arg kind "$5" --arg outcome "$6" --arg expectedPid "$expected_pid" '
    def require($condition; $message):
        if $condition then . else error($message) end;
    def count($event): [.[] | select(.event == $event)] | length;
    . as $rows |
    require(length >= 4 and length <= 512; "invalid row count") |
    require([.[].sequence] == [range(0; length)]; "non-contiguous sequence") |
    require(.[0].schema == 1 and .[0].event == "journal_opened" and
        .[0].runID == $run and .[0].runtimeVersion == $version and
        .[0].processID > 0 and (.[0].processInstance | type == "string") and
        .[0].callerContext == "trusted_native_provider" and
        .[0].sourceAttestation == "runtime-version-requires-external-binary-provenance" and
        .[0].persistence == "unverified" and .[0].installedAcceptance == "not_claimed";
        "journal identity or evidence boundary mismatch") |
    require(($expectedPid == "") or (.[0].processID == ($expectedPid | tonumber));
        "journal process identity mismatch") |
    require(count("request_created") == 1; "single-case verifier requires exactly one request") |
    .[1] as $request |
    require($request.event == "request_created" and $request.operation == $operation and
        $request.effectKind == $kind and
        ([$request.requestID, $request.sessionID, $request.targetID, $request.presenterID] |
            all(type == "string" and length > 0)); "request identity mismatch") |
    require(all(.[1:][]; .requestID == $request.requestID); "cross-request contamination") |
    require(all(.[]; [.event] - ["journal_opened", "request_created", "presentation_requested",
        "presented", "presentation_rejected", "confirm_callback", "cancel_callback",
        "duplicate_callback_suppressed", "execution_entered", "effect_returned",
        "authority_rejected", "cancelled", "request_finished"] == []);
        "incomplete, wrong-thread, or unknown event") |
    require(count("request_finished") == 1; "missing or repeated terminal record") |
    (if $outcome == "effect" then
        ["presentation_requested", "presented", "confirm_callback", "execution_entered", "effect_returned", "request_finished"]
     elif $outcome == "cancelled" then
        ["presentation_requested", "presented", "cancel_callback", "cancelled", "request_finished"]
     elif $outcome == "authority-rejected" then
        ["presentation_requested", "presented", "confirm_callback", "execution_entered", "authority_rejected", "request_finished"]
     elif $outcome == "presentation-rejected" then
        ["presentation_rejected", "request_finished"]
     else error("unknown expected outcome") end) as $expected |
    # Any replay must be observed as one callback followed by its suppression.
    ([.[2:][] | .event]) as $events |
    require($events[0:($expected | length)] == $expected; "unexpected execution order or outcome") |
    ($events[($expected | length):]) as $replays |
    require(($replays | length) % 2 == 0 and
        all(range(0; ($replays | length); 2);
            ($replays[.] == "confirm_callback" or $replays[.] == "cancel_callback") and
            $replays[. + 1] == "duplicate_callback_suppressed"); "unsuppressed or malformed replay") |
    {runID: $run, runtimeVersion: $version, processID: .[0].processID,
     requestID: $request.requestID, operation: $operation, effectKind: $kind,
     observedOutcome: $outcome, effectReturns: count("effect_returned"),
     duplicateCallbacksSuppressed: count("duplicate_callback_suppressed"),
     persistence: "requires-independent-poststate", installedIdentity: "requires-external-provenance",
     acceptance: "single-provider-callback-only-not-P1-P2.1-P3"}
' "$journal"
