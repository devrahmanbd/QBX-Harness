#!/usr/bin/env bash
# tests/06-config-static.test.sh — hermetic split of 06-config: static/file
# sections only (entrypoint premise, synthetic-tree C2 pins, fixture C2/C3).
# C1 live + C1 red run the full C1 check (docker + ESL reloadxml) and are
# live-only, see docs/harness-ci-contract.md. Tree parameterized via QBX_TREE
# (CI sets it to the QBX checkout); no box paths.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"; F="$H/tests/fixtures/config"
QBX_TREE="${QBX_TREE:-${GITHUB_WORKSPACE:-/root/QBX}}"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
# entrypoint premise on the real tree (repo untouched; runtime copies live in $TD)
grep -cE 'FS_[A-Z_]*_SIP_PORT' "$QBX_TREE/deploy/freeswitch/entrypoint.sh" >/dev/null || { echo "C1 fixture premise gone"; exit 1; }
sed 's/FS_[A-Z_]*_SIP_PORT/REMOVED_PORT/g' "$QBX_TREE/deploy/freeswitch/entrypoint.sh" > "$TD/entrypoint-broken.gen.sh"
! grep -qE 'FS_[A-Z_]*_SIP_PORT' "$TD/entrypoint-broken.gen.sh" || { echo "sed did not strip"; exit 1; }
# synthetic tree: anchors present + recursive code hit → must fail with detection evidence
TREE="$TD/tree"
mkdir -p "$TREE/backend/pkg/telecom" "$TREE/backend/services/api-gateway/internal/freeswitchresolver" "$TREE/backend/services/call-control-service"
printf 'package x\nvar _ = "qbx_sub_id=00000000-0000-0000-0000-000000000000"\n' > "$TREE/backend/pkg/telecom/dialplan.go"
printf 'package x\nvar _ = "qbx_sub_id"\n' > "$TREE/backend/services/api-gateway/internal/freeswitchresolver/resolver.go"
printf 'package x\nvar TenantID = os.Getenv("tenant_id")\n' > "$TREE/backend/services/call-control-service/evil.go"
# fail-closed scope: every telepathy dir must exist — list sourced from the check
# itself (single source of truth; drift fails loudly via the exit-3 pin below)
for t in $(sed -n 's/^telepaths="\(.*\)"$/\1/p' "$H/checks/C2-tenant-key.sh"); do mkdir -p "$TREE/$t"; done
C2_SCAN_DIR="$TREE" bash "$H/checks/C2-tenant-key.sh" >"$TD/c2tree.json" 2>&1; tree_rc=$?
[ "$tree_rc" -eq 1 ] || { echo "C2 synthetic tree should be exit 1, got $tree_rc"; exit 1; }
grep -q 'forbidden tenant key' "$TD/c2tree.json" || { echo "C2 tree miss not detection-shaped"; exit 1; }
# missing scope dir must fail closed (3), not skip silently
rmdir "$TREE/deploy/telecom"
C2_SCAN_DIR="$TREE" bash "$H/checks/C2-tenant-key.sh" >/dev/null 2>&1; [ $? -eq 3 ] \
  || { echo "C2 missing scope dir should be 3"; exit 1; }
# targeted per-file runs:
C2_SCAN_DIR="$F" C2_ONLY=tenantid-comment.go bash "$H/checks/C2-tenant-key.sh" >"$TD/c2c.json" 2>&1 \
  || { echo "comment-only tenant_id must pass: $(cat "$TD/c2c.json")"; exit 1; }
C2_SCAN_DIR="$F" C2_ONLY=tenantid-code.go bash "$H/checks/C2-tenant-key.sh" >/dev/null 2>&1 \
  && { echo "code-line tenant_id must fail"; exit 1; }
C2_SCAN_DIR="$QBX_TREE" bash "$H/checks/C2-tenant-key.sh" >"$TD/c2live.json" 2>&1 \
  || { echo "C2 telephony path should pass: $(cat "$TD/c2live.json")"; exit 1; }
jq -e '.check=="C2" and .exit==0' "$TD/c2live.json" >/dev/null || { echo "C2 live not exit 0"; exit 1; }
C2_SCAN_DIR="$F" C3_ONLY=codec-g729.go bash "$H/checks/C3-codec-policy.sh" >/dev/null 2>&1 \
  && { echo "G729 fixture must fail"; exit 1; }
C2_SCAN_DIR="$F" C3_ONLY=codec-clean.go bash "$H/checks/C3-codec-policy.sh" >/dev/null 2>&1 \
  || { echo "clean fixture must pass"; exit 1; }
C2_SCAN_DIR="$QBX_TREE" bash "$H/checks/C3-codec-policy.sh" >"$TD/c3live.json" 2>&1 \
  || { echo "C3 live should pass: $(cat "$TD/c3live.json")"; exit 1; }
echo ok
