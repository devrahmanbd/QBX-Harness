# tests/09-loop.test.sh
#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
L="$H/bin/loop"; R="$H/bin/report"
mkdir -p "$H/tests/fixtures/loop"
gen() { printf '#!/usr/bin/env bash\nHARNESS_ROOT="${HARNESS_ROOT:-%s}"; . "$HARNESS_ROOT/lib/common.sh"\n%s\n' "$H" "$2" > "$1"; chmod +x "$1"; }
F="$H/tests/fixtures/loop"
gen "$F/zz-pass-a.sh" 'emit ZZPASS 0 "stub a evidence"'
gen "$F/zz-pass-b.sh" 'emit ZZPASS 0 "stub b evidence"'
gen "$F/zz-open-1.sh" 'emit ZZOPEN 1 "open finding 1"'
gen "$F/zz-open-2.sh" 'emit ZZOPEN 1 "open finding 2"'
gen "$F/zz-open-3.sh" 'emit ZZOPEN 1 "open finding 3"'
gen "$F/zz-open-4.sh" 'emit ZZOPEN 1 "open finding 4"'
gen "$F/zz-blocked.sh" 'emit ZZBLK 2 "external blocker"'
gen "$F/zz-error.sh" 'emit ZZERR 3 "error"'
gen "$F/zz-exit130.sh" 'echo "{\"check\":\"ZZ130\",\"exit\":130,\"evidence\":\"killed\",\"ts\":\"x\"}"; exit 130'
gen "$F/zz-leaky.sh" 'echo "{\"check\":\"ZZLEAK\",\"exit\":1,\"evidence\":\"pw=FREESWITCH_ESL_PASSWORD=hunter2\",\"ts\":\"x\"}"; exit 1'
gen "$F/zz-slow.sh" 'sleep 30'

# every mktemp -d in this test hangs off TMPROOT and is removed on EXIT (success or failure)
TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT

run_loop() {  # run_loop <fixture-list-csv> [extra loop args...]
  local list="$1"; shift
  local tdir; tdir=$(mktemp -d "$TMPROOT/XXXXXX")
  printf '%s\n' ${list//,/ } > "$tdir/catalog"   # unquoted: one id per line
  local lrc
  RUNS="$tdir/runs" "$L" --runs-dir "$tdir/runs" --checks-dir "$F" \
    --catalog "$tdir/catalog" --no-memory "$@" >"$tdir/loop.out" 2>&1; lrc=$?
  echo "$tdir"
  return "$lrc"
}
# 1) all-pass: 2 lines, exit 0, report rows == lines
d=$(run_loop "zz-pass-a,zz-pass-b"); rc=$?
[ "$rc" -eq 0 ] || { echo "all-pass loop rc=$rc"; exit 1; }
n=$(wc -l < "$d"/runs/*/results.jsonl); [ "$n" -eq 2 ] || { echo "want 2 jsonl lines, got $n"; exit 1; }
rows=$(grep -c '^| ' "$d"/runs/*/report.md); [ "$((rows-1))" -eq "$n" ] || { echo "report table rows $((rows-1)) != jsonl lines $n"; exit 1; }
# 2) breaker: error stub repeated -> stops after exactly 3 executions, rc=1, breaker flag
d=$(run_loop "zz-error,zz-error,zz-error,zz-error"); rc=$?
[ "$rc" -eq 1 ] || { echo "breaker loop rc=$rc want 1"; exit 1; }
n=$(wc -l < "$d"/runs/*/results.jsonl); [ "$n" -eq 3 ] || { echo "breaker should stop at 3, got $n"; exit 1; }
grep -q 'breaker' "$d"/runs/*/report.md || { echo "report lacks breaker note"; exit 1; }
grep -q '^| ZZERR | 3 | error |' "$d"/runs/*/report.md || { echo "error class word missing"; exit 1; }
# 3) open findings never trip: 4 exit-1 stubs all execute, rc=0
d=$(run_loop "zz-open-1,zz-open-2,zz-open-3,zz-open-4"); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$d"/runs/*/results.jsonl)" -eq 4 ] \
  || { echo "open-finding run should complete"; exit 1; }
grep -q '^| ZZOPEN | 1 | open-finding |' "$d"/runs/*/report.md || { echo "open-finding class word missing"; exit 1; }
# 4) blocked completes with class blocked
d=$(run_loop "zz-blocked,zz-pass-a"); rc=$?
[ "$rc" -eq 0 ] && grep -q 'blocked' "$d"/runs/*/report.md || { echo "blocked class missing"; exit 1; }
grep -q '^| ZZBLK | 2 | blocked |' "$d"/runs/*/report.md || { echo "blocked class word missing"; exit 1; }
# 5) exit 130 normalized to 3 with normalized_from
d=$(run_loop "zz-exit130,zz-pass-a,zz-pass-a,zz-pass-a"); rc=$?
grep -q 'normalized_from=130' "$d"/runs/*/results.jsonl || { echo "exit130 not normalized"; exit 1; }
grep -q '"exit":3' "$d"/runs/*/results.jsonl || { echo "normalized exit not 3 in artifact"; exit 1; }
# 6) redaction: planted secret absent, marker present
d=$(run_loop "zz-leaky,zz-pass-a")
grep -q 'hunter2' "$d"/runs/*/results.jsonl "$d"/runs/*/report.md 2>/dev/null && { echo "secret leaked"; exit 1; }
grep -q '<redacted>' "$d"/runs/*/results.jsonl || { echo "redaction marker missing"; exit 1; }
# validity pin: redaction must never destroy the jsonl record structure
while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null || { echo "redaction broke the jsonl record: $l"; exit 1; }; done < "$d"/runs/*/results.jsonl
# 7) memory-degraded: memory ops ON but mem0 unreachable -> flag set, checks still run
tdir=$(mktemp -d "$TMPROOT/XXXXXX"); printf 'zz-pass-a\nzz-pass-b\n' > "$tdir/catalog"
MEM0_BASE=http://127.0.0.1:1 "$L" --runs-dir "$tdir/runs" --checks-dir "$F" \
  --catalog "$tdir/catalog" --skip-gate >"$tdir/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$tdir"/runs/*/results.jsonl)" -eq 2 ] \
  && grep -q 'memory_degraded=1' "$tdir"/runs/*/report.md \
  || { echo "memory_degraded flag missing (rc=$rc)"; exit 1; }
