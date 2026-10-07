# tests/10-voicemail.test.sh — Task 3 M3: mailbox-4000 deposit -> API list -> delete -> zero residue
#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness
TD=$(mktemp -d); RUN_DIR=$(mktemp -d)
trap 'rm -rf "$TD" "$RUN_DIR"' EXIT   # covers scratch + RUN_DIR on every path (R-tmp), not just success
M3="$H/checks/M3-voicemail.sh"
B="${M1_BASE_URL:-http://127.0.0.1:3006}"

# ---- R6 header contract: filename comment on line 1; memory-query/timeout each own col-0 line
head -n1 "$M3" 2>/dev/null | grep -qx '# checks/M3-voicemail.sh' \
  || { echo "M3 line 1 must be the filename comment '# checks/M3-voicemail.sh'"; exit 1; }
grep -qE '^# memory-query: .+' "$M3" || { echo "M3 lacks col-0 '# memory-query:' line"; exit 1; }
grep -qE '^# timeout: [0-9]+$' "$M3" || { echo "M3 lacks col-0 '# timeout:' line"; exit 1; }
# ---- R2 branch must exist: registered 4000 -> emit M3 2 (transient, retry next run)
grep -q 'emit M3 2' "$M3" || { echo "M3 lacks registered->blocked(2) branch (R2)"; exit 1; }
# ---- R1/R4/R5 static guards: never touch voicemail_ivr mode; include_deleted diff; no direct DB access
grep -q 'voicemail_ivr' "$M3" && { echo "M3 must not reference voicemail_ivr mode (R1: dead transfer target)"; exit 1; }
grep -q 'include_deleted=true' "$M3" || { echo "M3 lacks include_deleted=true diff (R4)"; exit 1; }
grep -q 'psql' "$M3" && { echo "M3 must not shell out to psql (R5: verification is API-only here)"; exit 1; }

# ---- baseline: how many live (non-deleted) messages mailbox 4000 has before the run
. "$H/lib/common.sh"
. "$H/lib/qbx_api.sh"
base_tok=$(qbx_login) || { echo "test login failed"; exit 1; }
n0=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $base_tok" "$B/api/v1/voicemails?limit=200" \
  | jq '[.voicemails[]|select(.extension_number=="4000")]|length')
[ "${n0:-x}" != x ] || { echo "baseline list unreadable"; exit 1; }

# ---- live M3 run: single JSON line, exit 0, evidence quotes the message id
export RUN_DIR
bash "$M3" >"$TD/m3.json" 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "M3 should pass (rc=$rc): $(cat "$TD/m3.json")"; exit 1; }
[ "$(wc -l <"$TD/m3.json")" -eq 1 ] || { echo "M3 must emit exactly one line: $(cat "$TD/m3.json")"; exit 1; }
jq -e '.check=="M3" and .exit==0' "$TD/m3.json" >/dev/null \
  || { echo "M3 output is not passing M3 JSON: $(cat "$TD/m3.json")"; exit 1; }
ev=$(jq -r .evidence "$TD/m3.json")
msg=$(grep -oE 'msg=[0-9a-f]{8}-[0-9a-f-]{27}' <<<"$ev" | head -1 | cut -d= -f2)
[ -n "$msg" ] || { echo "evidence must quote msg=<uuid>: $ev"; exit 1; }
grep -q 'ext=4000' <<<"$ev" || { echo "evidence must quote ext=4000: $ev"; exit 1; }
grep -qE 'caller=15[0-9]{10,}' <<<"$ev" || { echo "evidence must quote unique caller token: $ev"; exit 1; }
grep -q 'channels=0' <<<"$ev" || { echo "evidence must quote channels=0: $ev"; exit 1; }
grep -q 'reg=absent' <<<"$ev" || { echo "evidence must quote reg=absent: $ev"; exit 1; }

# ---- independent R4 verification: id gone from default list, still visible via include_deleted
dflt=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $base_tok" "$B/api/v1/voicemails?limit=200")
n1=$(jq --arg i "$msg" '[.voicemails[]|select(.id==$i)]|length' <<<"$dflt")
[ "$n1" -eq 0 ] || { echo "deleted message still in default list: $msg"; exit 1; }
cnt=$(jq '[.voicemails[]|select(.extension_number=="4000")]|length' <<<"$dflt")
[ "$cnt" -eq "$n0" ] || { echo "residual live 4000 messages: before=$n0 after=$cnt"; exit 1; }
all=$("${HOST_NS[@]}" curl -s -H "Authorization: Bearer $base_tok" "$B/api/v1/voicemails?limit=200&include_deleted=true")
del_ts=$(jq -r --arg i "$msg" '[.voicemails[]|select(.id==$i)][0].deleted_at // empty' <<<"$all")
[ -n "$del_ts" ] || { echo "include_deleted diff must still show $msg with deleted_at"; exit 1; }

# ---- zero residual channels + mailbox still unregistered (sofia status)
left=$(nsenter -t 1 -n python3 /root/esl_api.py "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | grep -oE '^[0-9]+')
[ "${left:-1}" -eq 0 ] || { echo "channels not empty after M3 (total=${left:-none})"; exit 1; }
reg=$(nsenter -t 1 -n python3 /root/esl_api.py "sofia status profile internal reg" 2>/dev/null)
grep -q '4000@qbx.qubickle.com' <<<"$reg" && { echo "4000 registered after M3"; exit 1; }
grep -q 'Total items returned: 0' <<<"$reg" || { echo "sofia reg status unreadable: $(tr '\n' ' ' <<<"$reg")"; exit 1; }
echo ok
