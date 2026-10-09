#!/usr/bin/env bash
# tests/18-saas-wave-b-mutations.test.sh — hermetic split of wave B (Task 4):
# CATALOG pins + mutation fixture sections only (R1/D1 bad-rows red, C3
# no-transcode red). No live SIP/ESL/network/box deps: R1/D1 fixture mode needs
# only jq+curl, C3 only grep. Tree reads parameterized via QBX_TREE.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
QBX_TREE="${QBX_TREE:-${GITHUB_WORKSPACE:-/root/QBX}}"
RESOLVER="$QBX_TREE/backend/services/api-gateway/internal/freeswitchresolver/resolver.go"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT

# ---- CATALOG rows + loop file resolution ----
for id in R1 D1; do
  grep -qx "$id" "$H/checks/CATALOG" || { echo "CATALOG missing row $id"; exit 1; }
  f=$(ls "$H/checks/$id"*.sh 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "no check file for $id"; exit 1; }
done

# ---- R1: invalid toggle value must fail (no live probe on this path) ----
printf 'sub-1\tauto\nsub-2\tmaybe\n' > "$TD/r1-bad.tsv"
R1_ROWS_FILE="$TD/r1-bad.tsv" bash "$H/checks/R1-recording-toggle.sh" >"$TD/r1-red.json" 2>&1
[ $? -eq 1 ] || { echo "R1 bad-rows fixture should be 1"; exit 1; }
grep -q 'bad=1' "$TD/r1-red.json" || { echo "R1 red must name count: $(cat "$TD/r1-red.json")"; exit 1; }
R1_ROWS_FILE="$TD/r1-nope.tsv" bash "$H/checks/R1-recording-toggle.sh" >/dev/null 2>&1
[ $? -eq 3 ] || { echo "R1 missing fixture should be 3"; exit 1; }

# ---- D1: incomplete CDR row must fail naming the call_id ----
printf 'cid-1\tsub-1\t2100\tqbx-test-echo\tcompleted\t200\tNORMAL_CLEARING\t2026-10-09T10:00:05Z\t2026-10-09T10:00:00Z\toutbound\ncid-2\tsub-1\t2100\tqbx-test-echo\tcompleted\t200\tNORMAL_CLEARING\t\t2026-10-09T10:00:00Z\toutbound\n' > "$TD/d1-bad.tsv"
D1_ROWS_FILE="$TD/d1-bad.tsv" bash "$H/checks/D1-cdr-completeness.sh" >"$TD/d1-red.json" 2>&1
[ $? -eq 1 ] || { echo "D1 bad-rows fixture should be 1"; exit 1; }
grep -q 'call_id=cid-2' "$TD/d1-red.json" || { echo "D1 red must name call_id: $(cat "$TD/d1-red.json")"; exit 1; }
printf 'cid-1\tsub-1\t2100\tqbx-test-echo\tcompleted\t200\tNORMAL_CLEARING\t2026-10-09T10:00:05Z\t2026-10-09T10:00:00Z\toutbound\n' > "$TD/d1-good.tsv"
D1_ROWS_FILE="$TD/d1-good.tsv" bash "$H/checks/D1-cdr-completeness.sh" >"$TD/d1-fix.json" 2>&1 \
  || { echo "D1 good fixture should pass: $(cat "$TD/d1-fix.json")"; exit 1; }
jq -e '.check=="D1" and .exit==0' "$TD/d1-fix.json" >/dev/null || { echo "D1 fix bad shape"; exit 1; }

# ---- C3: inherit_codec-stripped tree must fail the no-transcode assertion ----
mkdir -p "$TD/c3"; cp "$RESOLVER" "$TD/c3/resolver.go"
python3 - "$TD/c3/resolver.go" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s2 = s.replace("inherit_codec=true", "inherit_codec=false")
assert s2 != s
open(p, "w").write(s2)
EOF
C3_ONLY=c3 C2_SCAN_DIR="$TD" bash "$H/checks/C3-codec-policy.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C3 no-transcode-stripped fixture should be 1"; exit 1; }
echo ok