# 8) SIGINT abort: partial results, rc=130, aborted flag
tdir=$(mktemp -d "$TMPROOT/XXXXXX"); printf 'zz-slow\n' > "$tdir/catalog"
# ruling Z: without monitor mode an async launch starts with SIGINT ignored-on-entry (untrappable)
set -m
"$L" --runs-dir "$tdir/runs" --checks-dir "$F" --catalog "$tdir/catalog" --no-memory >"$tdir/out" 2>&1 &
pid=$!; set +m
sleep 2; kill -INT "$pid"; wait "$pid"; rc=$?
[ "$rc" -eq 130 ] || { echo "SIGINT rc=$rc want 130"; exit 1; }
grep -q 'aborted' "$tdir"/runs/*/report.md || { echo "aborted flag missing"; exit 1; }
# 9) missing-file ids trip the breaker (typos stop at exactly 3 rows, rc=1)
d=$(run_loop "zz-nope-1,zz-nope-2,zz-nope-3"); rc=$?
[ "$rc" -eq 1 ] || { echo "missing-file breaker rc=$rc want 1"; exit 1; }
n=$(wc -l < "$d"/runs/*/results.jsonl); [ "$n" -eq 3 ] || { echo "missing-file breaker should stop at 3, got $n"; exit 1; }
# 10) --dry-run runs checks, sets dry_run flag, rc=0
d=$(run_loop "zz-pass-a,zz-pass-b" --dry-run); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$d"/runs/*/results.jsonl)" -eq 2 ] \
  && grep -q 'dry_run=1' "$d"/runs/*/report.md || { echo "dry-run coverage failed (rc=$rc)"; exit 1; }
# 11) --only narrows a 2-id catalog to 1 line
d=$(run_loop "zz-pass-a,zz-pass-b" --only zz-pass-a); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$d"/runs/*/results.jsonl)" -eq 1 ] \
  || { echo "--only coverage failed (rc=$rc)"; exit 1; }
# 12) unknown arg -> exit 64
d=$(run_loop "zz-pass-a" --bogus); rc=$?
[ "$rc" -eq 64 ] || { echo "unknown-arg rc=$rc want 64"; exit 1; }
# 13) header-parse arm: fixture carries '# timeout: 1' on its own col-0 line (real-check format) -> killed at 1s, exit 3 + timeout evidence
grep -qE '^# timeout: 1$' "$F/zz-timeout.sh" || { echo "zz-timeout fixture lacks col-0 '# timeout: 1' header"; exit 1; }
d=$(run_loop "zz-timeout"); rc=$?
[ "$rc" -eq 0 ] || { echo "timeout stub loop rc=$rc want 0"; exit 1; }
grep -q '"exit":3' "$d"/runs/*/results.jsonl || { echo "timeout stub should be exit 3"; exit 1; }
grep -q ' timeout' "$d"/runs/*/results.jsonl || { echo "timeout missing from evidence (header not parsed?)"; exit 1; }
echo ok
