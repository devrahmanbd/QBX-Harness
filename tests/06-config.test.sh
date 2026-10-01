#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness; F="$H/tests/fixtures/config"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
bash "$H/checks/C1-config-integrity.sh" >/dev/null 2>&1 && c1_live=0 || c1_live=$?
[ "$c1_live" -eq 0 ] || { echo "C1 live should pass"; exit 1; }
# build broken entrypoint copy from the real one (repo untouched; runtime copy lives in $TD)
grep -cE 'FS_[A-Z_]*_SIP_PORT' /root/QBX/deploy/freeswitch/entrypoint.sh >/dev/null || { echo "C1 fixture premise gone"; exit 1; }
sed 's/FS_[A-Z_]*_SIP_PORT/REMOVED_PORT/g' /root/QBX/deploy/freeswitch/entrypoint.sh > "$TD/entrypoint-broken.gen.sh"
! grep -qE 'FS_[A-Z_]*_SIP_PORT' "$TD/entrypoint-broken.gen.sh" || { echo "sed did not strip"; exit 1; }
C1_ENTRYPOINT="$TD/entrypoint-broken.gen.sh" bash "$H/checks/C1-config-integrity.sh" >"$TD/c1-red.json" 2>&1
[ $? -eq 1 ] || { echo "C1 broken entrypoint should be 1"; exit 1; }
C2_SCAN_DIR="$F" bash "$H/checks/C2-tenant-key.sh" >/dev/null 2>&1 && { echo "C2 fixture dir (code tenant_id) should fail"; exit 1; }
# targeted per-file runs:
C2_SCAN_DIR="$F" C2_ONLY=tenantid-comment.go bash "$H/checks/C2-tenant-key.sh" >"$TD/c2c.json" 2>&1 \
  || { echo "comment-only tenant_id must pass: $(cat "$TD/c2c.json")"; exit 1; }
C2_SCAN_DIR="$F" C2_ONLY=tenantid-code.go bash "$H/checks/C2-tenant-key.sh" >/dev/null 2>&1 \
  && { echo "code-line tenant_id must fail"; exit 1; }
C2_SCAN_DIR=/root/QBX bash "$H/checks/C2-tenant-key.sh" >"$TD/c2live.json" 2>&1; c2live=$?
{ [ "$c2live" -eq 0 ] || [ "$c2live" -eq 1 ]; } || { echo "C2 live crashed ($c2live)"; exit 1; }
jq -e '.check=="C2" and (.evidence|length>0)' "$TD/c2live.json" >/dev/null || { echo "C2 live bad JSON"; exit 1; }
C2_SCAN_DIR="$F" C3_ONLY=codec-g729.go bash "$H/checks/C3-codec-policy.sh" >/dev/null 2>&1 \
  && { echo "G729 fixture must fail"; exit 1; }
C2_SCAN_DIR="$F" C3_ONLY=codec-clean.go bash "$H/checks/C3-codec-policy.sh" >/dev/null 2>&1 \
  || { echo "clean fixture must pass"; exit 1; }
C2_SCAN_DIR=/root/QBX bash "$H/checks/C3-codec-policy.sh" >"$TD/c3live.json" 2>&1 \
  || { echo "C3 live should pass: $(cat "$TD/c3live.json")"; exit 1; }
echo ok
