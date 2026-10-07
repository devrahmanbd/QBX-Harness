# checks/M3-voicemail.sh
# memory-query: voicemail mailbox 4000 deposit api list delete roundtrip
# timeout: 120
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require jq M3; require curl M3; require python3 M3
. "$HARNESS_ROOT/lib/qbx_api.sh"
ext="${M3_EXT:-4000}"; domain="${M3_DOMAIN:-qbx.qubickle.com}"; did="${M3_DID:-+16804888308}"
base="${M1_BASE_URL:-http://127.0.0.1:3006}"
wav="${M3_WAV:-/usr/share/freeswitch/sounds/en/us/callie/voicemail/vm-instruction.wav}"
hold="${M3_HOLD:-15}"; wait_s="${M3_WAIT:-30}"
# R6 trap: every artifact (call, message, cookie jar) is removed on ALL paths, emit exits included.
# All cleanup output is suppressed — emit's single JSON line stays the only stdout of a run.
# m3_cleanup records its outcome in m3_report; m3_fail runs it inline first so failure evidence
# names leftovers explicitly (spec: mid-run failure scenario).
m3_uuid=""; m3_msg=""; m3_del=""; m3_tok=""; m3_token=""; m3_csrf=""; m3_jar=""; m3_report=""; m3_done=""
m3_csrf_fetch() {  # cookie jar + X-CSRF-Token header for state-changing calls (key names only)
  m3_jar=$(mktemp /tmp/m3-cookie.XXXXXX) || return 1
  m3_csrf=$("${HOST_NS[@]}" curl -s -D - -o /dev/null -c "$m3_jar" "$base/api/v1/csrf" 2>/dev/null \
    | grep -i '^X-Csrf-Token:' | tr -d '\r' | awk '{print $2}')
  [ -n "$m3_csrf" ]
}
m3_locate() {  # resolve our message by the R3 key (extension_number + caller token) when the id is unknown
  local l row
  [ -n "$m3_tok" ] && [ -n "$m3_token" ] || return 1
  l=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $m3_token" "$base/api/v1/voicemails?limit=200" 2>/dev/null)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    m3_msg=$(jq -r '.id // empty' <<<"$row" 2>/dev/null); [ -n "$m3_msg" ] && return 0  # null id never reaches DELETE /:id
  done < <(jq -c --arg e "$ext" --arg c "$m3_tok" \
             '.voicemails[]|select(.extension_number==$e and .caller_number==$c)' <<<"$l" 2>/dev/null)
  return 1
}
m3_delete() {  # R4: DELETE /api/v1/voicemails/:id -> 200 {"status":"deleted"}
  local resp code
  resp=$("${HOST_NS[@]}" curl -s -b "$m3_jar" -H "Authorization: Bearer $m3_token" \
    -H "X-CSRF-Token: $m3_csrf" -w '\n%{http_code}' \
    -X DELETE "$base/api/v1/voicemails/$m3_msg" 2>/dev/null)
  code=$(tail -n1 <<<"$resp")
  if [ "$code" = 200 ] && grep -q '"status":"deleted"' <<<"$resp"; then m3_del=yes; return 0; fi
  m3_del="failed:$code"; return 1
}
m3_cleanup() {  # call first (teardown triggers delivery), then the message — bounded, output-free
  local i loc call msg n
  [ "${m3_done:-}" = yes ] && return 0
  if [ -n "$m3_uuid" ]; then                      # artifact 1: the call
    esl "uuid_kill $m3_uuid" >/dev/null 2>&1
    call=kill-sent
    for i in 1 2 3; do                            # verify the channel is really gone
      n=$(esl "show channels like $m3_uuid" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
      [ "${n:-0}" -eq 0 ] && { call=gone; break; }   # grep -c reads all input: no pipefail 141
      sleep 1
    done
  else call=none; fi
  loc=no                                          # artifact 2: the message
  if [ "$m3_del" = yes ]; then msg=already-deleted
  elif [ -n "$m3_token" ] && [ -n "$m3_csrf" ] && [ -n "$m3_tok" ]; then
    for i in 1 2 3 4 5; do    # delivery lands ~1-2s after teardown: bounded wait, then delete
      if m3_locate; then loc=yes; m3_delete >/dev/null 2>&1 && break; fi
      sleep 2
    done
    if [ "$m3_del" = yes ]; then msg=deleted
    elif [ "$loc" = yes ]; then msg="leftover:$m3_del"   # located but DELETE kept failing
    else msg=not-located; fi                       # never appeared (or list API unreadable)
  else msg=none; fi
  [ -n "$m3_jar" ] && rm -f "$m3_jar"              # artifact 3: cookie jar
  m3_report="call=$call msg=$msg"; m3_done=yes
  return 0
}
m3_fail() {  # spec mid-run failure: cleanup runs inline first, evidence names what (if anything) is left
  m3_cleanup; emit M3 1 "$1; cleanup: ${m3_report:-unavailable}"
}
trap m3_cleanup EXIT

# R2 precondition FIRST: 4000 must be unregistered (S4 holds it ~25s during its run) -> transient 2
reg=$(esl "sofia status profile internal reg" 2>/dev/null)
[ -n "$reg" ] || emit M3 3 "sofia status unreadable (R2 precondition)"
reg_line=$(grep -m1 -E "(^|[[:space:]])${ext}@${domain}([[:space:]]|$)" <<<"$reg")  # field-bounded: must not match 14000@/24000@
[ -n "$reg_line" ] && emit M3 2 "extension $ext registered (transient, retry next run): $(tr '\n' ' ' <<<"$reg_line")"
unset reg reg_line

m3_token=$(qbx_login) || emit M3 3 "api login failed (base=$base)"
m3_csrf_fetch || emit M3 3 "csrf fetch failed (base=$base)"
list0=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $m3_token" "$base/api/v1/voicemails?limit=200")
[ -n "$list0" ] && jq -e . <<<"$list0" >/dev/null 2>&1 || emit M3 3 "list baseline unreadable"
n0=$(jq --arg e "$ext" '[.voicemails[]|select(.extension_number==$e)]|length' <<<"$list0")
[ "${n0:-x}" != x ] || emit M3 3 "baseline count unreadable"
unset list0

# R1: deposit into mailbox $ext via the live DID route (offline branch -> leave-vm-direct ->
# `voicemail(default ...)`) with skip_greeting (the packaged greeting aborts on missing
# digits/ sounds: product defect noted in the task report) and a non-silent product prompt
# feeding the record phase (raw silence < min-record-len is discarded by mod_voicemail).
# R3: unique caller_number per run; display-name token set too, auxiliary only.
m3_tok="1555$(date +%s)${RANDOM}"
m3_uuid=$(cat /proc/sys/kernel/random/uuid)
t0=$(date +%s)
job=$(esl "bgapi originate {origination_uuid=$m3_uuid,origination_caller_id_number=$m3_tok,origination_caller_id_name=$m3_tok,skip_greeting=true,ignore_early_media=true}loopback/$did/default &endless_playback($wav)" 2>&1)
grep -q '+OK' <<<"$job" || m3_fail "originate rejected: $(tr '\n' ' ' <<<"$job")"
up=0
for _ in $(seq 1 10); do
  up=$(esl "show channels like $m3_uuid" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
  [ "${up:-0}" -gt 0 ] && break; sleep 1
done
[ "$up" -gt 0 ] || m3_fail "call leg never appeared: $(tr '\n' ' ' <<<"$job")"
sleep "$hold"                       # greeting-skip + transfer + instruction prompt + record start (~7s)
esl "uuid_kill $m3_uuid" >/dev/null 2>&1   # caller hangup: mod_voicemail saves (>=3s) and delivers

# R3 primary match key: extension_number + unique caller_number + timestamp window
win=$(( t0 - 60 )); id=""; row=""; listn=""
for _ in $(seq 1 "$wait_s"); do
  listn=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $m3_token" "$base/api/v1/voicemails?limit=200")
  mr=0; mt=0; keys=""   # per-poll drift counters: rows matched vs rows without .timestamp
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mr=$((mr+1))
    ts=$(jq -r '.timestamp // empty' <<<"$row")   # // empty: null must not become literal "null"
    if [ -z "$ts" ]; then
      mt=$((mt+1))
      keys=$(jq -r 'keys|join(",")' <<<"$row" 2>/dev/null)
      continue
    fi
    ep=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    if [ "$ep" -ge "$win" ] && [ "$ep" -le "$(( $(date +%s) + 60 ))" ]; then
      id=$(jq -r '.id // empty' <<<"$row")   # accept only non-null ids: null must never be targeted
      [ -n "$id" ] && break
    fi
  done < <(jq -c --arg e "$ext" --arg c "$m3_tok" \
             '.voicemails[]|select(.extension_number==$e and .caller_number==$c)' <<<"$listn" 2>/dev/null)
  [ -n "$id" ] && break
  # all matched rows lacked .timestamp -> API field drift: fail fast (3) with observed keys, don't burn the 30s window
  [ "$mr" -gt 0 ] && [ "$mt" -eq "$mr" ] && emit M3 3 "voicemail rows lack .timestamp (API field drift): keys=${keys:-unknown} matched=$mr"
  sleep 1
done
[ -n "$id" ] || m3_fail "no message for caller=$m3_tok within ${wait_s}s (baseline=$n0 last4000=$(jq --arg e "$ext" '[.voicemails[]|select(.extension_number==$e)]|length' <<<"$listn" 2>/dev/null)) channels=$(esl 'show channels' 2>/dev/null | grep -oE '[0-9]+ total\.')"
m3_msg="$id"

# R4 list/verify: visible in the default list and in the include_deleted diff
present=$(jq --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)]|length' <<<"$listn")
[ "$present" = 1 ] || m3_fail "message $m3_msg missing from default list"
all=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $m3_token" "$base/api/v1/voicemails?limit=200&include_deleted=true")
present=$(jq --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)]|length' <<<"$all")
[ "$present" = 1 ] || m3_fail "message $m3_msg missing from include_deleted list"
dur=$(jq -r --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)][0].duration // empty' <<<"$listn")
bytes=$(jq -r --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)][0].file_size // empty' <<<"$listn")
cname=$(jq -r --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)][0].caller // empty' <<<"$listn")
unset all

