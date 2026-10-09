#!/usr/bin/env bash
# tests/15-relocation.test.sh — Task 4 portability: tree copied to /tmp runs the
# contract suite with identical verdict semantics (per-check exit codes;
# evidence paths may differ — logs explicitly NOT byte-identical).
# Procedure: full `bin/loop --no-memory` sweep in-place vs in the /tmp copy
# (scratch --runs-dir both, so real runs/ artifacts are untouched), then
# `bin/report` in the copy, then hermetic contract tests (00/04/13) in the
# copy. Live-SIP checks run in both sweeps exactly as the contract suite does
# (no NEW live traffic classes). Guard HARNESS_RELOC_DEPTH blocks recursion
# if a relocated suite ever re-enters this test.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
[ -n "${HARNESS_RELOC_DEPTH:-}" ] && { echo "skip: already inside a relocated run"; exit 0; }
T=$(mktemp -d); DEST="/tmp/qbx-harness-reloc-$$"
trap 'rm -rf "$T" "$DEST"' EXIT
mkdir -p "$T"
cp -a "$H/." "$DEST/" || { echo "copy tree failed"; exit 1; }
rm -rf "$DEST/runs"; mkdir -p "$DEST/runs"
[ -x "$DEST/bin/loop" ] || { echo "relocated loop missing"; exit 1; }

sweep() { # $1=HARNESS_ROOT $2=out-prefix -> prints run dir; rc = loop rc
  local root="$1" pfx="$2" rc=0
  HARNESS_ROOT="$root" bash "$root/bin/loop" --no-memory \
    --runs-dir "$T/$pfx-runs" >"$T/$pfx.log" 2>&1 || rc=$?
  local rd; rd=$(ls -d "$T/$pfx-runs"/*/ 2>/dev/null | head -1)
  [ -n "$rd" ] || { echo "$pfx: no run dir produced"; return 1; }
  echo "$rd"; return "$rc"
}

in_rd=$(sweep "$H" in); in_rc=$?
cp_rd=$(sweep "$DEST" cp); cp_rc=$?
[ -n "${in_rd:-}" ] && [ -n "${cp_rd:-}" ] || exit 1
[ "$in_rc" -eq "$cp_rc" ] || { echo "loop rc differs: in-place=$in_rc copy=$cp_rc"; exit 1; }
exits() { jq -r '[.check, (.exit|tostring)] | join("=")' "$1/results.jsonl" 2>/dev/null | sort; }
in_ex=$(exits "$in_rd"); cp_ex=$(exits "$cp_rd")
[ -n "$in_ex" ] || { echo "in-place sweep produced no verdicts"; exit 1; }
[ "$in_ex" = "$cp_ex" ] || {
  echo "per-check exits differ:"; diff <(printf '%s\n' "$in_ex") <(printf '%s\n' "$cp_ex") || true
  exit 1; }
n=$(printf '%s\n' "$in_ex" | wc -l)
echo "relocation: loop rc=$in_rc both trees, $n per-check exits identical"

HARNESS_ROOT="$DEST" bash "$DEST/bin/report" "$cp_rd" >/dev/null 2>&1 \
  || { echo "relocated report failed"; exit 1; }
[ -s "$cp_rd/report.md" ] || { echo "relocated report.md empty"; exit 1; }
echo "relocation: report ok in copy"

for t in 00-runner.test.sh 04-common.test.sh 09-loop.test.sh 13-flake-retry.test.sh; do
  HARNESS_ROOT="$DEST" bash "$DEST/tests/$t" >"$T/reloc-$t.log" 2>&1 \
    || { echo "relocated $t FAILED:"; tail -5 "$T/reloc-$t.log"; exit 1; }
  echo "relocation: $t ok in copy"
done
echo ok
