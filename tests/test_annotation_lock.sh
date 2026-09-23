#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/goodreads-lock-test.XXXXXX)"
payload="/tmp/goodreads-annotations-$$.properties"
request_result="/tmp/goodreads-annotation-result-$$.log"
trap 'rm -rf "$test_root"; rm -f "$payload" "$request_result"' EXIT HUP INT TERM

plugin_dir="$test_root/plugin"
state_dir="$test_root/state"
receipt_dir="$test_root/receipts"
lock_dir="$test_root/held.lock"
published_result="$test_root/published-result.log"
helper="$test_root/sync-annotations"
fake_java="$test_root/java"
mkdir -p "$plugin_dir/bin/classes" "$receipt_dir" "$lock_dir"
: >"$plugin_dir/bin/goodreads-annotation-agent-v31.jar"
: >"$plugin_dir/bin/classes/AttachLauncher.class"
printf '%s\n' '#!/bin/sh' >"$fake_java"
chmod 0755 "$fake_java"

# The helper sources its runtime check from its own directory.
cp "$project_root/goodreads.koplugin/bin/goodreads-java-runtime" "$test_root/"
export GOODREADS_JAVA_BIN="$fake_java"
sed \
    -e "s|^PLUGIN_DIR=.*|PLUGIN_DIR=\"$plugin_dir\"|" \
    -e "s|^STATE_DIR=.*|STATE_DIR=\"$state_dir\"|" \
    -e "s|^RECEIPT_DIR=.*|RECEIPT_DIR=\"$receipt_dir\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$lock_dir\"|" \
    -e "s|^PUBLISHED_RESULT=.*|PUBLISHED_RESULT=\"$published_result\"|" \
    "$project_root/goodreads.koplugin/bin/sync-annotations" >"$helper"
chmod 0755 "$helper"

cat >"$payload" <<EOF
version=1
asin=B012345678
request_id=$$
outbox_sequence=legacy
outbox_checksum=legacy
retry_count=0
trigger=reader_ready
desired_count=0
previous_count=0
EOF

started_at="$(date +%s)"
if "$helper" "$payload"; then
    printf 'error: lock contention was reported as success\n' >&2
    exit 1
else
    status=$?
fi
elapsed="$(( $(date +%s) - started_at ))"
[ "$status" -eq 75 ]
[ "$elapsed" -lt 5 ]
grep -Fqx "request_id=$$" "$published_result"
grep -Fqx 'failed_stage=lock_busy' "$published_result"
grep -Fqx 'success=false' "$published_result"
grep -Fqx 'outbox_acknowledged=false' "$published_result"
grep -Fqx 'state=failed' "$receipt_dir/B012345678"
grep -Fqx 'retry_reason=lock_busy' "$receipt_dir/B012345678"
grep -Fqx 'native_range_count=unavailable' "$receipt_dir/B012345678"

# cvm-only firmware cannot attach the agent. The helper must publish a
# retryable runtime failure at once instead of leaving a 120-second poll.
cat >"$payload" <<EOF
version=1
asin=B012345678
request_id=$$
outbox_sequence=legacy
outbox_checksum=legacy
retry_count=0
trigger=reader_ready
desired_count=0
previous_count=0
EOF
rm -f "$published_result"
started_at="$(date +%s)"
if GOODREADS_JAVA_BIN=/nonexistent/java GOODREADS_CVM_BIN="$fake_java" \
    "$helper" "$payload"; then
    printf 'error: cvm-only runtime was reported as success\n' >&2
    exit 1
else
    status=$?
fi
elapsed="$(( $(date +%s) - started_at ))"
[ "$status" -eq 3 ]
[ "$elapsed" -lt 5 ]
grep -Fqx "request_id=$$" "$published_result"
grep -Fqx 'failed_stage=runtime_unsupported' "$published_result"
grep -Fqx 'success=false' "$published_result"
grep -Fqx 'outbox_acknowledged=false' "$published_result"
grep -Fqx 'state=failed' "$receipt_dir/B012345678"
grep -Fqx 'retry_reason=runtime_unsupported' "$receipt_dir/B012345678"
[ ! -e "$payload" ]

printf 'Annotation lock-contention test passed.\n'
