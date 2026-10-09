#!/usr/bin/env bash
# bin/watchdog.sh — missed-run + red-sweep verdict for the daily timer sweep.
# Read-only over runs/ (never deletes); optionally exports node_exporter
# textfile metrics consumed by /etc/prometheus/rules/qbx-harness.yml.
#
# Exit contract (mirrors bin/loop): 0 ok (green, tolerated-only, noted-only, or
# too early to judge a miss) / 1 incident (missed run past fire+grace, or
# untolerated EXIT-1 red) / 130 aborted by signal. 64 = bad usage
# (same convention as loop's CLI errors). 2 is never used.
# Paging scope (spec): ONLY exit 1 pages. Untolerated exit 2/3 lines are
# recorded in the non-paging qbx_harness_check_note series and never alert.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
. "$H/lib/common.sh"
RUNS_DIR="$H/runs"; FIRE="03:00"; GRACE_MIN=30; TEXTFILE_DIR="/var/lib/prometheus/node-exporter"; METRICS=1; NOW=""
while [ $# -gt 0 ]; do case "$1" in
  --runs-dir) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; RUNS_DIR="$2"; shift 2;;
  --fire-time) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; FIRE="$2"; shift 2;;
  --grace-min) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; GRACE_MIN="$2"; shift 2;;
  --textfile-dir) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; TEXTFILE_DIR="$2"; shift 2;;
  --no-metrics) METRICS=0; shift;;
  --now) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 64; }; NOW="$2"; shift 2;;
  -h|--help) sed -n '1,12p' "$0"; exit 0;;
  *) echo "unknown arg $1" >&2; exit 64;;
esac; done
[[ "$FIRE" =~ ^[0-9]{2}:[0-9]{2}$ ]] || { echo "bad --fire-time (want HH:MM): $FIRE" >&2; exit 64; }
[[ "$GRACE_MIN" =~ ^[0-9]+$ ]] || { echo "bad --grace-min: $GRACE_MIN" >&2; exit 64; }
on_sig() { exit 130; }; trap on_sig INT TERM

now=$( [ -n "$NOW" ] && printf '%s' "$NOW" || date -u +%s )
day=$(date -u -d "@$now" +%F)
fire=$(date -u -d "$day $FIRE UTC" +%s)
last_fire=$fire
[ "$now" -lt $((fire + GRACE_MIN * 60)) ] && last_fire=$(date -u -d "$day $FIRE UTC -1 day" +%s)

# Tolerated-red substrings — canonical list lives in docs/governed-runs.md
# ("Tolerated-red paging exclusion"). Keep both in sync.
TOLERATED=(
  "Cannot find profile qbx.qubickle.com"   # L1 accepted cost (M3 teardown ERR)
)
# Tolerated check IDs with expiry — canonical list in docs/governed-runs.md.
# MEM-GATE exits 1 by design while the mem0 quota freeze lasts (remove after
# 2026-11-01 once the gate is re-verified green); its evidence line carries no
# stable match string, so the ID itself is the tolerated key until expiry.
TOLERATED_IDS_EXPIRED_AFTER="2026-11-01"
TOLERATED_IDS=(MEM-GATE)
EXP_EP=$(date -u -d "$TOLERATED_IDS_EXPIRED_AFTER UTC" +%s 2>/dev/null || echo 0)
tolerated() { local id="$1" ev="$2" t i; for t in "${TOLERATED[@]}"; do
  case "$ev" in *"$t"*) return 0;; esac; done
  if [ "$EXP_EP" -gt 0 ] && [ "$now" -ge "$EXP_EP" ]; then return 1; fi  # lapsed: ID tolerance no longer applies
  for i in "${TOLERATED_IDS[@]}"; do [ "$id" = "$i" ] && return 0; done
  return 1; }
if [ "$EXP_EP" -gt 0 ] && [ "$now" -lt "$EXP_EP" ] && [ $((EXP_EP - now)) -le $((7*86400)) ]; then
  echo "watchdog: WARNING MEM-GATE ID tolerance expires in $(((EXP_EP - now + 86399)/86400))d ($TOLERATED_IDS_EXPIRED_AFTER) — remove or re-justify" >&2
fi

latest=""; latest_ts=0
if [ -d "$RUNS_DIR" ]; then
  while IFS= read -r d; do
    ts="${d##*/}"; ts="${ts%%-*}"
    ep=$(date -u -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2} UTC" +%s 2>/dev/null || echo 0)
    [ "$ep" -gt "$latest_ts" ] && [ -f "$d/results.jsonl" ] && { latest="$d"; latest_ts="$ep"; }
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

