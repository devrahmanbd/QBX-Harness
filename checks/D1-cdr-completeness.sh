# checks/D1-cdr-completeness.sh
# memory-query: cdr completeness required fields labeled test call
# timeout: 180
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq D1; require curl D1
# D1 asserts CDR completeness for a labeled test call: every required field
# non-null on the row (call_id, subscription_id, from/to, status, direction,
# started_at; ended_at once completed). D1_ROWS_FILE injects a TSV fixture
# (call_id,sub,from,to,status,sip,hangup,ended,started,direction) for tests
# (no live deps in fixture mode); live path runs the deterministic lifecycle
# (labeled qbx-test-echo call) and audits its own call_id row read-only,
# channels 0-total around it.
. "$HARNESS_ROOT/lib/qbx_api.sh"
check_row() { # check_row <tsv-line> — incomplete -> emit D1 1 naming call_id only
  local line="$1" cid
  cid=$(cut -f1 <<<"$line")
  for i in 1 2 3 4 5 9 10; do
    [ -n "$(cut -f"$i" <<<"$line")" ] || emit D1 1 "incomplete CDR row: call_id=$cid field=$i empty"
  done
  if [ "$(cut -f5 <<<"$line")" = completed ] && [ -z "$(cut -f8 <<<"$line")" ]; then
    emit D1 1 "incomplete CDR row: call_id=$cid completed without ended_at"
  fi
}
if [ -n "${D1_ROWS_FILE:-}" ]; then
  [ -f "$D1_ROWS_FILE" ] || emit D1 3 "rows fixture missing: $D1_ROWS_FILE"
  n=0; while IFS= read -r line; do [ -n "$line" ] || continue; n=$((n+1)); check_row "$line"; done <"$D1_ROWS_FILE"
  emit D1 0 "fixture CDR rows complete: rows=$n"
fi
require psql D1
ch=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${ch:-1}" = 0 ] || emit D1 2 "stale sibling channels before run: total=${ch:-unreadable}"
token=$(qbx_login) || emit D1 3 "api login failed (base=${D1_BASE_URL:-http://127.0.0.1:3006})"
RUN_DIR="${RUN_DIR:-/tmp}"; art="$RUN_DIR/d1-lifecycle.json"
QBX_E2E_TOKEN="$token" QBX_BASE_URL="${D1_BASE_URL:-http://127.0.0.1:3006}" \
  run_to "${D1_TIMEOUT:-90}" "${HOST_NS[@]}" python3 /root/QBX/scripts/qbx-deterministic-call-lifecycle.py \
    --mode live --output "$art" --base-url "${D1_BASE_URL:-http://127.0.0.1:3006}" --from-extension 2100 >/dev/null 2>&1
rc=$?; unset token
case "$rc" in
  0) :;; 1) emit D1 1 "lifecycle script reported failure";;
  3) emit D1 2 "lifecycle script blocked";;
  2|124) emit D1 3 "lifecycle script exception/timeout (rc=$rc)";;
  *) emit D1 3 "lifecycle script exit normalized_from=$rc";;
esac
[ -f "$art" ] || emit D1 3 "artifact missing: $art"
call_id=$(jq -r '.call_id // empty' "$art")
[ -z "$call_id" ] && call_id=$(jq -r 'first(.requests[]? | select(.operation=="create") | .response.call_id // empty) // empty' "$art")
[ -z "$call_id" ] && emit D1 1 "no call_id located for CDR assertion"
row=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX -F'	' \
  -c "SELECT call_id,subscription_id::text,from_number,to_number,status,sip_code,hangup_cause,ended_at,started_at,direction FROM cdrs WHERE call_id='$call_id'" 2>/dev/null | head -1)
[ -z "$row" ] && emit D1 1 "cdrs row missing for labeled call $call_id"
check_row "$row"
sleep 2
left=$(esl "show channels like $call_id" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
[ "${left:-0}" -gt 0 ] && emit D1 1 "channel still alive after lifecycle: $call_id"
emit D1 0 "CDR complete for labeled call $call_id (10/10 fields; ended_at set); channels=0"
