# checks/R1-recording-toggle.sh
# memory-query: recording toggle subscription setting uuid_record echo probe
# timeout: 120
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq R1; require curl R1
# R1 asserts the recording toggle posture + mechanism. Toggle rows live in
# recording_settings(subscription_id, setting in enabled|disabled|auto).
# R1_ROWS_FILE injects `sub<TAB>setting` lines for fixture tests; live path
# reads psql read-only (psql required only there, keeping fixture mode hermetic).
# Zero rows is recorded (default auto applies), not a failure. Mechanism proof:
# a labeled echo call with uuid_record start/stop +OK and a materialized file,
# channels 0-total around it.
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
if [ -n "${R1_ROWS_FILE:-}" ]; then
  [ -f "$R1_ROWS_FILE" ] || emit R1 3 "rows fixture missing: $R1_ROWS_FILE"
  cp "$R1_ROWS_FILE" "$TD/rows.tsv"
else
  require psql R1
  "${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX -F'	' \
    -c "SELECT subscription_id::text, setting FROM recording_settings" >"$TD/rows.tsv" 2>/dev/null \
    || emit R1 3 "recording_settings query failed"
fi
bad=$(awk -F'\t' '$2 !~ /^(enabled|disabled|auto)$/ {c++} END {print c+0}' "$TD/rows.tsv")
total=$(grep -c . "$TD/rows.tsv" || true); total=${total:-0}
[ "${bad:-0}" -gt 0 ] && emit R1 1 "invalid recording toggle values: bad=$bad of rows=$total (want enabled|disabled|auto)"
# ---- labeled mechanism probe via the API vehicle (own call only) ----
# Probe originates via POST /api/v1/calls (same vehicle as M1/D1).
# Labeled destination qbx-test-echo, channels 0-total around.
ch=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${ch:-1}" = 0 ] || emit R1 2 "stale sibling channels before run: total=${ch:-unreadable}"
. "$HARNESS_ROOT/lib/qbx_api.sh"
token=$(qbx_login) || emit R1 3 "api login failed (base=${R1_BASE_URL:-http://127.0.0.1:3006})"
base="${R1_BASE_URL:-http://127.0.0.1:3006}"
jar=$(mktemp); trap 'rm -rf "$TD" "$jar"' EXIT
csrf=$("${HOST_NS[@]}" curl -s -D - -o /dev/null -c "$jar" -b "$jar" "$base/api/v1/csrf" 2>/dev/null \
  | grep -i '^X-Csrf-Token:' | tr -d '\r' | awk '{print $2}')
[ -z "$csrf" ] && { unset token; emit R1 3 "csrf fetch failed"; }
key="qbx-r1-$RANDOM-$(date +%s)"
create=$("${HOST_NS[@]}" curl -s -b "$jar" -c "$jar" -H "Authorization: Bearer $token" \
  -H "X-Csrf-Token: $csrf" -H "Idempotency-Key: $key" -H 'Content-Type: application/json' \
  -X POST "$base/api/v1/calls" -d '{"to_number":"qbx-test-echo","from_extension":"2100"}' 2>/dev/null)
call_id=$(jq -r '.call_id // empty' <<<"$create" 2>/dev/null)
[ -z "$call_id" ] && { unset token; emit R1 1 "labeled call create failed: $(tr '\n' ' ' <<<"$create" | cut -c1-200)"; }
r1_hangup() { # best-effort DELETE of OUR call only; never touches other channels
  "${HOST_NS[@]}" curl -s -b "$jar" -H "Authorization: Bearer $token" -H "X-Csrf-Token: $csrf" \
    -X DELETE "$base/api/v1/calls/$call_id" >/dev/null 2>&1
}
r1_fail() { r1_hangup; unset token; emit R1 1 "$1"; }
FS="${R1_FS:-telecom-freeswitch-1}"
uuid=""
for _ in $(seq 1 30); do
  uuid=$(esl "show channels" 2>/dev/null | awk -F, '/^[0-9a-f]{8}-[0-9a-f-]{27}/{print $1; exit}')
  [ -n "$uuid" ] && break; sleep 1
done
[ -z "$uuid" ] && r1_fail "no channel for labeled call $call_id"
rec_path="/tmp/r1-probe-$uuid.wav"
st=$(esl "uuid_record $uuid start $rec_path" 2>&1)
grep -q '+OK' <<<"$st" || r1_fail "uuid_record start rejected: $(tr '\n' ' ' <<<"$st")"
sleep 3
sp=$(esl "uuid_record $uuid stop $rec_path" 2>&1)
grep -q '+OK' <<<"$sp" || r1_fail "uuid_record stop rejected: $(tr '\n' ' ' <<<"$sp")"
fsize=$(docker exec "$FS" sh -c "wc -c < '$rec_path' 2>/dev/null" | tr -d '[:space:]')
docker exec "$FS" rm -f "$rec_path" >/dev/null 2>&1
r1_hangup; unset token
[ "${fsize:-0}" -ge 1000 ] 2>/dev/null || emit R1 1 "recording file missing/tiny after uuid_record stop: bytes=${fsize:-none} (start_stop=+OK)"
sleep 2
left=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${left:-1}" = 0 ] || emit R1 1 "channels not empty after labeled call: total=${left:-unreadable} uuid=$uuid"
emit R1 0 "toggle rows=$total bad=0 (zero rows = default auto, recorded); uuid_record start_stop=+OK bytes=$fsize call=$call_id channels=0"
