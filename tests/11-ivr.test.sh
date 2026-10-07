# tests/11-ivr.test.sh — Task 4 V2: *98 stock check menu — gate proof, own-leg bypass, invalid-key re-prompt, mailbox byte-identical
#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
V2="$H/checks/V2-ivr.sh"

# ---- R6 header contract: filename comment on line 1; memory-query/timeout each own col-0 line
head -n1 "$V2" 2>/dev/null | grep -qx '# checks/V2-ivr.sh' \
  || { echo "V2 line 1 must be the filename comment '# checks/V2-ivr.sh'"; exit 1; }
grep -qE '^# memory-query: .+' "$V2" || { echo "V2 lacks col-0 '# memory-query:' line"; exit 1; }
grep -qE '^# timeout: [0-9]+$' "$V2" || { echo "V2 lacks col-0 '# timeout:' line"; exit 1; }

# ---- static guards scan CODE only: a mention in a comment must neither break nor satisfy them
v2code=$(grep -v '^[[:space:]]*#' "$V2")
# authorized own-leg bypass must exist as code (addendum constraint 1)
grep -q 'uuid_setvar' <<<"$v2code" || { echo "V2 lacks authorized own-leg bypass (uuid_setvar)"; exit 1; }
grep -q 'voicemail_authorized' <<<"$v2code" || { echo "V2 lacks voicemail_authorized setvar target"; exit 1; }
# authorized walk: id 4000 + terminator + invalid menu key 3 only; keys 1/2/5 are forbidden
# (1/2 mark-read via VM_CHECK_PLAY_MESSAGES, 5 INSERTs voicemail_prefs rows)
grep -q '4000#3' <<<"$v2code" || { echo "V2 lacks authorized id+invalid-key walk '4000#3'"; exit 1; }
grep -qE '\-\-dtmf "[^"]*[125]' <<<"$v2code" && { echo "V2 DTMF walk must never send menu keys 1/2/5 (mark-read/play/prefs-insert)"; exit 1; }
# ---- finding 2: hard override validation must exist as CODE (the regex guard above can never match
# the variable `--dtmf "$digits"`, so it must not be relied on)
grep -qF '[ "$ext" = 4000 ]' <<<"$v2code" || { echo "V2 lacks hard-validation ext must equal 4000"; exit 1; }
grep -qF '4000#3) ;;' <<<"$v2code" || { echo "V2 lacks case-guard forcing digits exactly 4000#3"; exit 1; }
# ---- finding 4: a lost uuid-poll/setvar race must be retried once, then verdict 3 — never 1
grep -q 'uuid-poll failed twice' <<<"$v2code" || { echo "V2 lacks uuid-poll race retry -> emit V2 3"; exit 1; }
grep -q 'race lost twice' <<<"$v2code" || { echo "V2 lacks bypass-race retry -> emit V2 3"; exit 1; }
# ---- finding 1: recordings probe must hit both real roots, maxdepth-scoped, explicit predicate,
# with the roots emitted in evidence for auditability
grep -q 'HOST_RECORDINGS' <<<"$v2code" || { echo "V2 lacks host recordings root (\$HOST_RECORDINGS)"; exit 1; }
grep -qF -- '-maxdepth' <<<"$v2code" || { echo "V2 recordings find must be maxdepth-scoped"; exit 1; }
grep -qF '\( -name ' <<<"$v2code" || { echo "V2 recordings find must use explicit \\( -name … -o -name … \\) predicate"; exit 1; }
grep -qF 'roots=container:' <<<"$v2code" || { echo "V2 must emit the recordings roots searched in evidence"; exit 1; }
# trap cleanup + blocked/precondition branches + byte-identical mailbox evidence + single success emit
grep -q 'trap v2_cleanup EXIT' <<<"$v2code" || { echo "V2 lacks trap v2_cleanup EXIT (R6)"; exit 1; }
grep -qE '^[^#]*emit V2 2' <<<"$v2code" || { echo "V2 lacks stale-sibling-channels blocked(2) branch"; exit 1; }
grep -qE '^[^#]*emit V2 3' <<<"$v2code" || { echo "V2 lacks precondition-unreadable(3) branch"; exit 1; }
grep -q 'stale sibling channels' <<<"$v2code" || { echo "V2 lacks stale-channels precondition (NEEDS_CONTEXT stop)"; exit 1; }
grep -q 'mailbox=identical' <<<"$v2code" || { echo "V2 evidence must quote mailbox=identical (byte-identical assertion)"; exit 1; }
n_succ=$(grep -cE '^[^#]*emit V2 0' <<<"$v2code"); [ "$n_succ" -eq 1 ] \
  || { echo "V2 must contain exactly one success emit (got $n_succ)"; exit 1; }

