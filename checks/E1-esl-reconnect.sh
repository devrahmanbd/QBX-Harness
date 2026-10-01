# checks/E1-esl-reconnect.sh
# memory-query: esl reconnect gateway ready
# timeout: 180
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require journalctl E1
# NOTE: esl() is a shell function; timeout(1) cannot exec functions, so inline its body here, interpolating the shared ${HOST_NS[*]} array.
st_raw=$(run_to 15 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'status'" 2>/dev/null)
st=$(head -3 <<<"$st_raw" | tr '\n' ' ')
grep -qi 'is ready' <<<"$st" || emit E1 3 "ESL auth/status failed: $st"
gws=$(run_to 15 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'sofia status gateway'" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
rc_raw=$(journalctl -u qbx-call-control.service --since "${E1_SINCE:--24h}" --no-pager 2>/dev/null \
        | grep -iE 'esl.*(reconnect|connected|ready)' || true)
rc_ev=$(tail -1 <<<"$rc_raw" | cut -c1-200)
[ -z "$rc_ev" ] && rc_ev="no reconnect event in window; fresh-auth proves path"
if [ "${E1_RESTART_PROBE:-0}" = "1" ]; then
  ch=$(esl "show channels" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
  [ "${ch:-0}" -gt 0 ] && emit E1 2 "restart probe blocked: $ch live channel(s)"
  docker restart "${FS_CONTAINER:-telecom-freeswitch-1}" >/dev/null || emit E1 1 "docker restart failed"
  ready=""
  for _ in $(seq 1 60); do
    r_raw=$(run_to 5 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'status'" 2>/dev/null)
    grep -qi 'is ready' <<<"$r_raw" && { ready=yes; break; }
    sleep 1
  done
  [ "$ready" != yes ] && emit E1 1 "FS not ready within 60s after restart"
  rc2_raw=$(journalctl -u qbx-call-control.service --since "-2 min" --no-pager 2>/dev/null \
           | grep -iE 'esl.*(connected|ready|reconnect)' || true)
  reconn=$(tail -1 <<<"$rc2_raw" | cut -c1-200)
  [ -z "$reconn" ] && emit E1 1 "call-control ESL reconnect not observed after restart"
  emit E1 0 "restart probe: ready after restart; reconnect='$reconn'; gateways=$(printf '%s' "$gws" | cut -c1-120)"
fi
emit E1 0 "status=ready; gateways=$(printf '%s' "$gws" | cut -c1-120); reconnect_evidence='$rc_ev'"
