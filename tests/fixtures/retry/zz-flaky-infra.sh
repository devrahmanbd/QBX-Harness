#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
c="$FLAKE_STATE/zz-flaky-infra.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
if [ "$n" -le 1 ]; then emit ZZFLK 3 "timeout simulated: uuid-poll no channel (attempt $n)"; else emit ZZFLK 0 "recovered on attempt $n"; fi