# ---- finding 2 live: scope-widening overrides are rejected before any SIP call (exit 3, one JSON line)
V2_EXT=4001 bash "$V2" >"$TD/bad_ext.json" 2>&1; rcx=$?
[ "$rcx" -eq 3 ] || { echo "V2_EXT=4001 must exit 3 (got $rcx): $(cat "$TD/bad_ext.json")"; exit 1; }
jq -e '.check=="V2" and .exit==3' "$TD/bad_ext.json" >/dev/null \
  || { echo "V2_EXT=4001 output not exit-3 V2 JSON: $(cat "$TD/bad_ext.json")"; exit 1; }
V2_ID='4000#5' bash "$V2" >"$TD/bad_id.json" 2>&1; rcy=$?
[ "$rcy" -eq 3 ] || { echo "V2_ID=4000#5 (forbidden key 5) must exit 3 (got $rcy): $(cat "$TD/bad_id.json")"; exit 1; }
jq -e '.check=="V2" and .exit==3' "$TD/bad_id.json" >/dev/null \
  || { echo "V2_ID=4000#5 output not exit-3 V2 JSON: $(cat "$TD/bad_id.json")"; exit 1; }

# ---- independent mailbox baseline (read-only sqlite snapshot; the check asserts its own too)
snap() {
  local out="$1" db
  db=$(mktemp "$TD/vmdb.XXXXXX") || return 1
  docker cp telecom-freeswitch-1:/var/lib/freeswitch/db/voicemail_default.db "$db" 2>/dev/null || return 1
  python3 - "$db" >"$out" 2>/dev/null <<'PY' || return 1
import json, sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
rows = c.execute("SELECT * FROM voicemail_msgs WHERE username='4000' AND domain='qbx.qubickle.com' ORDER BY uuid").fetchall()
prefs = c.execute("SELECT * FROM voicemail_prefs ORDER BY 1").fetchall()
print(json.dumps({"rows": rows, "prefs": prefs}))
PY
}
snap "$TD/pre.json" || { echo "test mailbox baseline snapshot unreadable"; exit 1; }

# ---- live precondition: zero sibling channels before the run (stale -> STOP NEEDS_CONTEXT)
ch=$(nsenter -t 1 -n python3 /root/esl_api.py "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${ch:-1}" = 0 ] || { echo "stale channels before run (total=${ch:-unreadable}) — STOP NEEDS_CONTEXT"; exit 1; }

# ---- live V2 run: single JSON line, exit 0, evidence quotes the whole walk
bash "$V2" >"$TD/v2.json" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "V2 should pass (rc=$rc): $(cat "$TD/v2.json")"; exit 1; }
[ "$(wc -l <"$TD/v2.json")" -eq 1 ] || { echo "V2 must emit exactly one line: $(cat "$TD/v2.json")"; exit 1; }
jq -e '.check=="V2" and .exit==0' "$TD/v2.json" >/dev/null \
  || { echo "V2 output is not passing V2 JSON: $(cat "$TD/v2.json")"; exit 1; }
ev=$(jq -r .evidence "$TD/v2.json")

# gate evidence: pre-bypass PIN gate quoted (or the addendum's auto-auth deviation note)
gate=$(grep -oE 'gate=[a-z-]+' <<<"$ev" | head -1)
case "$gate" in
  gate=observed)
    grep -q 'gate_prompt=vm-enter_pass' <<<"$ev" || { echo "evidence must quote gate_prompt=vm-enter_pass: $ev"; exit 1; }
    grep -q 'fail_auth=observed' <<<"$ev" || { echo "evidence must quote fail_auth=observed: $ev"; exit 1; }
    grep -q 'bypass=uuid_setvar-via-esl' <<<"$ev" || { echo "evidence must quote bypass=uuid_setvar-via-esl: $ev"; exit 1; }
    grep -qE 'bypass=uuid_setvar-via-esl uuid=[0-9a-f]{8}-[0-9a-f-]{27} at[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.' <<<"$ev" \
      || { echo "evidence must quote bypass timestamp at<FS-log-ts>: $ev"; exit 1; }
    ;;
  gate=skipped-auto-auth)
    grep -q 'bypass=skipped-auto-auth' <<<"$ev" || { echo "evidence must quote bypass=skipped-auto-auth: $ev"; exit 1; }
    ;;
  *) echo "evidence must quote gate=<observed|skipped-auto-auth>: $ev"; exit 1 ;;
