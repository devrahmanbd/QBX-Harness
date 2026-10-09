# checks/H4-tls-certs.sh
# memory-query: tls certificate expiry openssl
# timeout: 40
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require openssl H4
now=$(date +%s); worst=99999; detail=""
for p in 7443 5061; do
  enddate=$(echo | run_to 12 openssl s_client -connect "${H4_HOST:-88.99.250.99}:$p" -servername qbx.qubickle.com 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -z "$enddate" ] && emit H4 3 "no cert parsed on port $p"
  days=$(( ( $(date -d "$enddate" +%s) - now ) / 86400 ))
  detail="$detail p$p=${days}d"
  [ "$days" -lt "$worst" ] && worst=$days
done
min=${H4_MIN_DAYS:-14}
[ "$worst" -lt "$min" ] && emit H4 1 "cert days:$detail < min=$min"
# Wave-B extension (wss.pem order + handshake assertion ONLY): the served TLS
# bundle must contain key AND cert markers, and a fresh handshake on 7443 must
# present a parseable leaf (proves the bundle loads, not just that files
# exist). H4_WSS_PEM_FILE injects a canned bundle for fixture tests.
if [ -n "${H4_WSS_PEM_FILE:-}" ]; then
  [ -f "$H4_WSS_PEM_FILE" ] || emit H4 3 "wss.pem fixture missing: $H4_WSS_PEM_FILE"
  pem=$(cat "$H4_WSS_PEM_FILE")
else
  pem=$(docker exec "${FS_CONTAINER:-telecom-freeswitch-1}" cat /etc/freeswitch/tls/wss.pem 2>/dev/null) \
    || emit H4 3 "wss.pem unreadable"
fi
grep -q 'BEGIN PRIVATE KEY' <<<"$pem" || emit H4 1 "wss.pem missing private-key block"
grep -q 'BEGIN CERTIFICATE' <<<"$pem" || emit H4 1 "wss.pem missing certificate block"
leaf=$(echo | run_to 12 openssl s_client -connect "${H4_HOST:-88.99.250.99}:7443" -servername qbx.qubickle.com 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null)
[ -n "$leaf" ] || emit H4 1 "7443 handshake presented no parseable leaf cert"
emit H4 0 "cert days:$detail min=$min; wss.pem key+cert present; handshake leaf: $(printf '%s' "$leaf" | cut -c1-80)"
