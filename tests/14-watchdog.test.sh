#!/usr/bin/env bash
# tests/14-watchdog.test.sh — watchdog verdict + missed-run + metric export
# (exit-1-only paging, exit-2/3 note series, MEM-GATE expiry boundaries).
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"; W="$H/bin/watchdog.sh"
TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT
R="$TMPROOT/runs"; M="$TMPROOT/textfile"; mkdir -p "$R" "$M"
mk() { local d="$R/$1"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/results.jsonl"; }
L1_TOL='{"check":"L1","exit":1,"evidence":"new_errors=1 sample=2026-10-08 [ERR] sofia_presence.c:555 Cannot find profile qbx.qubickle.com|","ts":"x"}'
# fire 03:00 UTC; now = 2026-10-09 04:00 UTC (past fire+grace), run fresh today
NOW=$(date -u -d "2026-10-09 04:00 UTC" +%s)
# 1) green run -> 0
mk "20261009T030129Z-1" '{"check":"H1","exit":0,"evidence":"ok","ts":"x"}'
"$W" --runs-dir "$R" --textfile-dir "$M" --now "$NOW" >/dev/null || { echo "green rc!=0"; exit 1; }
grep -q 'qbx_harness_untolerated_red_count 0' "$M/qbx-harness.prom" || { echo "green metric"; exit 1; }
# 2) tolerated L1 only -> 0, counted not paged
mk "20261009T031500Z-2" "$L1_TOL"
"$W" --runs-dir "$R" --textfile-dir "$M" --now "$NOW" >/dev/null || { echo "tolerated rc!=0"; exit 1; }
grep -q 'qbx_harness_tolerated_red_count 1' "$M/qbx-harness.prom" || { echo "tol count"; exit 1; }
grep -q 'qbx_harness_check_exit{' "$M/qbx-harness.prom" && { echo "tolerated exported as page"; exit 1; }
# 3) untolerated red -> 1 naming the check
mk "20261009T033000Z-3" "$(printf '{"check":"ZZRED","exit":1,"evidence":"forced red proof","ts":"x"}\n%s' "$L1_TOL")"
out=$("$W" --runs-dir "$R" --textfile-dir "$M" --now "$NOW" 2>&1); rc=$?
[ "$rc" -eq 1 ] || { echo "red rc=$rc want 1"; exit 1; }
echo "$out" | grep -q 'ZZRED=1' || { echo "check name missing: $out"; exit 1; }
grep -q 'qbx_harness_check_exit{check="ZZRED"' "$M/qbx-harness.prom" || { echo "red metric"; exit 1; }
# 4) missed run: only yesterday's artifact, now past today fire+grace -> 1
rm -rf "$R"; mkdir -p "$R"
mk "20261008T030011Z-9" '{"check":"H1","exit":0,"evidence":"ok","ts":"x"}'
out=$("$W" --runs-dir "$R" --no-metrics --now "$NOW" 2>&1); rc=$?
[ "$rc" -eq 1 ] || { echo "missed rc=$rc want 1"; exit 1; }
echo "$out" | grep -q 'missed-run' || { echo "missed not named: $out"; exit 1; }
# 5) inside grace (now 03:10, grace 30) with stale artifact -> 0, no false page
NOW2=$(date -u -d "2026-10-09 03:10 UTC" +%s)
"$W" --runs-dir "$R" --no-metrics --now "$NOW2" >/dev/null || { echo "grace rc!=0"; exit 1; }
# 6) MEM-GATE exit 1 during quota freeze -> 0 (ID-tolerated, expires 2026-11-01)
rm -rf "$R"; mkdir -p "$R"
mk "20261009T032000Z-4" '{"check":"MEM-GATE","exit":1,"evidence":"probes: port5060_hits=0 agent=qbx-harness","ts":"x"}'
"$W" --runs-dir "$R" --no-metrics --now "$NOW" >/dev/null || { echo "memgate rc!=0"; exit 1; }
# 7) exit 2 untolerated -> 0 (recorded in non-paging note series, never pages)
rm -rf "$R"; mkdir -p "$R"
mk "20261009T032500Z-5" '{"check":"E1","exit":2,"evidence":"no gateways listed","ts":"x"}'
out=$("$W" --runs-dir "$R" --textfile-dir "$M" --now "$NOW" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "exit2 rc=$rc want 0"; exit 1; }
grep -q 'qbx_harness_check_note{check="E1"' "$M/qbx-harness.prom" || { echo "note metric missing"; exit 1; }
grep -q 'qbx_harness_check_exit{' "$M/qbx-harness.prom" && { echo "exit2 leaked to paging series"; exit 1; }
# 8) MEM-GATE expiry boundary: pre-expiry tolerated, post-expiry pages
rm -rf "$R"; mkdir -p "$R"
mk "20261028T030100Z-6" '{"check":"MEM-GATE","exit":1,"evidence":"gate down","ts":"x"}'
NOWOCT=$(date -u -d "2026-10-28 04:00 UTC" +%s)
out=$("$W" --runs-dir "$R" --no-metrics --now "$NOWOCT" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "pre-expiry rc=$rc want 0"; exit 1; }
echo "$out" | grep -q 'WARNING.*expires' || { echo "7d warning missing: $out"; exit 1; }
rm -rf "$R"; mkdir -p "$R"
mk "20261102T030100Z-7" '{"check":"MEM-GATE","exit":1,"evidence":"gate down","ts":"x"}'
NOWNOV=$(date -u -d "2026-11-02 04:00 UTC" +%s)
out=$("$W" --runs-dir "$R" --no-metrics --now "$NOWNOV" 2>&1); rc=$?
[ "$rc" -eq 1 ] || { echo "post-expiry rc=$rc want 1"; exit 1; }
echo "$out" | grep -q 'MEM-GATE=1' || { echo "lapsed memgate not named: $out"; exit 1; }
# 9) bad usage -> 64 (loop CLI convention), never 2
"$W" --bogus >/dev/null 2>&1; [ "$?" -eq 64 ] || { echo "usage rc"; exit 1; }
echo "watchdog contract ok"
