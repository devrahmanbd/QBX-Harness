# checks/V2-ivr.sh
# memory-query: stock mod_voicemail *98 check menu id prompt pin gate own-leg bypass invalid-key re-prompt zero residue
# timeout: 150
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq V2; require python3 V2; require docker V2
ext="${V2_EXT:-4000}"
proxy="${V2_HOST:-88.99.250.99}"; port="${V2_PORT:-5080}"
# Authorized walk (addendum): id + terminator + ONE invalid menu key (3). Menu keys 1/2/5 are
# forbidden by design — 1/2 mark-read via VM_CHECK_PLAY_MESSAGES, 5 INSERTs voicemail_prefs rows.
digits="${V2_ID:-4000#3}"
delay="${V2_DELAY:-5.0}"
# hard scope validation (overrides must never widen the walk or the mailbox-snapshot scope): only
# mailbox 4000, only the authorized walk id4000 + '#' + ONE invalid key 3 (keys 1/2/5 forbidden).
# Rejects before any precondition/call so a bad override is usage/environment (3), never a walk.
[ "$ext" = 4000 ] || emit V2 3 "V2_EXT=$ext rejected: only mailbox 4000 is in scope (snapshot + never-1/2/5 rule)"
case "$digits" in
  4000#3) ;;
  *) emit V2 3 "V2_ID=$digits rejected: authorized walk is exactly 4000#3 (keys 1/2/5 forbidden)" ;;
esac
dur_a=25   # gate segment: prompt -> 4000# -> enter_pass -> invalid3 as password digit -> fail_auth -> retry (disc3-measured)
dur_b=36   # menu segment: full voicemail_menu play1 + play2 re-prompt both complete well inside this window
LOG="${V2_LOG:-/root/QBX/logs/freeswitch/freeswitch.log}"
FS="${V2_FS:-telecom-freeswitch-1}"
HOST_RECORDINGS="${HOST_RECORDINGS:-/root/QBX/storage/recordings}"
sip="$HARNESS_ROOT/checks/lib/sip_caller.py"

