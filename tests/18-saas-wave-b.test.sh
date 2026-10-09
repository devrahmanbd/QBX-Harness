#!/usr/bin/env bash
# tests/18-saas-wave-b.test.sh — Task 4 wave B: R1 D1 + E1/C3/H3/H4/M1/I1
# extensions + V2 key-map pin + runbooks + originate review.
# TDD: each new check fails on a crafted violation (exit 1), passes clean +
# live (exit 0 + JSON shape); each extension fails on a crafted violation and
# keeps its live verdict (regression guard). S6 is NEEDS_CONTEXT (spec wrong
# live: external TLS disabled + no sip_secure_media gates) — asserted absent.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
shape() { # shape <file> <id> — emit contract: single JSON line, check id, exit 0
  jq -e --arg c "$2" '.check==$c and .exit==0' "$1" >/dev/null || { echo "bad shape $1: $(cat "$1")"; exit 1; }
}

# ---- S6 deferral (spec amended: V14/external-TLS + SRTP-policy preconditions
# unmet — tracked GAP, not a check this wave). Passes whether S6 is
# absent-deferred or present-red-pending-policy; records which. ----
if [ -n "$(ls "$H/checks/S6"* 2>/dev/null)" ]; then
  bash "$H/checks/S6"*.sh >"$TD/s6.json" 2>&1; src=$?
  [ "$src" -eq 1 ] || { echo "S6 present but not red-with-precondition (rc=$src): $(cat "$TD/s6.json")"; exit 1; }
  echo "S6-note: present-red-pending-policy (V14/external-TLS precondition)"
else
  echo "S6-note: absent-deferred (V14/external-TLS precondition)"
fi

# ---- CATALOG rows + loop file resolution ----
for id in R1 D1; do
  grep -qx "$id" "$H/checks/CATALOG" || { echo "CATALOG missing row $id"; exit 1; }
  f=$(ls "$H/checks/$id"*.sh 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "no check file for $id"; exit 1; }
done

# ---- R1: bad toggle must fail; live (rows=0 + record probe) must pass ----
printf 'sub-1\tauto\nsub-2\tmaybe\n' > "$TD/r1-bad.tsv"
R1_ROWS_FILE="$TD/r1-bad.tsv" bash "$H/checks/R1-recording-toggle.sh" >"$TD/r1-red.json" 2>&1
[ $? -eq 1 ] || { echo "R1 bad-rows fixture should be 1"; exit 1; }
grep -q 'bad=1' "$TD/r1-red.json" || { echo "R1 red must name count"; exit 1; }
bash "$H/checks/R1-recording-toggle.sh" >"$TD/r1-live.json" 2>&1 \
  || { echo "R1 live should pass: $(cat "$TD/r1-live.json")"; exit 1; }
shape "$TD/r1-live.json" R1
grep -q 'uuid_record start_stop=+OK' "$TD/r1-live.json" || { echo "R1 live missing record proof"; exit 1; }

# ---- D1: incomplete row must fail naming call_id; live labeled row must pass ----
printf 'cid-1\tsub-1\t2100\tqbx-test-echo\tcompleted\t200\tNORMAL_CLEARING\t2026-10-09T10:00:05Z\t2026-10-09T10:00:00Z\toutbound\ncid-2\tsub-1\t2100\tqbx-test-echo\tcompleted\t200\tNORMAL_CLEARING\t\t2026-10-09T10:00:00Z\toutbound\n' > "$TD/d1-bad.tsv"
D1_ROWS_FILE="$TD/d1-bad.tsv" bash "$H/checks/D1-cdr-completeness.sh" >"$TD/d1-red.json" 2>&1
[ $? -eq 1 ] || { echo "D1 bad-rows fixture should be 1"; exit 1; }
grep -q 'call_id=cid-2' "$TD/d1-red.json" || { echo "D1 red must name call_id"; exit 1; }
bash "$H/checks/D1-cdr-completeness.sh" >"$TD/d1-live.json" 2>&1 \
  || { echo "D1 live should pass: $(cat "$TD/d1-live.json")"; exit 1; }
shape "$TD/d1-live.json" D1

# ---- E1: unguarded ESL conf must fail; live verdict stays 2 ----
printf '<configuration name="event_socket.conf"><settings><param name="listen-ip" value="0.0.0.0"/><param name="listen-port" value="8021"/><param name="password" value="longenoughfixturepw"/></settings></configuration>\n' > "$TD/e1-noacl.xml"
E1_ESL_CONF_FILE="$TD/e1-noacl.xml" bash "$H/checks/E1-esl-reconnect.sh" >"$TD/e1-red.json" 2>&1
[ $? -eq 1 ] || { echo "E1 no-acl fixture should be 1"; exit 1; }
grep -q 'not ACL-guarded' "$TD/e1-red.json" || { echo "E1 red not assertion-shaped"; exit 1; }
bash "$H/checks/E1-esl-reconnect.sh" >"$TD/e1-live.json" 2>&1; [ $? -eq 2 ] || { echo "E1 live verdict changed: $(cat "$TD/e1-live.json")"; exit 1; }
grep -q 'esl_bind=' "$TD/e1-live.json" || { echo "E1 live missing bind evidence"; exit 1; }

