#!/usr/bin/env bash
# tests/17-saas-wave-a-mutations.test.sh — hermetic split of 17-saas-wave-a
# (Task 3 wave A): CATALOG pins + mutation/clean fixture sections only (S5 S7
# V3 C-ctx C-public C-no-listen C-cid C-realm C4 red/clean + S3 posture
# fixtures). All live-green sections are live-only, see
# docs/harness-ci-contract.md. Tree reads parameterized via QBX_TREE (CI sets
# it to the QBX checkout); no box paths. V3 needs python3 + bcrypt.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
QBX_TREE="${QBX_TREE:-${GITHUB_WORKSPACE:-/root/QBX}}"
RESOLVER="$QBX_TREE/backend/services/api-gateway/internal/freeswitchresolver/resolver.go"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
shape() { # shape <file> <id> — emit contract: single JSON line, check id, exit 0
  jq -e --arg c "$2" '.check==$c and .exit==0' "$1" >/dev/null || { echo "bad shape $1: $(cat "$1")"; exit 1; }
}

# ---- CATALOG rows + loop file resolution ----
for id in S5 S7 V3 C-ctx C-public C-no-listen C-cid C-realm C4; do
  grep -qx "$id" "$H/checks/CATALOG" || { echo "CATALOG missing row $id"; exit 1; }
  f=$(ls "$H/checks/$id"*.sh 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "no check file for $id"; exit 1; }
done

# ---- S5: swapped contexts must fail ----
printf '                 external\tprofile\tsip:mod_sofia@10.0.0.1:5060\tRUNNING (0)\n                 internal\tprofile\tsip:mod_sofia@10.0.0.1:5080\tRUNNING (0)\n2 profiles 0 aliases\n' > "$TD/s5-status"
printf 'Context          \tdefault\nREGISTRATIONS    \t0\nTotal items returned: 0\n' > "$TD/s5-ext"
printf 'Context          \tdefault\n' > "$TD/s5-int"
S5_STATUS_FILE="$TD/s5-status" S5_PROFILE_EXT_FILE="$TD/s5-ext" S5_PROFILE_INT_FILE="$TD/s5-int" \
  bash "$H/checks/S5-sofia-isolation.sh" >"$TD/s5-red.json" 2>&1
[ $? -eq 1 ] || { echo "S5 shared-context fixture should be 1"; exit 1; }
grep -q 'isolation' "$TD/s5-red.json" || { echo "S5 red not detection-shaped"; exit 1; }

# ---- S7: relay shaped 200 must fail; shaped 404 must pass ----
printf 'status=SIP/2.0 100 Trying\nua=QBX-SBC\nstatus=SIP/2.0 200 OK\n' > "$TD/s7-200"
S7_PROBE_FILE="$TD/s7-200" bash "$H/checks/S7-public-egress-ban.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "S7 200-OK fixture should be 1"; exit 1; }
printf 'status=SIP/2.0 100 Trying\nstatus=SIP/2.0 404 Tenant DID Unallocated\n' > "$TD/s7-404"
S7_PROBE_FILE="$TD/s7-404" bash "$H/checks/S7-public-egress-ban.sh" >"$TD/s7-fix.json" 2>&1 \
  || { echo "S7 404 fixture should pass"; exit 1; }

# ---- V3: weak PIN (bcrypt of 1111) must fail with count; clean must pass ----
python3 - "$TD/v3-weak.tsv" <<'EOF'
import bcrypt, sys
h = bcrypt.hashpw(b"1111", bcrypt.gensalt()).decode()
open(sys.argv[1], "w").write("4000\t%s\n4001\t\n" % h)
EOF
V3_FIXTURE_TSV="$TD/v3-weak.tsv" bash "$H/checks/V3-voicemail-pin-audit.sh" >"$TD/v3-red.json" 2>&1
[ $? -eq 1 ] || { echo "V3 weak-pin fixture should be 1"; exit 1; }
grep -q 'weak=1' "$TD/v3-red.json" || { echo "V3 red must name count: $(cat "$TD/v3-red.json")"; exit 1; }
grep -q '1111' "$TD/v3-red.json" && { echo "V3 red leaked PIN value"; exit 1; }
python3 - "$TD/v3-clean.tsv" <<'EOF'
import bcrypt, sys
h = bcrypt.hashpw(b"847392", bcrypt.gensalt()).decode()
open(sys.argv[1], "w").write("4000\t%s\n" % h)
EOF
V3_FIXTURE_TSV="$TD/v3-clean.tsv" bash "$H/checks/V3-voicemail-pin-audit.sh" >/dev/null 2>&1 \
  || { echo "V3 clean fixture should pass"; exit 1; }