v2_uuid_a=""; v2_uuid_b=""; v2_td=""; v2_report=""; v2_done=""; v2_b_race=""
v2_gone() {  # uuid -> 0 once the channel is really gone (bounded wait)
  local u="$1" i n=1
  for i in 1 2 3; do
    n=$(esl "show channels like $u" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
    [ "${n:-0}" -eq 0 ] && return 0
    sleep 1
  done
  return 1
}
v2_cleanup() {  # R6: own probe channels killed + verified gone, scratch removed, output-free — ALL paths,
  local u ok="" # including emit exits; outcome recorded for v2_fail evidence only (success emit runs before trap)
  [ "${v2_done:-}" = yes ] && return 0
  for u in $v2_uuid_a $v2_uuid_b; do
    [ -n "$u" ] || continue
    esl "uuid_kill $u" >/dev/null 2>&1
    if v2_gone "$u"; then ok="$ok $u:gone"; else ok="$ok $u:LEFTOVER"; fi
  done
  [ -n "$v2_td" ] && rm -rf "$v2_td"
  v2_report="channels${ok:- none}"; v2_done=yes
  return 0
}
v2_fail() { v2_cleanup; emit V2 1 "$1; cleanup: ${v2_report:-unavailable}"; }
trap v2_cleanup EXIT

v2_out_ok() {  # sip_caller evidence contract per call: 200 invite, te/101 path, all6 digits, 200 to our BYE
  local f="$1" lbl="$2"
  grep -q '^invite=SIP/2.0 200' "$f" || v2_fail "call $lbl invite failed: $(tr '\n' ' ' <"$f")"
  grep -q '^dtmf=ok pt=101$' "$f" || v2_fail "call $lbl lacks te/101 DTMF path: $(tr '\n' ' ' <"$f")"
  grep -q '^dtmf_sent=6$' "$f" || v2_fail "call $lbl did not send all6 walk digits: $(tr '\n' ' ' <"$f")"
  grep -q '^bye=SIP/2.0 200' "$f" || v2_fail "call $lbl: our BYE got no 200 (hangup race): $(tr '\n' ' ' <"$f")"
}
v2_tok() {  # uuid-scoped FS log -> one token per audited event line, chronological (grep preserves file order)
  grep -aE 'Handle play-file:\[voicemail/vm-(enter_id|enter_pass|fail_auth|listen_new|press|listen_saved|advanced|to_exit)\.wav\]|switch_channel\.c:528 RECV DTMF [0-9*#]:' "$1" | sed -E \
    -e 's@.*vm-enter_id\.wav.*@ID@' \
    -e 's@.*vm-enter_pass\.wav.*@PASS@' \
    -e 's@.*vm-fail_auth\.wav.*@FAIL@' \
    -e 's@.*vm-listen_new\.wav.*@MN@' \
    -e 's@.*vm-listen_saved\.wav.*@MS@' \
    -e 's@.*vm-advanced\.wav.*@MA@' \
    -e 's@.*vm-to_exit\.wav.*@MX@' \
    -e 's@.*vm-press\.wav.*@MP@' \
    -e 's@.*RECV DTMF ([0-9*#]):.*@D\1@'
}
v2_snap() {  # byte-identical mailbox proof: every 4000 row (uuid/read_epoch/flags/in_folder/...) + every prefs row, read-only
  local out="$1" db
  db=$(mktemp "${v2_td:-/tmp}/vmdb.XXXXXX") || return 1
  docker cp "$FS":/var/lib/freeswitch/db/voicemail_default.db "$db" 2>/dev/null || return 1
  python3 - "$db" >"$out" 2>/dev/null <<'PY' || return 1
import json, sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
rows = c.execute("SELECT * FROM voicemail_msgs WHERE username='4000' AND domain='qbx.qubickle.com' ORDER BY uuid").fetchall()
prefs = c.execute("SELECT * FROM voicemail_prefs ORDER BY 1").fetchall()
print(json.dumps({"rows": rows, "prefs": prefs}))
PY
}

# preconditions: zero sibling channels (stale -> STOP NEEDS_CONTEXT), sounds present (truncated/404 ->
# container-recreate suspicion -> NEEDS_CONTEXT), then the mailbox byte baseline.
ch=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${ch:-1}" = 0 ] || emit V2 2 "stale sibling channels before run: total=${ch:-unreadable} (STOP NEEDS_CONTEXT)"
snd=$(docker exec "$FS" sh -c 'wc -c < /usr/share/freeswitch/sounds/en/us/callie/voicemail/vm-enter_id.wav; wc -c < /usr/share/freeswitch/sounds/en/us/callie/voicemail/vm-enter_pass.wav; wc -c < /usr/share/freeswitch/sounds/en/us/callie/voicemail/vm-listen_new.wav' 2>/dev/null)
s_id=$(sed -n 1p <<<"$snd" | tr -d '[:space:]'); s_pass=$(sed -n 2p <<<"$snd" | tr -d '[:space:]'); s_menu=$(sed -n 3p <<<"$snd" | tr -d '[:space:]')
{ [ "${s_id:-0}" -ge 1000 ] 2>/dev/null && [ "${s_pass:-0}" -ge 1000 ] 2>/dev/null && [ "${s_menu:-0}" -ge 1000 ] 2>/dev/null; } \
  || emit V2 3 "voicemail sounds missing/truncated (container-recreate suspicion -> NEEDS_CONTEXT): vm-enter_id=${s_id:-none} vm-enter_pass=${s_pass:-none} vm-listen_new=${s_menu:-none}"
v2_td=$(mktemp -d)
v2_snap "$v2_td/pre.json" || emit V2 3 "mailbox pre-snapshot unreadable (docker cp/sqlite failed)"

ext_secret=$(nsenter -t 1 -n psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" \
  -tAX -c "SELECT secret FROM extensions WHERE extension_number='${ext}'" 2>/dev/null)
[ -n "$ext_secret" ] || emit V2 3 "extension $ext secret lookup empty (psql)"

# ---- call A (no bypass): pre-bypass segment quoted as gate evidence — id prompt, 4000# round-trip,
# vm-enter_pass gate, invalid key3 consumed as password attempt, fail-closed vm-fail_auth, retry prompt.
# A uuid-poll miss (no channel from our INVITE) is a harness/environment flake, never a product
# verdict: one automatic retry, then emit V2 3 — never V2 1 (finding: race verdict option (b)).
a_tries=0
while :; do
  "${HOST_NS[@]}" python3 "$sip" "$proxy" "$port" '*98' "$dur_a" --user "$ext" --pass "$ext_secret" \
    --dtmf "$digits" --dtmf-delay "$delay" >"$v2_td/a.out" 2>&1 &
  call=$!
  v2_uuid_a=""; polls=0
  while [ -z "$v2_uuid_a" ] && [ "$polls" -lt 80 ]; do   # bounded poll: uuid lands ~0.1s after INVITE
    v2_uuid_a=$(esl "show channels" 2>/dev/null | awk -F, '/^[0-9a-f]{8}-[0-9a-f-]{27}/{print $1; exit}')
    [ -n "$v2_uuid_a" ] || sleep 0.05
    polls=$((polls+1))
  done
  [ -n "$v2_uuid_a" ] && break
  kill "$call" 2>/dev/null; wait "$call" 2>/dev/null
  a_tries=$((a_tries+1))
  [ "$a_tries" -ge 2 ] && emit V2 3 "call A uuid-poll failed twice (no channel from *98 leg) — environment (harness), not product"
done
wait "$call"; rc_a=$?
[ "$rc_a" -eq 0 ] || v2_fail "call A caller rc=$rc_a: $(tr '\n' ' ' <"$v2_td/a.out")"
v2_out_ok "$v2_td/a.out" A
grep -a "^$v2_uuid_a " "$LOG" >"$v2_td/a.log" || true
[ -s "$v2_td/a.log" ] || v2_fail "no FS log lines for uuid_a=$v2_uuid_a (log rotated mid-run?)"
a_tok=$(v2_tok "$v2_td/a.log")
a_seq=$(tr '\n' ' ' <<<"$a_tok")
grep -qE 'ID.*D4 D0 D0 D0 D#' <<<"$a_seq" || v2_fail "id prompt or 4000# round-trip absent in call A: $a_seq"
gate=""; gp=none; fa=not-applicable
if grep -qx 'PASS' <<<"$a_tok"; then
  grep -qE 'D#.*PASS' <<<"$a_seq" || v2_fail "vm-enter_pass not played after the 4000# id: $a_seq"
  grep -qE 'PASS.*D3.*FAIL' <<<"$a_seq" || v2_fail "fail-closed gate walk incomplete (want gate, key3, fail_auth): $a_seq"
  gate=observed; gp=vm-enter_pass; fa=observed
elif grep -qx 'MN' <<<"$a_tok"; then
  gate=skipped-auto-auth   # stock menu reached with no gate (auto-auth landed): bypass skipped, note in evidence
else
  v2_fail "neither PIN gate nor stock menu after id entry (call A): $a_seq"
fi
v2_gone "$v2_uuid_a" || v2_fail "call A channel not gone after BYE: $v2_uuid_a"

# ---- call B: the addendum-authorized bypass — in-memory voicemail_authorized on OUR probe uuid only,
# set after the gate was observed live and before the voicemail app reads it at entry (single read
# point, mod_voicemail.c:3761); dies with the channel, no persistent product write, no other leg
# touched. A lost uuid-poll→setvar race (no uuid appearing, setvar rejected, or the PIN gate still
# observed on the bypassed leg) is a harness flake, never a product verdict: v2_leg_b returns 10 so
# the driver retries ONCE and then emits V2 3 (environment) — never V2 1 (finding: option (b)).
v2_leg_b() {
  v2_uuid_b=""; v2_b_race=""
  "${HOST_NS[@]}" python3 "$sip" "$proxy" "$port" '*98' "$dur_b" --user "$ext" --pass "$ext_secret" \
    --dtmf "$digits" --dtmf-delay "$delay" >"$v2_td/b.out" 2>&1 &
  call=$!
  local polls=0
  while [ -z "$v2_uuid_b" ] && [ "$polls" -lt 80 ]; do
    v2_uuid_b=$(esl "show channels" 2>/dev/null | awk -F, '/^[0-9a-f]{8}-[0-9a-f-]{27}/{print $1; exit}')
    [ -n "$v2_uuid_b" ] || sleep 0.05
    polls=$((polls+1))
  done
  if [ -z "$v2_uuid_b" ]; then
    v2_b_race="uuid-poll-empty"; kill "$call" 2>/dev/null; wait "$call" 2>/dev/null; return 10
  fi
  if [ "$gate" = observed ]; then
    sv=$(esl "uuid_setvar $v2_uuid_b voicemail_authorized true" 2>&1)
    if ! grep -q '+OK' <<<"$sv"; then
      v2_b_race="setvar-rejected:$(tr '\n' ' ' <<<"$sv")"
      kill "$call" 2>/dev/null; wait "$call" 2>/dev/null; return 10
    fi
    bypass="uuid_setvar-via-esl uuid=$v2_uuid_b"
  else
    bypass="skipped-auto-auth"
  fi
  wait "$call"; rc_b=$?
  [ "$rc_b" -eq 0 ] || v2_fail "call B caller rc=$rc_b: $(tr '\n' ' ' <"$v2_td/b.out")"
  v2_out_ok "$v2_td/b.out" B
  grep -a "^$v2_uuid_b " "$LOG" >"$v2_td/b.log" || true
  [ -s "$v2_td/b.log" ] || v2_fail "no FS log lines for uuid_b=$v2_uuid_b (log rotated mid-run?)"
  b_tok=$(v2_tok "$v2_td/b.log")
  b_seq=$(tr '\n' ' ' <<<"$b_tok")
  if [ "$gate" = observed ]; then   # bypass timestamp: first uuid-scoped FS-log line = channel
    b_at=$(grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' "$v2_td/b.log" | head -1)  # creation; poll+setvar follow within ~0.1s, before app entry
    bypass="$bypass at${b_at:-no-fs-ts}"
  fi
  grep -qE 'D4 D0 D0 D0 D#' <<<"$b_seq" || v2_fail "id 4000# round-trip absent in call B: $b_seq"
  if grep -qx 'PASS' <<<"$b_tok"; then v2_b_race="gate-observed-on-bypassed-leg"; return 10; fi
  grep -aqF 'Handle play-file:[/' "$v2_td/b.log" \
    && v2_fail "absolute-path message playback observed (auto-play guard violated): $(grep -am2 -F 'Handle play-file:[/' "$v2_td/b.log" | tr '\n' ' ')"
  grep -qE 'D4 D0 D0 D0 D#.*D3.*MN MP MS MP MA MP MX MP' <<<"$b_seq" \
    || v2_fail "menu walk absent — full voicemail_menu after invalid key3 not observed in call B: $b_seq"
  mn_n=$(grep -cx 'MN' <<<"$b_tok")
  [ "${mn_n:-0}" -ge 2 ] || v2_fail "menu re-prompt after invalid key3 absent (vm-listen_new plays=${mn_n:-0}): $b_seq"
  return 0
}
b_tries=0
while :; do
  v2_leg_b && break
  b_tries=$((b_tries+1))
  [ "$b_tries" -ge 2 ] && emit V2 3 "own-leg bypass race lost twice (uuid-poll→setvar→app-entry: ${v2_b_race:-unknown}) — environment (harness), not product"
  # reap the failed attempt fully (caller reaped, own channel killed + verified gone) before retrying
  [ -n "${call:-}" ] && { kill "$call" 2>/dev/null; wait "$call" 2>/dev/null; }
  [ -n "$v2_uuid_b" ] && { esl "uuid_kill $v2_uuid_b" >/dev/null 2>&1; v2_gone "$v2_uuid_b" \
    || emit V2 3 "bypass retry blocked: own channel $v2_uuid_b not gone after uuid_kill"; }
  v2_uuid_b=""
done
unset ext_secret
v2_gone "$v2_uuid_b" || v2_fail "call B channel not gone after BYE: $v2_uuid_b"

# zero residual channels
ch=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${ch:-1}" = 0 ] || v2_fail "channels not empty after run: total=${ch:-unreadable}"
# zero harness-created recording artifacts of our own calls, probed in BOTH real roots
# (host /tmp/recordings does not exist — the old host-only find could never fail):
# container /tmp/recordings (docker exec, maxdepth-scoped, explicit -name predicate) + host
# $HOST_RECORDINGS, roots emitted in evidence. QBX records every answered leg by policy
# (call-control MaybeStartOnAnswer -> uuid_record -> /tmp/recordings/<subID>/<fs_uuid>.wav, AGENTS.md
# "Recording system") — that is product output of our own call, not a harness artifact, so the brief's
# binding "verify zero residuals for YOUR artifacts only" scopes it out: counted as session_rec in
# evidence, while recordings= asserts zero residuals anywhere outside the product layout.
v2_rechits() {  # container|host <root> -> own-uuid files found, maxdepth 4, explicit \( -name … -o -name … \) -print
  if [ "$1" = container ]; then
    docker exec "$FS" sh -c "find $2 -maxdepth 4 \( -name '*${v2_uuid_a}*' -o -name '*${v2_uuid_b}*' \) -print 2>/dev/null"
  else
    find "$2" -maxdepth 4 \( -name "*${v2_uuid_a}*" -o -name "*${v2_uuid_b}*" \) -print 2>/dev/null
  fi
}
sess_rec=0; rec=0; resid=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if grep -qE "/recordings/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(${v2_uuid_a}|${v2_uuid_b})\.wav$" <<<"$p"; then
    sess_rec=$((sess_rec+1))
  else
    rec=$((rec+1)); resid="$resid $p"
  fi
done <<< "$(v2_rechits container /tmp/recordings; v2_rechits host "$HOST_RECORDINGS")"
[ "$rec" -eq 0 ] || v2_fail "residual uuid-keyed recordings:$resid (roots searched: container:$FS:/tmp/recordings host:$HOST_RECORDINGS)"

# mailbox byte-identical assertion (addendum constraint 4: any diff fails the run)
v2_snap "$v2_td/post.json" || emit V2 3 "mailbox post-snapshot unreadable (docker cp/sqlite failed)"
cmp -s "$v2_td/pre.json" "$v2_td/post.json" \
  || v2_fail "mailbox 4000 not byte-identical: $(diff <(jq -S . "$v2_td/pre.json") <(jq -S . "$v2_td/post.json") | head -6 | tr '\n' ' ')"
rows=$(jq -r '.rows|length' "$v2_td/pre.json"); prefs=$(jq -r '.prefs|length' "$v2_td/pre.json")

emit V2 0 "id_prompt=vm-enter_id gate=$gate recv_id_a=4,0,0,0,# gate_prompt=$gp fail_auth=$fa bypass=$bypass recv_b=4,0,0,0,#,3 menu=MN>MP>MS>MP>MA>MP>MX>MP reprompt=vm-listen_new#$mn_n mailbox=identical rows=${rows:-?} prefs=${prefs:-?} channels=0 recordings=$rec roots=container:$FS:/tmp/recordings+host:$HOST_RECORDINGS session_rec=$sess_rec rc_a=$rc_a rc_b=$rc_b uuid_a=$v2_uuid_a uuid_b=$v2_uuid_b"
