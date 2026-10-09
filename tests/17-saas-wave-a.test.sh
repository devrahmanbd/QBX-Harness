#!/usr/bin/env bash
# tests/17-saas-wave-a.test.sh — Task 3 wave A: S5 S7 V3 C-ctx C-public C-no-listen C-cid C-realm C4.
# TDD: each check fails on a crafted violation (exit 1), passes clean + live (exit 0 + JSON shape).
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
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

# ---- S5: swapped contexts must fail; live must pass ----
printf '                 external\tprofile\tsip:mod_sofia@10.0.0.1:5060\tRUNNING (0)\n                 internal\tprofile\tsip:mod_sofia@10.0.0.1:5080\tRUNNING (0)\n2 profiles 0 aliases\n' > "$TD/s5-status"
printf 'Context          \tdefault\nREGISTRATIONS    \t0\nTotal items returned: 0\n' > "$TD/s5-ext"
printf 'Context          \tdefault\n' > "$TD/s5-int"
S5_STATUS_FILE="$TD/s5-status" S5_PROFILE_EXT_FILE="$TD/s5-ext" S5_PROFILE_INT_FILE="$TD/s5-int" \
  bash "$H/checks/S5-sofia-isolation.sh" >"$TD/s5-red.json" 2>&1
[ $? -eq 1 ] || { echo "S5 shared-context fixture should be 1"; exit 1; }
grep -q 'isolation' "$TD/s5-red.json" || { echo "S5 red not detection-shaped"; exit 1; }
bash "$H/checks/S5-sofia-isolation.sh" >"$TD/s5-live.json" 2>&1 \
  || { echo "S5 live should pass: $(cat "$TD/s5-live.json")"; exit 1; }
shape "$TD/s5-live.json" S5

# ---- S7: relay shaped 200 must fail; live 404 must pass ----
printf 'status=SIP/2.0 100 Trying\nua=QBX-SBC\nstatus=SIP/2.0 200 OK\n' > "$TD/s7-200"
S7_PROBE_FILE="$TD/s7-200" bash "$H/checks/S7-public-egress-ban.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "S7 200-OK fixture should be 1"; exit 1; }
printf 'status=SIP/2.0 100 Trying\nstatus=SIP/2.0 404 Tenant DID Unallocated\n' > "$TD/s7-404"
S7_PROBE_FILE="$TD/s7-404" bash "$H/checks/S7-public-egress-ban.sh" >"$TD/s7-fix.json" 2>&1 \
  || { echo "S7 404 fixture should pass"; exit 1; }
bash "$H/checks/S7-public-egress-ban.sh" >"$TD/s7-live.json" 2>&1 \
  || { echo "S7 live should pass: $(cat "$TD/s7-live.json")"; exit 1; }
shape "$TD/s7-live.json" S7

# ---- V3: weak PIN (bcrypt of 1111) must fail with count; clean must pass; live green ----
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
bash "$H/checks/V3-voicemail-pin-audit.sh" >"$TD/v3-live.json" 2>&1 \
  || { echo "V3 live should pass: $(cat "$TD/v3-live.json")"; exit 1; }
shape "$TD/v3-live.json" V3

# ---- C-ctx: unanchored destination condition must fail; live tree must pass ----
mkdir -p "$TD/ctx"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/ctx/resolver.go"
printf 'package x\nfunc renderEvil() {\n_ = start(enc, "condition", map[string]string{"field": "destination_number", "expression": ".*"} )\n}\n' > "$TD/ctx/evil.go"
C_CTX_SRC="$TD/ctx" bash "$H/checks/C-ctx-exact-match.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-ctx evil fixture should be 1"; exit 1; }
C_CTX_SRC=/root/QBX/backend/services/api-gateway/internal/freeswitchresolver \
  bash "$H/checks/C-ctx-exact-match.sh" >"$TD/cctx-live.json" 2>&1 \
  || { echo "C-ctx live should pass: $(cat "$TD/cctx-live.json")"; exit 1; }
shape "$TD/cctx-live.json" C-ctx

