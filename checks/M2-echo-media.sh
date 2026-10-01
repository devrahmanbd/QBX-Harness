# checks/M2-echo-media.sh
# memory-query: echo media rtp packet counters
# timeout: 90
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq M2; require psql M2; require python3 M2
RUN_DIR="${RUN_DIR:-/tmp}"
ext="${M2_EXT:-4000}"
ext_secret=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
  -c "SELECT secret FROM extensions WHERE extension_number='$ext'" 2>/dev/null)
[ -z "$ext_secret" ] && emit M2 3 "extension secret lookup empty for $ext"
"${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/sip_caller.py" 88.99.250.99 5080 qbx-test-echo \
  "${M2_SECONDS:-10}" --user "$ext" --pass "$ext_secret" >"$RUN_DIR/m2-caller.out" 2>&1 &
caller=$!; unset ext_secret
uuid=""
for _ in $(seq 1 6); do
  ch=$(esl "show channels" 2>/dev/null); uuid=$(awk -F, '/^[0-9a-f]{8}-[0-9a-f-]{27}/ && /,echo,/ {print $1; exit}' <<<"$ch")
  [ -n "$uuid" ] && break; sleep 1
done
if [ -z "$uuid" ]; then kill "$caller" 2>/dev/null; wait "$caller" 2>/dev/null
  emit M2 1 "echo channel never appeared: $(tr '\n' ' ' <"$RUN_DIR/m2-caller.out")"; fi
esl "uuid_set_media_stats $uuid" >/dev/null 2>&1; sleep 2
esl "uuid_set_media_stats $uuid" >/dev/null 2>&1
dump=$(esl "uuid_dump $uuid json" 2>/dev/null)
in_n=$(printf '%s' "$dump" | jq -r '.variable_rtp_audio_in_packet_count // 0')
out_n=$(printf '%s' "$dump" | jq -r '.variable_rtp_audio_out_packet_count // 0')
app=$(printf '%s' "$dump" | jq -r '.variable_current_application // "n/a"')
min=${M2_MIN_PACKETS:-50}
[ "${in_n:-0}" -le "$min" ] || [ "${out_n:-0}" -le "$min" ] && \
  emit M2 1 "counters below floor: in=$in_n out=$out_n min=$min app=$app"
wait "$caller"; caller_rc=$?
grep -q 'invite=.*200' "$RUN_DIR/m2-caller.out" && grep -q 'bye=.*200' "$RUN_DIR/m2-caller.out" \
  || emit M2 1 "caller did not complete cleanly: $(tr '\n' ' ' <"$RUN_DIR/m2-caller.out")"
[ "$caller_rc" -ne 0 ] && emit M2 1 "caller rc=$caller_rc: $(tr '\n' ' ' <"$RUN_DIR/m2-caller.out")"
sleep 2
left=$(esl "show channels like $uuid" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
[ "${left:-0}" -gt 0 ] && emit M2 1 "channel not hung up after BYE: $uuid"
inv=$(grep -m1 '^invite=' "$RUN_DIR/m2-caller.out"); byel=$(grep -m1 '^bye=' "$RUN_DIR/m2-caller.out")
emit M2 0 "app=$app in=$in_n out=$out_n min=$min; $inv $byel; channel gone"
