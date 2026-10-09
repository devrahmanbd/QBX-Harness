# checks/C-cid-from-trunk-only.sh
# memory-query: caller id trunk origination effective_caller_id spoofing
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C-cid; require awk C-cid
# Served renders must never synthesize caller ID from caller-controlled input:
# no origination_caller_id_number in render code; effective_caller_id_number is
# set only from the trunk record (outboundActions) and the directory extension
# record (writeDirectoryUser); the gateway bridge carries no caller_id variable.
src="${C_CID_SRC:-/root/QBX/backend/services/api-gateway/internal/freeswitchresolver}"
[ -d "$src" ] || emit C-cid 3 "render source missing: $src"
gofiles=$(ls "$src"/*.go | grep -v '_test\.go$')
synth=$(grep -rn 'origination_caller_id_number' $gofiles 2>/dev/null | grep -vE ':[[:space:]]*//' || true)
[ -z "$synth" ] || emit C-cid 1 "synthesized origination CID in render code: $(printf '%s' "$synth" | head -2 | tr '\n' ' ')"
sites=$(awk 'FNR==1{fn=""} /^func /{fn=$2; sub(/\(.*/, "", fn)} /effective_caller_id_number=/ {print fn}' $gofiles | sort -u | tr '\n' ' ')
[ "$sites" = "outboundActions " ] || emit C-cid 1 "CID set outside trunk record: ${sites:-none found}"
grep -q '"effective_caller_id_number".*record\.Extension' $gofiles \
  || emit C-cid 1 "directory extension-CID record missing in writeDirectoryUser"
gwb=$(grep -rn 'sofia/gateway/' $gofiles 2>/dev/null | grep caller_id || true)
[ -z "$gwb" ] || emit C-cid 1 "caller-controlled CID in gateway bridge: $(tr '\n' ' ' <<<"$gwb")"
emit C-cid 0 "CID from trunk only: 0 synthesized origination sites; effective_caller_id_number in {outboundActions, writeDirectoryUser}; gateway bridge CID-free"
