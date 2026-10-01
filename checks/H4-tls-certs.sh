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
emit H4 0 "cert days:$detail min=$min"
