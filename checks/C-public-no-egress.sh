# checks/C-public-no-egress.sh
# memory-query: public context egress carrier gateway bridge open relay
# timeout: 45
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C-public; require awk C-public; require curl C-public
# Carrier egress (sofia/gateway/ bridge) must exist in exactly one renderer —
# outboundActions in the default context. Public-context renders (inbound,
# leave-vm-direct, unallocated 404) must never express it. Served samples are
# fetched read-only from the xml_curl endpoint (machine auth, values never
# emitted); C_PUBLIC_SERVED1/2 inject canned XML for fixture tests.
src="${C_PUBLIC_SRC:-/root/QBX/backend/services/api-gateway/internal/freeswitchresolver}"
[ -d "$src" ] || emit C-public 3 "render source missing: $src"
gofiles=$(ls "$src"/*.go | grep -v '_test\.go$')
gw=$(awk 'FNR==1{fn=""} /^func /{fn=$2; sub(/\(.*/, "", fn)} /sofia\/gateway\// {print fn}' $gofiles | sort -u | tr '\n' ' ')
[ "$gw" = "outboundActions " ] || emit C-public 1 "carrier bridge outside outboundActions: ${gw:-none found}"
served() { # served <destination> <override-var>
  if [ -n "${!2:-}" ]; then cat "${!2}"; return 0; fi
  u=$(grep -h '^FREESWITCH_XML_CURL_USERNAME=' /root/QBX/.env | cut -d= -f2-)
  p=$(grep -h '^FREESWITCH_XML_CURL_PASSWORD=' /root/QBX/.env | cut -d= -f2-)
  [ -n "$u" ] && [ -n "$p" ] || { echo "MACHINE-AUTH-UNAVAILABLE"; return 1; }
  "${HOST_NS[@]}" curl -s -m 10 -u "$u:$p" -X POST http://127.0.0.1:3006/api/v1/fs/dialplan \
    --data-urlencode 'section=dialplan' --data-urlencode 'hostname=check' \
    --data-urlencode 'context=public' --data-urlencode "destination_number=$1"
}
s1=$(served leave-vm-direct C_PUBLIC_SERVED1) || emit C-public 3 "served leave-vm-direct unreadable"
s2=$(served "${C_PUBLIC_UNALLOCATED:-15551230099}" C_PUBLIC_SERVED2) || emit C-public 3 "served unallocated render unreadable"
for s in "$s1" "$s2"; do
  grep -q 'sofia/gateway/' <<<"$s" && emit C-public 1 "carrier bridge in served public render"
  grep -q 'application="bridge"' <<<"$s" && emit C-public 1 "bridge app in served public render"
done
grep -q 'action application="voicemail"\|action application="respond"' <<<"$s1$s2" \
  || emit C-public 3 "served samples not render-shaped"
emit C-public 0 "no egress: gateway bridge singleton in outboundActions; served public renders bridge-free (leave-vm-direct + unallocated-404)"