missed=0; reds=""; redn=0; notes=""; notn=0; toln=0; run_id="-"
if [ -z "$latest" ]; then
  if [ "$now" -gt $((last_fire + GRACE_MIN * 60)) ]; then
    missed=1; echo "WATCHDOG INCIDENT missed-run: no runs/<ts>/ artifact past scheduled fire $(date -u -d "@$last_fire" +%Y%m%dT%H%M%SZ) + ${GRACE_MIN}min grace"
  fi
else
  run_id="${latest##*/}"
  while IFS= read -r line || [ -n "$line" ]; do
    c=$(printf '%s' "$line" | jq -r '.check // "?"' 2>/dev/null)
    e=$(printf '%s' "$line" | jq -r '.exit // 3' 2>/dev/null)
    ev=$(printf '%s' "$line" | jq -r '.evidence // ""' 2>/dev/null)
    [ "$e" = "0" ] && continue
    if tolerated "$c" "$ev"; then toln=$((toln+1));
    elif [ "$e" = "1" ]; then reds="$reds $c=$e"; redn=$((redn+1));
    else notes="$notes $c=$e"; notn=$((notn+1)); fi   # exit 2/3: recorded, never pages
  done < "$latest/results.jsonl"
  if [ "$latest_ts" -lt "$last_fire" ] && [ "$now" -gt $((last_fire + GRACE_MIN * 60)) ]; then
    missed=1; echo "WATCHDOG INCIDENT missed-run: latest artifact $run_id predates scheduled fire $(date -u -d "@$last_fire" +%Y%m%dT%H%M%SZ) + ${GRACE_MIN}min grace"
  fi
  [ "$redn" -gt 0 ] && echo "WATCHDOG INCIDENT red-sweep: $run_id untolerated exit-1:$reds (tolerated-excluded=$toln, noted-nonpaging:$notn, see docs/governed-runs.md)"
  [ "$notn" -gt 0 ] && echo "watchdog: $run_id noted-nonpaging:$notes (exit 2/3 recorded, never pages)"
fi

if [ "$METRICS" -eq 1 ] && [ -n "${TEXTFILE_DIR:-}" ]; then
  if [ -d "$TEXTFILE_DIR" ] && [ -w "$TEXTFILE_DIR" ]; then
    tmp="$TEXTFILE_DIR/.qbx-harness.$$.prom"
    { echo "# HELP qbx_harness_last_run_timestamp_seconds Start time of latest sweep artifact (0 when none)."
      echo "# TYPE qbx_harness_last_run_timestamp_seconds gauge"
      printf 'qbx_harness_last_run_timestamp_seconds{run_id="%s"} %s\n' "$run_id" "$latest_ts"
      echo "# HELP qbx_harness_untolerated_red_count Non-tolerated nonzero checks in latest sweep (pages)."
      echo "# TYPE qbx_harness_untolerated_red_count gauge"
      echo "qbx_harness_untolerated_red_count $redn"
      echo "# HELP qbx_harness_tolerated_red_count Tolerated-red lines recorded but never paged."
      echo "# TYPE qbx_harness_tolerated_red_count gauge"
      echo "qbx_harness_tolerated_red_count $toln"
      echo "# HELP qbx_harness_missed_run 1 when past fire+grace with no artifact."
      echo "# TYPE qbx_harness_missed_run gauge"
      echo "qbx_harness_missed_run $missed"
      echo "# HELP qbx_harness_check_exit Exit code per untolerated EXIT-1 check (the only paging series)."
      echo "# TYPE qbx_harness_check_exit gauge"
      for r in $reds; do c="${r%%=*}"; v="${r##*=}"
        printf 'qbx_harness_check_exit{check="%s",run_id="%s"} %s\n' "$c" "$run_id" "$v"
      done
      echo "# HELP qbx_harness_check_note Exit code per untolerated exit-2/3 check (recorded, never pages)."
      echo "# TYPE qbx_harness_check_note gauge"
      for r in $notes; do c="${r%%=*}"; v="${r##*=}"
        printf 'qbx_harness_check_note{check="%s",run_id="%s"} %s\n' "$c" "$run_id" "$v"
      done
    } > "$tmp" && mv "$tmp" "$TEXTFILE_DIR/qbx-harness.prom" \
      || { echo "watchdog: metric write failed (non-fatal)" >&2; rm -f "$tmp"; }
  else echo "watchdog: textfile dir unwritable, metrics skipped (non-fatal): $TEXTFILE_DIR" >&2; fi
fi

if [ "$missed" -eq 1 ] || [ "$redn" -gt 0 ]; then exit 1; fi
[ -z "$latest" ] && echo "watchdog: no artifact yet, inside grace (last fire $(date -u -d "@$last_fire" +%Y%m%dT%H%M%SZ)) — ok"
[ -n "$latest" ] && [ "$redn" -eq 0 ] && echo "watchdog: $run_id ok (tolerated-excluded=$toln noted-nonpaging=$notn)"
exit 0
