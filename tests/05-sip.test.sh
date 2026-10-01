#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
# closed-port negatives: silence must never pass
S2_HOST=127.0.0.1 S2_EXTERNAL_PORT=9 S2_INTERNAL_PORT=9 bash "$H/checks/S2-sip-identity.sh" >"$TD/s2-closed.json" 2>&1
[ $? -eq 1 ] || { echo "S2 closed-port should be 1"; exit 1; }
grep -q 'NO-RESPONSE' "$TD/s2-closed.json" || { echo "S2 evidence must show NO-RESPONSE"; exit 1; }
S3_HOST=127.0.0.1 S3_PORT=9 bash "$H/checks/S3-fail-closed.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "S3 closed-port should be 1"; exit 1; }
# S2 green-path isolation: point both ports at the QBX-SBC port
S2_EXTERNAL_PORT=5060 S2_INTERNAL_PORT=5060 bash "$H/checks/S2-sip-identity.sh" >"$TD/s2-green.json" 2>&1
[ $? -eq 0 ] || { echo "S2 both-QBX-SBC should be 0: $(cat "$TD/s2-green.json")"; exit 1; }
# S2 default live: internal port leaks FreeSWITCH UA -> real finding, must be exit 1
bash "$H/checks/S2-sip-identity.sh" >"$TD/s2-live.json" 2>&1; s2=$?
[ "$s2" -eq 1 ] && grep -qi 'freeswitch' "$TD/s2-live.json" \
  || { echo "S2 live should be exit 1 quoting FreeSWITCH UA (got $s2)"; exit 1; }
# S3 live: exact spec response
bash "$H/checks/S3-fail-closed.sh" >"$TD/s3.json" 2>&1
[ $? -eq 0 ] || { echo "S3 live should pass: $(cat "$TD/s3.json")"; exit 1; }
grep -qi '404 Tenant DID Unallocated' "$TD/s3.json" || { echo "S3 evidence lacks reason phrase"; exit 1; }
# S1 + S4 live
bash "$H/checks/S1-sip-listeners.sh" >/dev/null 2>&1 || { echo "S1 should pass"; exit 1; }
bash "$H/checks/S4-registered-ext.sh" >"$TD/s4.json" 2>&1 || { echo "S4 should pass: $(cat "$TD/s4.json")"; exit 1; }
grep -q 'Total items returned: 0\|unregistered' "$TD/s4.json" || { echo "S4 must show cleanup"; exit 1; }
echo ok