# ---- C-ctx: unanchored destination condition must fail ----
mkdir -p "$TD/ctx"; cp "$RESOLVER" "$TD/ctx/resolver.go"
printf 'package x\nfunc renderEvil() {\n_ = start(enc, "condition", map[string]string{"field": "destination_number", "expression": ".*"} )\n}\n' > "$TD/ctx/evil.go"
C_CTX_SRC="$TD/ctx" bash "$H/checks/C-ctx-exact-match.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-ctx evil fixture should be 1"; exit 1; }

# ---- C-public: gateway bridge in public render must fail ----
mkdir -p "$TD/pub"; cp "$RESOLVER" "$TD/pub/resolver.go"
python3 - "$TD/pub/resolver.go" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('{"transfer", "leave-vm-direct XML public"},',
              '{"transfer", "leave-vm-direct XML public"},\n\t\t{"bridge", "sofia/gateway/evil/123"},', 1)
open(p, "w").write(s)
EOF
grep -q 'sofia/gateway/evil' "$TD/pub/resolver.go" || { echo "evil-bridge seed failed"; exit 1; }
C_PUBLIC_SRC="$TD/pub" bash "$H/checks/C-public-no-egress.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-public evil fixture should be 1"; exit 1; }

# ---- C-no-listen: eavesdrop action must fail ----
mkdir -p "$TD/nl"; cp "$RESOLVER" "$TD/nl/resolver.go"
printf 'package x\nvar evil = []dialAction{{"eavesdrop", "all"}}\n' > "$TD/nl/evil.go"
C_NOLISTEN_SRC="$TD/nl" bash "$H/checks/C-no-listen-apps.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-no-listen evil fixture should be 1"; exit 1; }

# ---- C-cid: synthesized origination CID in render must fail ----
mkdir -p "$TD/cid"; cp "$RESOLVER" "$TD/cid/resolver.go"
printf 'package x\nfunc evilCID() {\n_ = dialAction{"set", "origination_caller_id_number=${caller_id_number}"}\n}\n' > "$TD/cid/evil.go"
C_CID_SRC="$TD/cid" bash "$H/checks/C-cid-from-trunk-only.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-cid evil fixture should be 1"; exit 1; }

# ---- C-realm: gate-stripped resolver must fail ----
mkdir -p "$TD/realm"; cp "$RESOLVER" "$TD/realm/resolver.go"
python3 - "$TD/realm/resolver.go" <<'EOF'
import sys, re
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r'.*RealmExists.*\n', '', s)
assert s2 != s
open(p, "w").write(s2)
EOF
C_REALM_SRC="$TD/realm" bash "$H/checks/C-realm-allowlist.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-realm stripped fixture should be 1"; exit 1; }

# ---- C4: extra password emitter + leaked secret must fail ----
mkdir -p "$TD/c4/scan"; cp "$RESOLVER" "$TD/c4/resolver.go"
printf 'package x\nfunc evilEmit() {\n_ = empty(enc, "param", map[string]string{"name": "password", "value": "hunter2"})\n}\n' > "$TD/c4/evil.go"
printf 'supersecret-fixture-value\n' > "$TD/c4/secrets"
printf 'log line with supersecret-fixture-value inside\n' > "$TD/c4/scan/fs.log"
C4_SRC="$TD/c4" C4_SCAN_DIR="$TD/c4/scan" C4_SECRETS_FILE="$TD/c4/secrets" \
  bash "$H/checks/C4-credential-posture.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C4 evil fixture should be 1"; exit 1; }

# ---- S3 internal-only posture fixtures (false->1, true->0) ----
printf '<profile name="internal"><settings><param name="auth-calls" value="false"/></settings></profile>\n' >"$TD/s3-false.xml"
S3_INTERNAL_XML_FILE="$TD/s3-false.xml" bash "$H/checks/S3-fail-closed.sh" >"$TD/s3-f.json" 2>&1
[ $? -eq 1 ] || { echo "S3 internal=false fixture should be 1"; exit 1; }
grep -q 'internal auth-calls not true' "$TD/s3-f.json" || { echo "S3 red not assertion-shaped"; exit 1; }
printf '<profile name="internal"><settings><param name="auth-calls" value="true"/></settings></profile>\n' >"$TD/s3-true.xml"
S3_INTERNAL_XML_FILE="$TD/s3-true.xml" bash "$H/checks/S3-fail-closed.sh" >"$TD/s3-t.json" 2>&1 \
  || { echo "S3 internal=true fixture should pass: $(cat "$TD/s3-t.json")"; exit 1; }
shape "$TD/s3-t.json" S3
grep -q 'external auth-calls=false deliberate opt-out' "$TD/s3-t.json" || { echo "S3 opt-out evidence missing"; exit 1; }
echo ok