# ---- C3: no-transcode-stripped tree must fail; live stays 0 ----
mkdir -p "$TD/c3"; cp /root/QBX/backend/services/api-gateway/internal/freeswitchresolver/resolver.go "$TD/c3/resolver.go"
python3 - "$TD/c3/resolver.go" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s2 = s.replace("inherit_codec=true", "inherit_codec=false")
assert s2 != s
open(p, "w").write(s2)
EOF
C3_ONLY=c3 C2_SCAN_DIR="$TD" bash "$H/checks/C3-codec-policy.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "C3 stripped fixture should be 1"; exit 1; }
bash "$H/checks/C3-codec-policy.sh" >"$TD/c3-live.json" 2>&1 \
  || { echo "C3 live should pass: $(cat "$TD/c3-live.json")"; exit 1; }
shape "$TD/c3-live.json" C3

# ---- H3: allowlist-stripped ruleset must fail; live stays 0 ----
nsenter -t 1 -n nft list ruleset > "$TD/h3-live.rules" 2>/dev/null || { echo "nft read failed"; exit 1; }
grep -v 'saddr.*dport 5060' "$TD/h3-live.rules" > "$TD/h3-noallow.rules"
H3_RULES_FILE="$TD/h3-noallow.rules" bash "$H/checks/H3-firewall-surface.sh" >"$TD/h3-red.json" 2>&1
[ $? -eq 1 ] || { echo "H3 stripped fixture should be 1"; exit 1; }
grep -q 'carrier allowlist empty' "$TD/h3-red.json" || { echo "H3 red not assertion-shaped"; exit 1; }
bash "$H/checks/H3-firewall-surface.sh" >"$TD/h3-live.json" 2>&1 \
  || { echo "H3 live should pass: $(cat "$TD/h3-live.json")"; exit 1; }
shape "$TD/h3-live.json" H3

# ---- H4: cert-less bundle must fail; live stays 0 ----
printf -- '-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n' > "$TD/h4-nocert.pem"
H4_WSS_PEM_FILE="$TD/h4-nocert.pem" bash "$H/checks/H4-tls-certs.sh" >"$TD/h4-red.json" 2>&1
[ $? -eq 1 ] || { echo "H4 nocert fixture should be 1"; exit 1; }
grep -q 'missing certificate block' "$TD/h4-red.json" || { echo "H4 red not assertion-shaped"; exit 1; }
bash "$H/checks/H4-tls-certs.sh" >"$TD/h4-live.json" 2>&1 \
  || { echo "H4 live should pass: $(cat "$TD/h4-live.json")"; exit 1; }
shape "$TD/h4-live.json" H4

# ---- M1: answer-less artifact must fail; live stays 0 ----
printf '{"result":"pass","validation":{"passed":true},"events":[{"event_type":"CHANNEL_CREATE"},{"event_type":"CHANNEL_HANGUP_COMPLETE"}]}' > "$TD/m1-noanswer.json"
M1_ART_FILE="$TD/m1-noanswer.json" bash "$H/checks/M1-lifecycle.sh" >"$TD/m1-red.json" 2>&1
[ $? -eq 1 ] || { echo "M1 no-answer fixture should be 1"; exit 1; }
grep -q 'answer proof absent' "$TD/m1-red.json" || { echo "M1 red not assertion-shaped"; exit 1; }
bash "$H/checks/M1-lifecycle.sh" >"$TD/m1-live.json" 2>&1 \
  || { echo "M1 live should pass: $(cat "$TD/m1-live.json")"; exit 1; }
shape "$TD/m1-live.json" M1

# ---- I1: DOWN gateway must fail; live verdict stays 2 ----
printf 'Profile::Gateway-Name Data State\n=================================================================================================\ndidx-trunk DOWN DOWN\n=================================================================================================\n1 gateways\n' > "$TD/i1-down.txt"
I1_GW_FILE="$TD/i1-down.txt" bash "$H/checks/I1-carrier-health.sh" >"$TD/i1-red.json" 2>&1
[ $? -eq 1 ] || { echo "I1 down fixture should be 1"; exit 1; }
grep -q 'non-REGED' "$TD/i1-red.json" || { echo "I1 red not assertion-shaped"; exit 1; }
bash "$H/checks/I1-carrier-health.sh" >"$TD/i1-live.json" 2>&1; [ $? -eq 2 ] || { echo "I1 live verdict changed: $(cat "$TD/i1-live.json")"; exit 1; }
grep -q 'gateways=0(opt-out' "$TD/i1-live.json" || { echo "I1 live missing gateway opt-out"; exit 1; }

# ---- V2 key-map pin: comment-only, logic byte-identical ----
grep -q 'KEY-MAP PIN' "$H/checks/V2-ivr.sh" || { echo "V2 key-map pin missing"; exit 1; }
bash -n "$H/checks/V2-ivr.sh" || { echo "V2 syntax broken"; exit 1; }

# ---- runbooks + originate review present ----
for d in runbook-call-debugging runbook-sofia-rescan runbook-cert-rotation runbook-bridge-failover-triage originate-guards-review; do
  [ -s "$H/docs/$d.md" ] || { echo "doc missing: $d"; exit 1; }
done
echo ok