esac
grep -q 'recv_id_a=4,0,0,0,#' <<<"$ev" || { echo "evidence must quote call A id round-trip recv_id_a=4,0,0,0,#: $ev"; exit 1; }
grep -q 'recv_b=4,0,0,0,#,3' <<<"$ev" || { echo "evidence must quote call B walk recv_b=4,0,0,0,#,3: $ev"; exit 1; }
grep -q 'menu=MN>MP>MS>MP>MA>MP>MX>MP' <<<"$ev" || { echo "evidence must quote the full voicemail_menu chain: $ev"; exit 1; }
grep -qE 'reprompt=vm-listen_new#[2-9]' <<<"$ev" || { echo "evidence must quote menu re-prompt after invalid key: $ev"; exit 1; }
grep -q 'mailbox=identical' <<<"$ev" || { echo "evidence must quote mailbox=identical: $ev"; exit 1; }
grep -qE 'rows=[0-9]+ prefs=[0-9]+' <<<"$ev" || { echo "evidence must quote rows=<n> prefs=<n>: $ev"; exit 1; }
grep -q 'channels=0' <<<"$ev" || { echo "evidence must quote channels=0: $ev"; exit 1; }
grep -q 'recordings=0' <<<"$ev" || { echo "evidence must quote recordings=0: $ev"; exit 1; }
grep -q 'id_prompt=vm-enter_id' <<<"$ev" || { echo "evidence must quote id_prompt=vm-enter_id: $ev"; exit 1; }
grep -qE 'roots=container:.+/tmp/recordings[+]host:.+/storage/recordings' <<<"$ev" \
  || { echo "evidence must quote both recordings roots searched: $ev"; exit 1; }
grep -qE 'session_rec=[0-9]+' <<<"$ev" || { echo "evidence must quote session_rec=<n>: $ev"; exit 1; }
grep -q 'rc_a=0 rc_b=0' <<<"$ev" || { echo "evidence must quote rc_a=0 rc_b=0: $ev"; exit 1; }
uuid_a=$(grep -oE 'uuid_a=[0-9a-f]{8}-[0-9a-f-]{27}' <<<"$ev" | cut -d= -f2)
uuid_b=$(grep -oE 'uuid_b=[0-9a-f]{8}-[0-9a-f-]{27}' <<<"$ev" | cut -d= -f2)
[ -n "$uuid_a" ] && [ -n "$uuid_b" ] || { echo "evidence must quote uuid_a/uuid_b: $ev"; exit 1; }

# ---- independent byte-identical mailbox assertion (addendum constraint 4: any diff fails the test)
snap "$TD/post.json" || { echo "test mailbox post snapshot unreadable"; exit 1; }
cmp -s "$TD/pre.json" "$TD/post.json" \
  || { echo "mailbox 4000 changed during V2 run:"; diff <(jq -S . "$TD/pre.json") <(jq -S . "$TD/post.json") | head -20; exit 1; }

# ---- zero residual channels
left=$(nsenter -t 1 -n python3 /root/esl_api.py "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${left:-1}" -eq 0 ] || { echo "channels not empty after V2 (total=${left:-none})"; exit 1; }
# ---- zero uuid-keyed recording artifacts, probed in BOTH real roots
# (finding 1: host /tmp/recordings does not exist). QBX's session recording of our own answered legs
# lives at <root>/<subID>/<uuid>.wav — product output of the call (brief: "residuals for YOUR
# artifacts only"), counted as session; anything else matching our uuids is a harness residual.
chits=$(docker exec telecom-freeswitch-1 sh -c 'find /tmp/recordings -maxdepth 4 \( -name "*'"$uuid_a"'*" -o -name "*'"$uuid_b"'*" \) -print 2>/dev/null')
chits="$chits
$(find /root/QBX/storage/recordings -maxdepth 4 \( -name "*${uuid_a}*" -o -name "*${uuid_b}*" \) -print 2>/dev/null)"
resid=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -qE "/recordings/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(${uuid_a}|${uuid_b})\.wav$" <<<"$p" \
    || resid="$resid $p"
done <<<"$chits"
[ -z "$resid" ] || { echo "residual (non-session-layout) recordings for probe uuids:$resid"; exit 1; }
echo ok
