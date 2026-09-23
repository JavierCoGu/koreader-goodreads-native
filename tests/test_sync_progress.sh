#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$project_root/goodreads.koplugin/bin/sync-progress"
test_root="$(mktemp -d /tmp/goodreads-progress-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

state="$test_root/state"
result="$test_root/result.log"
asin=B002GYI9C4

run_helper() {
    set +e
    GOODREADS_PLUGIN_DIR="$test_root/plugin" \
        GOODREADS_PROGRESS_STATE_DIR="$state" \
        GOODREADS_PROGRESS_RESULT_FILE="$result" \
        GOODREADS_JAVA_BIN="$java_bin" GOODREADS_CVM_BIN="$cvm_bin" \
        sh "$helper" "$@"
    status=$?
    set -e
}

# Argument validation still runs before any runtime decision.
java_bin=/nonexistent/java
cvm_bin=/bin/sh
run_helper not-an-asin 42
[ "$status" -eq 2 ]
[ ! -e "$result" ]

# cvm-only firmware (5.18.2) fails immediately with a definite result instead
# of leaving KOReader to poll for 30 seconds.
started="$(date +%s)"
run_helper "$asin" 42
finished="$(date +%s)"
[ "$status" -eq 3 ]
[ $((finished - started)) -le 2 ]
grep -Eqx 'started_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' "$result"
grep -Fqx "asin=$asin" "$result"
grep -Fqx 'percent=42' "$result"
grep -Fqx 'success=false' "$result"
grep -Fqx 'failed_stage=runtime_unsupported' "$result"
[ "$(wc -l <"$result" | tr -d ' ')" -eq 5 ]
[ ! -e "$state/$asin" ]
if find "$test_root" -name 'result.log.*' -print -quit | grep -q .; then
    printf 'error: temporary result file was left behind\n' >&2
    exit 1
fi

# Neither runtime present is reported separately.
cvm_bin=/nonexistent/cvm
run_helper "$asin" 43
[ "$status" -eq 3 ]
grep -Fqx 'percent=43' "$result"
grep -Fqx 'failed_stage=runtime_missing' "$result"
[ ! -e "$state/$asin" ]

# A usable runtime must not publish the unsupported result. Here the fixture
# plugin has no agent JAR, so the helper stops at its installation check.
rm -f "$result"
java_bin=/bin/sh
run_helper "$asin" 44
[ "$status" -eq 3 ]
[ ! -e "$result" ]

printf '%s\n' 'Progress runtime fail-fast tests passed.'
