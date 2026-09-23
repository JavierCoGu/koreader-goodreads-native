#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$project_root/goodreads.koplugin/bin/sync-progress"
test_root="$(mktemp -d /tmp/goodreads-progress-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

state="$test_root/state"
result="$test_root/result.log"
lipc="$test_root/lipc-hash-prop"
payloads="$test_root/payloads"
asin=B002GYI9C4

# Fake Kindle LIPC tool: records each request payload and echoes it back as a
# hash with the handler's result, like com.lab126.readnow / kppGoodReads.
cat >"$lipc" <<'EOF'
#!/bin/sh
[ "$1" = com.lab126.readnow ] && [ "$2" = kppGoodReads ] || exit 9
read -r payload
printf '%s\n' "$payload" >>"$FAKE_LIPC_PAYLOADS"
[ "${FAKE_LIPC_MODE:-}" = hang ] && sleep 10
asin="$(printf '%s' "$payload" | sed -n 's/.*asin = "\([^"]*\)".*/\1/p')"
progress="$(printf '%s' "$payload" | sed -n 's/.*progress = "\([^"]*\)".*/\1/p')"
printf 'Hash Index: 0\n\tkppMycdActivityName = "PostReview"\n'
printf '\tasin = "%s"\n\tprogress = "%s"\n' "$asin" "$progress"
printf '\tresult = "%s"\n' "${FAKE_LIPC_RESULT:-true}"
EOF
chmod 0755 "$lipc"

run_helper() {
    set +e
    GOODREADS_PLUGIN_DIR="$test_root/plugin" \
        GOODREADS_PROGRESS_STATE_DIR="$state" \
        GOODREADS_PROGRESS_RESULT_FILE="$result" \
        GOODREADS_PROGRESS_LOCK_DIR="$test_root/lock" \
        GOODREADS_JAVA_BIN="$java_bin" GOODREADS_CVM_BIN="$cvm_bin" \
        GOODREADS_LIPC_HASH_TOOL="$lipc_tool" \
        GOODREADS_PROGRESS_LIPC_TIMEOUT="${lipc_timeout:-30}" \
        FAKE_LIPC_PAYLOADS="$payloads" \
        FAKE_LIPC_RESULT="${lipc_result:-true}" \
        FAKE_LIPC_MODE="${lipc_mode:-}" \
        sh "$helper" "$@"
    status=$?
    set -e
}

payload_count() {
    if [ -f "$payloads" ]; then
        wc -l <"$payloads" | tr -d ' '
    else
        printf '0'
    fi
}

java_bin=/nonexistent/java
cvm_bin=/bin/sh
lipc_tool="$lipc"

# Argument validation still runs before any runtime decision. Notes that could
# break out of the LIPC hash literal are rejected outright.
run_helper not-an-asin 42 Reading
[ "$status" -eq 2 ]
run_helper "$asin" 42 'Reading "quoted"'
[ "$status" -eq 2 ]
run_helper "$asin" 42 'Reading; reboot'
[ "$status" -eq 2 ]
[ ! -e "$result" ]
[ "$(payload_count)" -eq 0 ]

# cvm-only firmware (5.18.2): Goodreads rejects an empty or blank note with
# HTTP 400, so the helper refuses before contacting the service.
run_helper "$asin" 42
[ "$status" -eq 3 ]
grep -Fqx 'failed_stage=note_required' "$result"
grep -Fqx 'transport=lipc' "$result"
run_helper "$asin" 42 '   '
[ "$status" -eq 3 ]
grep -Fqx 'failed_stage=note_required' "$result"
[ "$(payload_count)" -eq 0 ]

# A missing LIPC tool fails immediately with its own stage.
lipc_tool=/nonexistent/lipc-hash-prop
run_helper "$asin" 42 Reading
[ "$status" -eq 3 ]
grep -Fqx 'failed_stage=lipc_unavailable' "$result"
lipc_tool="$lipc"

# Accepted request: exact payload, confirmed readback, persisted percent.
run_helper "$asin" 42 Reading
[ "$status" -eq 0 ]
[ "$(payload_count)" -eq 1 ]
grep -Fqx "{kppMycdActivityName = \"PostReview\", asin = \"$asin\", progress = \"42\", note = \"Reading\"}" \
    "$payloads"
grep -Eqx 'started_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' "$result"
grep -Fqx "asin=$asin" "$result"
grep -Fqx 'percent=42' "$result"
grep -Fqx 'transport=lipc' "$result"
grep -Fqx 'http_status=202' "$result"
grep -Fqx 'success=true' "$result"
[ "$(sed -n '1p' "$state/$asin")" = 42 ]
[ ! -e "$test_root/lock" ]
if find /tmp -maxdepth 1 -name 'goodreads-progress-native.*' -newer "$lipc" \
    -print -quit 2>/dev/null | grep -q .; then
    printf 'error: native output was left behind\n' >&2
    exit 1
fi

# An already accepted percentage is not sent again.
run_helper "$asin" 42 Reading
[ "$status" -eq 0 ]
[ "$(payload_count)" -eq 1 ]

# Native rejection (result="false", e.g. HTTP 400) fails and keeps the state.
lipc_result=false
run_helper "$asin" 43 Reading
[ "$status" -eq 7 ]
grep -Fqx 'percent=43' "$result"
grep -Fqx 'success=false' "$result"
grep -Fqx 'failed_stage=send_request' "$result"
[ "$(sed -n '1p' "$state/$asin")" = 42 ]
lipc_result=true

# A stalled native service is bounded by the watchdog.
lipc_mode=hang
lipc_timeout=1
started="$(date +%s)"
run_helper "$asin" 44 Reading
finished="$(date +%s)"
[ "$status" -eq 7 ]
[ $((finished - started)) -le 6 ]
grep -Fqx 'failed_stage=send_request' "$result"
[ "$(sed -n '1p' "$state/$asin")" = 42 ]
lipc_mode=
lipc_timeout=30

# Neither runtime present: no transport is known to work, fail fast.
cvm_bin=/nonexistent/cvm
before="$(payload_count)"
run_helper "$asin" 45 Reading
[ "$status" -eq 3 ]
grep -Fqx 'percent=45' "$result"
grep -Fqx 'failed_stage=runtime_missing' "$result"
[ "$(payload_count)" -eq "$before" ]

# Java 21 keeps the attach transport and never calls the LIPC service. Here
# the fixture plugin has no agent JAR, so the helper stops at that check.
rm -f "$result"
java_bin=/bin/sh
run_helper "$asin" 46 Reading
[ "$status" -eq 3 ]
[ ! -e "$result" ]
[ "$(payload_count)" -eq "$before" ]

printf '%s\n' 'Progress transport tests passed.'
