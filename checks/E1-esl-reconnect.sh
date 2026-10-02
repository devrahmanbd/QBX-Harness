# checks/E1-esl-reconnect.sh
# memory-query: esl reconnect gateway ready
# timeout: 300
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require journalctl E1
# NOTE: esl() is a shell function; timeout(1) cannot exec functions, so inline its body here, interpolating the shared ${HOST_NS[*]} array.
st_raw=$(run_to 15 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'status'" 2>/dev/null)
st=$(head -3 <<<"$st_raw" | tr '\n' ' ')
grep -qi 'is ready' <<<"$st" || emit E1 3 "ESL auth/status failed: $st"
gw_raw=$(run_to 15 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'sofia status gateway'" 2>/dev/null); gw_rc=$?
gws=$(tr '\n' ' ' <<<"$gw_raw" | cut -c1-200)
if [ "$gw_rc" -ne 0 ] || [ -z "$gw_raw" ]; then emit E1 3 "sofia status gateway unreadable (rc=$gw_rc, ${#gw_raw} bytes)"; fi
gw_rows=$(grep -vE '^[[:space:]]*$|^=+$|Gateway-Name|[0-9]+ gateways:' <<<"$gw_raw" | grep -cE '[[:alnum:]]' || true)
[ "${gw_rows:-0}" -eq 0 ] && emit E1 2 "no gateways listed (trunk pending?)"
rc_raw=$(journalctl -u qbx-call-control.service --since "${E1_SINCE:--24h}" --no-pager 2>/dev/null \
        | grep -iE 'Successfully reconnected|ESL reconnected|attempting to reconnect' || true)
rc_ev=$(tail -1 <<<"$rc_raw" | cut -c1-200)
[ -z "$rc_ev" ] && rc_ev="NO journal reconnect evidence in window; verdict from fresh esl status + gateways in this line"
if [ "${E1_RESTART_PROBE:-0}" = "1" ]; then
  ch_raw=$(run_to 15 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'show channels'" 2>/dev/null)
  case "$ch_raw" in (*total.*) ;; *) emit E1 1 "channel count unreadable; restart probe not authorized" ;; esac
  ch=$(grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}' <<<"$ch_raw")
  [ "${ch:-0}" -gt 0 ] && emit E1 2 "restart probe blocked: $ch live channel(s)"
  t0=$(date +%s)
  dr=$(docker restart "${FS_CONTAINER:-telecom-freeswitch-1}" 2>&1) || emit E1 1 "docker restart failed: $dr"
  ready=""
  deadline=$((SECONDS+60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    r_raw=$(run_to 5 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'status'" 2>/dev/null)
    grep -qi 'is ready' <<<"$r_raw" && { ready=yes; break; }
    sleep 1
  done
  [ "$ready" != yes ] && emit E1 1 "FS not ready within 60s after restart"
  rc2_raw=$(journalctl -u qbx-call-control.service --since "@$t0" --no-pager 2>/dev/null \
           | grep -iE 'Successfully reconnected|ESL reconnected|attempting to reconnect' || true)
  reconn=$(tail -1 <<<"$rc2_raw" | cut -c1-200)
  [ -z "$reconn" ] && emit E1 1 "call-control ESL reconnect not observed after restart"
  emit E1 0 "restart probe: ready after restart; reconnect='$reconn'; gateways=$(printf '%s' "$gws" | cut -c1-120)"
fi
emit E1 0 "status=ready; gateways=$(printf '%s' "$gws" | cut -c1-120); reconnect_evidence='$rc_ev'"
