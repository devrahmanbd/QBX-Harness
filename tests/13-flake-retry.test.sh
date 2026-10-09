# tests/13-flake-retry.test.sh — flake accounting + infra-only retry budgets.
#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
L="$H/bin/loop"; F="$H/bin/flake-rates"
export QBX_RETRY_BUDGET=2 QBX_RETRY_DELAY_S=0
TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT
export FLAKE_STATE="$TMPROOT/state"; mkdir -p "$FLAKE_STATE" "$H/tests/fixtures/retry"
G="$H/tests/fixtures/retry"
gen() { printf '#!/usr/bin/env bash\nHARNESS_ROOT="${HARNESS_ROOT:-%s}"; . "$HARNESS_ROOT/lib/common.sh"\n%s\n' "$H" "$2" > "$1"; chmod +x "$1"; }
# flaky-infra: attempt 1 = infra (timeout, no channel), attempt 2+ = pass
gen "$G/zz-flaky-infra.sh" 'c="$FLAKE_STATE/zz-flaky-infra.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
if [ "$n" -le 1 ]; then emit ZZFLK 3 "timeout simulated: uuid-poll no channel (attempt $n)"; else emit ZZFLK 0 "recovered on attempt $n"; fi'
# hard-infra: always exit 3 with sibling-residue evidence
gen "$G/zz-hard-infra.sh" 'c="$FLAKE_STATE/zz-hard-infra.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
emit ZZHRD 3 "stale sibling channels before run: total=2 (attempt $n)"'
# scored: always exit 1 on real evidence
gen "$G/zz-scored.sh" 'c="$FLAKE_STATE/zz-scored.count"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
emit ZZSC 1 "real finding signature (attempt $n)"'
run_loop() {
  local list="$1"; shift
  local tdir; tdir=$(mktemp -d "$TMPROOT/XXXXXX")
  printf '%s\n' ${list//,/ } > "$tdir/catalog"
  local lrc
  RUNS="$tdir/runs" "$L" --runs-dir "$tdir/runs" --checks-dir "$G" \
    --catalog "$tdir/catalog" --no-memory "$@" >"$tdir/loop.out" 2>&1; lrc=$?
  echo "$tdir"
  return "$lrc"
}
# 1) aggregates compute over historical runs/ dirs
hdir=$(mktemp -d "$TMPROOT/XXXXXX"); mkdir -p "$hdir/runs/r1" "$hdir/runs/r2" "$hdir/runs/r3"
printf '%s\n' '{"check":"ZZAGG","exit":0,"evidence":"ok","ts":"x"}' > "$hdir/runs/r1/results.jsonl"
printf '%s\n' '{"check":"ZZAGG","exit":1,"evidence":"finding","ts":"x"}' > "$hdir/runs/r2/results.jsonl"
printf '%s\n' '{"check":"ZZAGG","exit":0,"evidence":"ok","ts":"x","duration_s":4}' > "$hdir/runs/r3/results.jsonl"
out=$("$F" --runs-dir "$hdir/runs") || { echo "aggregator failed"; exit 1; }
echo "$out" | grep -q '^ZZAGG[[:space:]]' || { echo "aggregator missing ZZAGG row"; exit 1; }
echo "$out" | awk '$1=="ZZAGG"{exit !($9>0)}' || { echo "ZZAGG flake_rate should be >0"; exit 1; }

# 2) infra failure retries within budget, then records infra (exit 3, never flipped to 1)
rm -f "$FLAKE_STATE/zz-hard-infra.count"
d=$(run_loop "zz-hard-infra"); rc=$?
tries=$(cat "$FLAKE_STATE/zz-hard-infra.count")
[ "$tries" -eq 3 ] || { echo "hard-infra tries=$tries want 3 (1+2 budget)"; exit 1; }
grep -q '"check":"ZZHRD","exit":3' "$d"/runs/*/results.jsonl || { echo "hard-infra final not exit 3"; exit 1; }
grep -q '"exit":1' "$d"/runs/*/results.jsonl && { echo "infra flipped to exit 1"; exit 1; }
[ -s "$d"/runs/*/retries.jsonl ] || { echo "retry attempts not logged (retries.jsonl)"; exit 1; }
[ -s "$d"/runs/*/retries.log ] || { echo "retry attempts not logged (retries.log)"; exit 1; }
grep -q 'attempt 2/2' "$d"/runs/*/retries.log || { echo "budget cap not visible in retries.log"; exit 1; }
# flaky-infra recovers via retry: final pass, attempts logged
rm -f "$FLAKE_STATE/zz-flaky-infra.count"
d=$(run_loop "zz-flaky-infra"); rc=$?
[ "$(cat "$FLAKE_STATE/zz-flaky-infra.count")" -eq 2 ] || { echo "flaky-infra should take 2 executions"; exit 1; }
grep -q '"check":"ZZFLK","exit":0' "$d"/runs/*/results.jsonl || { echo "flaky-infra final not pass"; exit 1; }
grep -q 'ZZFLK' "$d"/runs/*/retries.jsonl || { echo "flaky retry attempt missing"; exit 1; }

# 3) scored failure never retries
rm -f "$FLAKE_STATE/zz-scored.count"
d=$(run_loop "zz-scored"); rc=$?
[ "$(cat "$FLAKE_STATE/zz-scored.count")" -eq 1 ] || { echo "scored executed more than once"; exit 1; }
grep -q '"check":"ZZSC","exit":1' "$d"/runs/*/results.jsonl || { echo "scored final not exit 1"; exit 1; }
if [ -f "$d"/runs/*/retries.jsonl ]; then grep -q 'ZZSC' "$d"/runs/*/retries.jsonl && { echo "scored failure was retried"; exit 1; }; fi

# 4) retries counted INTO flake rates
hdir2=$(mktemp -d "$TMPROOT/XXXXXX"); mkdir -p "$hdir2/runs/r1" "$hdir2/runs/r2"
printf '%s\n' '{"check":"ZZCT","exit":0,"evidence":"ok","ts":"x"}' > "$hdir2/runs/r1/results.jsonl"
printf '%s\n' '{"check":"ZZCT","exit":0,"evidence":"recovered","ts":"x"}' > "$hdir2/runs/r2/results.jsonl"
printf '%s\n' '{"check":"ZZCT","exit":3,"evidence":"timeout","ts":"x","attempt":1,"final":0}' \
  '{"check":"ZZCT","exit":3,"evidence":"timeout","ts":"x","attempt":2,"final":0}' > "$hdir2/runs/r2/retries.jsonl"
out=$("$F" --runs-dir "$hdir2/runs") || { echo "aggregator failed (4)"; exit 1; }
echo "$out" | awk '$1=="ZZCT"{exit !($3==4 && $7==2 && $9>0)}' \
  || { echo "retries not counted into flake rates: $out"; exit 1; }
echo ok
