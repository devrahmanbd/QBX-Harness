#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
c="$FLAKE_STATE/zz-hard-infra.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
emit ZZHRD 3 "stale sibling channels before run: total=2 (attempt $n)"
