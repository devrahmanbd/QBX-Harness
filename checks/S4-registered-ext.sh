# checks/S4-registered-ext.sh
# memory-query: extension registration sofia wss
# timeout: 60
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
trap 'rm -f /tmp/s4-client.$$' EXIT   # emit exits bypass the inline rm (R-s4tmp)
require python3 S4; require openssl S4
ext="${S4_EXT:-4000}"; domain="${S4_DOMAIN:-qbx.qubickle.com}"
# error-path hygiene: server-side removal of the binding + absence proof (review finding 2)
s4_cleanup() {
  local flush ver
  flush=$(esl "sofia profile internal flush_inbound_reg ${ext}@${domain}" 2>/dev/null)
  ver=$(esl "sofia status profile internal reg" 2>/dev/null)
  if grep -q "${ext}@${domain}" <<<"$ver"; then
    printf 'flush=[%s] verification=STILL-REGISTERED' "$(tr '\n' ' ' <<<"$flush")"
    return 1
  fi
  printf 'flush=[%s] verification=absent; %s' "$(tr '\n' ' ' <<<"$flush")" \
    "$(grep -m1 'Total items returned:' <<<"$ver" | sed 's/  */ /g')"
  return 0
}
# WSS reachability (spec: registered extension path includes WSS endpoint)
# capture first, then grep the variable: openssl|grep -q under pipefail can 141 (SIGPIPE) (review finding 1)
cert_out=$(echo | run_to 12 openssl s_client -connect "${S4_HOST:-88.99.250.99}:7443" -servername "$domain" 2>/dev/null)
grep -q 'BEGIN CERTIFICATE' <<<"$cert_out" || emit S4 1 "WSS 7443: no certificate presented"
ext_secret=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
  -c "SELECT secret FROM extensions WHERE extension_number='$ext'" 2>/dev/null)
[ -z "$ext_secret" ] && emit S4 3 "extension secret lookup empty for $ext"
"${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/register_client.py" 88.99.250.99 5080 "$ext" "$domain" "$ext_secret" "${S4_HOLD:-25}" >/tmp/s4-client.$$ 2>&1 &
client=$!; unset ext_secret
reg_line=""
for _ in $(seq 1 15); do
  reg_out=$(esl "sofia status profile internal reg" 2>/dev/null)
  reg_line=$(grep -m1 "$ext@$domain" <<<"$reg_out")
  [ -n "$reg_line" ] && break; sleep 1
done
if [ -z "$reg_line" ]; then
  kill "$client" 2>/dev/null; wait "$client" 2>/dev/null
  cln=$(s4_cleanup)
  emit S4 1 "registration never appeared: $(tr '\n' ' ' </tmp/s4-client.$$); cleanup: $cln"
fi
wait "$client"; client_rc=$?
if [ "$client_rc" -ne 0 ]; then
  cln=$(s4_cleanup)
  emit S4 1 "register/unregister failed rc=$client_rc: $(tr '\n' ' ' </tmp/s4-client.$$); cleanup: $cln"
fi
cleaned=""
for _ in $(seq 1 10); do
  reg_out=$(esl "sofia status profile internal reg" 2>/dev/null)
  grep -q 'Total items returned: 0' <<<"$reg_out" && { cleaned=yes; break; }
  sleep 1
done
rm -f /tmp/s4-client.$$
[ "$cleaned" != yes ] && emit S4 1 "stale registration remained after unregister"
emit S4 0 "registered+verified: $reg_line; unregistered clean"