# ---- C-public: gateway bridge in public render must fail; live must pass ----
mkdir -p "$TD/pub"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/pub/resolver.go"
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
bash "$H/checks/C-public-no-egress.sh" >"$TD/cpub-live.json" 2>&1 \
  || { echo "C-public live should pass: $(cat "$TD/cpub-live.json")"; exit 1; }
shape "$TD/cpub-live.json" C-public

# ---- C-no-listen: eavesdrop action must fail; live must pass ----
mkdir -p "$TD/nl"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/nl/resolver.go"
printf 'package x\nvar evil = []dialAction{{"eavesdrop", "all"}}\n' > "$TD/nl/evil.go"
C_NOLISTEN_SRC="$TD/nl" bash "$H/checks/C-no-listen-apps.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-no-listen evil fixture should be 1"; exit 1; }
bash "$H/checks/C-no-listen-apps.sh" >"$TD/cnl-live.json" 2>&1 \
  || { echo "C-no-listen live should pass: $(cat "$TD/cnl-live.json")"; exit 1; }
shape "$TD/cnl-live.json" C-no-listen

# ---- C-cid: synthesized origination CID in render must fail; live must pass ----
mkdir -p "$TD/cid"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/cid/resolver.go"
printf 'package x\nfunc evilCID() {\n_ = dialAction{"set", "origination_caller_id_number=${caller_id_number}"}\n}\n' > "$TD/cid/evil.go"
C_CID_SRC="$TD/cid" bash "$H/checks/C-cid-from-trunk-only.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-cid evil fixture should be 1"; exit 1; }
bash "$H/checks/C-cid-from-trunk-only.sh" >"$TD/ccid-live.json" 2>&1 \
  || { echo "C-cid live should pass: $(cat "$TD/ccid-live.json")"; exit 1; }
shape "$TD/ccid-live.json" C-cid

# ---- C-realm: gate-stripped resolver must fail; live must pass ----
mkdir -p "$TD/realm"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/realm/resolver.go"
python3 - "$TD/realm/resolver.go" <<'EOF'
import sys, re
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r'.*RealmExists.*\n', '', s)
assert s2 != s
open(p, "w").write(s2)
EOF
C_REALM_SRC="$TD/realm" bash "$H/checks/C-realm-allowlist.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C-realm stripped fixture should be 1"; exit 1; }
bash "$H/checks/C-realm-allowlist.sh" >"$TD/crealm-live.json" 2>&1 \
  || { echo "C-realm live should pass: $(cat "$TD/crealm-live.json")"; exit 1; }
shape "$TD/crealm-live.json" C-realm

# ---- C4: extra password emitter + leaked secret must fail; live posture must pass ----
mkdir -p "$TD/c4/scan"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/c4/resolver.go"
printf 'package x\nfunc evilEmit() {\n_ = empty(enc, "param", map[string]string{"name": "password", "value": "hunter2"})\n}\n' > "$TD/c4/evil.go"
printf 'supersecret-fixture-value\n' > "$TD/c4/secrets"
printf 'log line with supersecret-fixture-value inside\n' > "$TD/c4/scan/fs.log"
C4_SRC="$TD/c4" C4_SCAN_DIR="$TD/c4/scan" C4_SECRETS_FILE="$TD/c4/secrets" \
  bash "$H/checks/C4-credential-posture.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C4 evil fixture should be 1"; exit 1; }
bash "$H/checks/C4-credential-posture.sh" >"$TD/c4-live.json" 2>&1 \
  || { echo "C4 live should pass: $(cat "$TD/c4-live.json")"; exit 1; }
shape "$TD/c4-live.json" C4

# ---- S3 internal-only posture (controller ruling): assertion logic pinned by
# fixtures (false->1, true->0). Product flip LANDED 2026-10-09 (~10:00 UTC:
# FS_INTERNAL_AUTH_CALLS=true + container recreate; S4/S3/M1 proof) — S3 is
# GREEN live; the fixture pins below guard the posture either way.
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
