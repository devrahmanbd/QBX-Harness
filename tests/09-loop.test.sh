# tests/09-loop.test.sh
#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness
L="$H/bin/loop"; R="$H/bin/report"
mkdir -p "$H/tests/fixtures/loop"
gen() { printf '#!/usr/bin/env bash\nHARNESS_ROOT=%s; . "$HARNESS_ROOT/lib/common.sh"\n%s\n' "$H" "$2" > "$1"; chmod +x "$1"; }
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
# 2) breaker: error stub repeated -> stops after exactly 3 executions, rc=1, breaker flag
d=$(run_loop "zz-error,zz-error,zz-error,zz-error"); rc=$?
[ "$rc" -eq 1 ] || { echo "breaker loop rc=$rc want 1"; exit 1; }
n=$(wc -l < "$d"/runs/*/results.jsonl); [ "$n" -eq 3 ] || { echo "breaker should stop at 3, got $n"; exit 1; }
grep -q 'breaker' "$d"/runs/*/report.md || { echo "report lacks breaker note"; exit 1; }
# 3) open findings never trip: 4 exit-1 stubs all execute, rc=0
d=$(run_loop "zz-open-1,zz-open-2,zz-open-3,zz-open-4"); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$d"/runs/*/results.jsonl)" -eq 4 ] \
  || { echo "open-finding run should complete"; exit 1; }
# 4) blocked completes with class blocked
d=$(run_loop "zz-blocked,zz-pass-a"); rc=$?
[ "$rc" -eq 0 ] && grep -q 'blocked' "$d"/runs/*/report.md || { echo "blocked class missing"; exit 1; }
# 5) exit 130 normalized to 3 with normalized_from
d=$(run_loop "zz-exit130,zz-pass-a,zz-pass-a,zz-pass-a"); rc=$?
grep -q 'normalized_from=130' "$d"/runs/*/results.jsonl || { echo "exit130 not normalized"; exit 1; }
# 6) redaction: planted secret absent, marker present
d=$(run_loop "zz-leaky,zz-pass-a")
grep -q 'hunter2' "$d"/runs/*/results.jsonl "$d"/runs/*/report.md 2>/dev/null && { echo "secret leaked"; exit 1; }
grep -q '<redacted>' "$d"/runs/*/results.jsonl || { echo "redaction marker missing"; exit 1; }
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
echo ok
