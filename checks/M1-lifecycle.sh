# checks/M1-lifecycle.sh
# memory-query: call lifecycle cdr idempotency
# timeout: 120
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq M1; require curl M1; require psql M1
. "$HARNESS_ROOT/lib/qbx_api.sh"
token=$(qbx_login) || emit M1 3 "api login failed (base=${M1_BASE_URL:-http://127.0.0.1:3006})"
RUN_DIR="${RUN_DIR:-/tmp}"; art="$RUN_DIR/m1-lifecycle.json"
QBX_E2E_TOKEN="$token" QBX_BASE_URL="${M1_BASE_URL:-http://127.0.0.1:3006}" \
  run_to "${M1_TIMEOUT:-90}" "${HOST_NS[@]}" python3 /root/QBX/scripts/qbx-deterministic-call-lifecycle.py \
    --mode live --output "$art" --base-url "${M1_BASE_URL:-http://127.0.0.1:3006}" --from-extension 2100 >/dev/null 2>&1
rc=$?; unset token
# spec legend: 0->0, 1->1, 3(blocked)->2, 2(exception)->3; timeout(124)/other -> 3
case "$rc" in
  0) :;; 1) emit M1 1 "lifecycle script reported failure";;
  3) emit M1 2 "lifecycle script blocked";;
  2) emit M1 3 "lifecycle script exception";;
  124) emit M1 3 "lifecycle script timeout";;
  *) emit M1 3 "lifecycle script exit normalized_from=$rc";;
esac
[ -f "$art" ] || emit M1 3 "artifact missing: $art"
# Wave-B extension (early-media answer-proof assertion ONLY): the lifecycle
# timeline must contain a CHANNEL_ANSWER event — the leg was really answered,
# not early-media false-answer. M1_ART_FILE injects a canned artifact for
# fixture tests (live path still runs the script above).
[ -n "${M1_ART_FILE:-}" ] && { [ -f "$M1_ART_FILE" ] || emit M1 3 "artifact fixture missing: $M1_ART_FILE"; art="$M1_ART_FILE"; }
jq -e '[.events[]? | select(((.event_type // .type // .state // "") | ascii_upcase) == "CHANNEL_ANSWER")] | length >= 1' "$art" >/dev/null \
  || emit M1 1 "answer proof absent: no CHANNEL_ANSWER in lifecycle timeline"
jq -e '.result=="pass" and .validation.passed==true' "$art" >/dev/null || \
  emit M1 1 "artifact not pass: $(jq -c '{result,validation}' "$art" 2>/dev/null)"
call_id=$(jq -r '.call_id // empty' "$art")
[ -z "$call_id" ] && call_id=$(jq -r 'first(.requests[]? | select(.operation=="create") | .response.call_id // empty) // empty' "$art")
if [ -z "$call_id" ]; then
  call_id=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
    -c "SELECT call_id FROM cdrs WHERE to_number='qbx-test-echo' AND started_at > now() - interval '5 minutes' ORDER BY started_at DESC LIMIT 1" 2>/dev/null | head -1)
fi
[ -z "$call_id" ] && emit M1 1 "no call_id located for CDR assertion"
cdr=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
  -c "SELECT status||'/'||duration||'/'||sip_code||'/'||hangup_cause FROM cdrs WHERE call_id='$call_id'" 2>/dev/null)
[ -z "$cdr" ] && emit M1 1 "cdrs row missing for $call_id"
left=$(esl "show channels like $call_id" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
[ "${left:-0}" -gt 0 ] && emit M1 1 "channel still alive after lifecycle: $call_id"
emit M1 0 "result=pass validation=passed call_id=$call_id cdr=$cdr channels=0"