# R4 delete (sanctioned cleanup) + post-delete diff
m3_delete || m3_fail "DELETE /api/v1/voicemails/$m3_msg failed: ${m3_del}"
dflt=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $m3_token" "$base/api/v1/voicemails?limit=200")
left_ids=$(jq --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)]|length' <<<"$dflt")
[ "$left_ids" = 0 ] || m3_fail "message $m3_msg still in default list after DELETE"
n1=$(jq --arg e "$ext" '[.voicemails[]|select(.extension_number==$e)]|length' <<<"$dflt")
[ "$n1" = "$n0" ] || m3_fail "residual live $ext messages: baseline=$n0 after=$n1"
all=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $m3_token" "$base/api/v1/voicemails?limit=200&include_deleted=true")
del_ts=$(jq -r --arg i "$m3_msg" '[.voicemails[]|select(.id==$i)][0].deleted_at // empty' <<<"$all")
[ -n "$del_ts" ] || m3_fail "include_deleted diff lost $m3_msg after DELETE"
unset dflt all m3_token

# zero residual channels + mailbox still unregistered (sofia status)
ch=$(esl "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${ch:-1}" = 0 ] || m3_fail "channels not empty after run: total=${ch:-unreadable}"
reg=$(esl "sofia status profile internal reg" 2>/dev/null)
regs=$(grep -m1 -E "(^|[[:space:]])${ext}@${domain}([[:space:]]|$)" <<<"$reg")  # field-bounded: must not match 14000@/24000@
[ -n "$regs" ] && m3_fail "extension $ext registered after run: $regs"
grep -q 'Total items returned: 0' <<<"$reg" || m3_fail "sofia reg status unreadable"
# WAV exclusion: soft DELETE keeps msg_*.wav on FS storage (live-verified before/after run) — named in evidence, not asserted as removed
emit M3 0 "msg=$m3_msg ext=$ext caller=$m3_tok dur=$dur bytes=$bytes callername=${cname:-none} baseline=$n0 del=200 diff=${n0}->${n1} deleted_at=$del_ts wav=retained-by-soft-delete channels=${ch:-unreadable} reg=${regs:-absent}"
