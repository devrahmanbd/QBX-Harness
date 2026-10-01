#!/usr/bin/env bash
set -uo pipefail
dir="${1:-}"; [ "${1:-}" = "--dir" ] && dir="$2"
[ -z "$dir" ] && dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir" || exit 2
fails=0; n=0
for t in *.test.sh; do
  n=$((n+1))
  if out=$(bash "$t" 2>&1); then echo "ok   $t"
  else echo "FAIL $t"; printf '%s\n' "$out" | sed 's/^/     /'; fails=$((fails+1)); fi
done
echo "tests: $n, failed: $fails"
[ "$fails" -eq 0 ]
