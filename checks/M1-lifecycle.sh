# checks/M1-lifecycle.sh
# memory-query: call lifecycle cdr idempotency
# timeout: 120
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq M1; require curl M1; require psql M1
. "$HARNESS_ROOT/lib/qbx_api.sh"
# Post-run containment (cascade fix): the lifecycle vehicle intermittently leaves
# qbx-test-echo legs behind after reporting pass; without a sweep that residue
# shadows M2's selector and trips M3/V2/R1/D1. Mirror M3/V2: kill all listed
# channels on ALL exit paths (trap) and assert channels=0 post-run (force-clean).
m1_uuids=""; m1_cleaned=0; m1_report=""; m1_done=""
m1_gone() {  # uuid -> 0 once the channel is really gone (bounded wait, mirrors V2 v2_gone)
  local u="$1" i n=1
  for i in 1 2 3; do
    n=$(esl "show channels like $u" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
    [ "${n:-0}" -eq 0 ] && return 0
    sleep 1
  done
  return 1
}
m1_sweep() {  # kill every listed channel (own vehicle + strays) by uuid, verify each; sets m1_cleaned/m1_report
  local u left=""
  m1_uuids=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9a-f]{8}-[0-9a-f-]{27}' | sort -u)
  [ -z "$m1_uuids" ] && { m1_report="channels none"; return 0; }
  for u in $m1_uuids; do
    esl "uuid_kill $u" >/dev/null 2>&1
    if m1_gone "$u"; then m1_cleaned=$((m1_cleaned+1)); else left="$left $u"; fi
  done
  m1_report="residue-cleaned=$m1_cleaned leftover:${left:- none}"
  [ -z "$left" ]
}
m1_cleanup() {  # trap on ALL paths incl. emit exits; output-free, outcome in m1_report
  [ "${m1_done:-}" = yes ] && return 0
  m1_sweep >/dev/null 2>&1 || true
  m1_done=yes
  return 0
}
m1_fail() { m1_cleanup; emit M1 1 "$1; cleanup: ${m1_report:-unavailable}"; }  # mirrors M3 m3_fail
trap m1_cleanup INT TERM EXIT
# M1_SKIP_LIVE=1 + M1_ART_FILE + M1_CDR_FAKE: hermetic fixture seam (tests only) —
# skips the vehicle run and the psql CDR read; validation + sweep run for real.
if [ -z "${M1_SKIP_LIVE:-}" ]; then
token=$(qbx_login) || emit M1 3 "api login failed (base=${M1_BASE_URL:-http://127.0.0.1:3006})"
RUN_DIR="${RUN_DIR:-/tmp}"; art="$RUN_DIR/m1-lifecycle.json"
QBX_E2E_TOKEN="$token" QBX_BASE_URL="${M1_BASE_URL:-http://127.0.0.1:3006}" \
  run_to "${M1_TIMEOUT:-90}" "${HOST_NS[@]}" python3 /root/QBX/scripts/qbx-deterministic-call-lifecycle.py \
    --mode live --output "$art" --base-url "${M1_BASE_URL:-http://127.0.0.1:3006}" --from-extension 2100 >/dev/null 2>&1
rc=$?; unset token
# spec legend: 0->0, 1->1, 3(blocked)->2, 2(exception)->3; timeout(124)/other -> 3
case "$rc" in
  0) :;; 1) m1_fail "lifecycle script reported failure";;
  3) emit M1 2 "lifecycle script blocked";;
  2) emit M1 3 "lifecycle script exception";;
  124) emit M1 3 "lifecycle script timeout";;
  *) emit M1 3 "lifecycle script exit normalized_from=$rc";;
esac
[ -f "$art" ] || emit M1 3 "artifact missing: $art"
else
  RUN_DIR="${RUN_DIR:-/tmp}"; art="$RUN_DIR/m1-lifecycle.json"
fi
# Wave-B extension (early-media answer-proof assertion ONLY): the lifecycle
# timeline must contain a CHANNEL_ANSWER event — the leg was really answered,
# not early-media false-answer. M1_ART_FILE injects a canned artifact for
# fixture tests (live path still runs the script above).
[ -n "${M1_ART_FILE:-}" ] && { [ -f "$M1_ART_FILE" ] || emit M1 3 "artifact fixture missing: $M1_ART_FILE"; art="$M1_ART_FILE"; }
jq -e '[.events[]? | select(((.event_type // .type // .state // "") | ascii_upcase) == "CHANNEL_ANSWER")] | length >= 1' "$art" >/dev/null \
  || m1_fail "answer proof absent: no CHANNEL_ANSWER in lifecycle timeline"
jq -e '.result=="pass" and .validation.passed==true' "$art" >/dev/null || \
  m1_fail "artifact not pass: $(jq -c '{result,validation}' "$art" 2>/dev/null)"
call_id=$(jq -r '.call_id // empty' "$art")
[ -z "$call_id" ] && call_id=$(jq -r 'first(.requests[]? | select(.operation=="create") | .response.call_id // empty) // empty' "$art")
if [ -z "$call_id" ]; then
  call_id=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
    -c "SELECT call_id FROM cdrs WHERE to_number='qbx-test-echo' AND started_at > now() - interval '5 minutes' ORDER BY started_at DESC LIMIT 1" 2>/dev/null | head -1)
fi
[ -z "$call_id" ] && m1_fail "no call_id located for CDR assertion"
if [ -n "${M1_CDR_FAKE:-}" ]; then cdr="$M1_CDR_FAKE"; else
cdr=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
  -c "SELECT status||'/'||duration||'/'||sip_code||'/'||hangup_cause FROM cdrs WHERE call_id='$call_id'" 2>/dev/null)
fi
[ -z "$cdr" ] && m1_fail "cdrs row missing for $call_id"
# post-run channels=0 assertion with force-clean (M3/V2 pattern): sweep the full
# listing (own vehicle + any strays) by uuid with bounded kill+verify each.
# cleaned -> exit 0 with residue-cleaned=N; unkillable -> exit 1 naming uuids.
m1_sweep; sweep_rc=$?
ch=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
m1_done=yes
if [ "$sweep_rc" -eq 0 ] && [ "${ch:-1}" = 0 ]; then
  emit M1 0 "result=pass validation=passed call_id=$call_id cdr=$cdr channels=0 residue-cleaned=$m1_cleaned"
else
  emit M1 1 "channels not empty after run: total=${ch:-unreadable} cleanup: $m1_report"
fi
