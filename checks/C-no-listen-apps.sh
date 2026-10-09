# checks/C-no-listen-apps.sh
# memory-query: listen apps eavesdrop intercept spy dialplan privacy
# timeout: 45
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C-no-listen; require curl C-no-listen
# No listen-family application (eavesdrop/intercept/three_way/valet_park/spy)
# may appear in served dialplan code or served renders. Either is a finding.
src="${C_NOLISTEN_SRC:-/root/QBX/backend/services/api-gateway/internal/freeswitchresolver}"
[ -d "$src" ] || emit C-no-listen 3 "render source missing: $src"
toks='eavesdrop|intercept|three_way|valet_park|[^a-z_]spy[^a-z_]'
hits=$(grep -rniE "$toks" "$src" --include='*.go' 2>/dev/null | grep -v _test | grep -vE ':[[:space:]]*//' || true)
[ -z "$hits" ] || emit C-no-listen 1 "listen app in render code: $(printf '%s' "$hits" | head -2 | tr '\n' ' ')"
served() {
  if [ -n "${!2:-}" ]; then cat "${!2}"; return 0; fi
  u=$(grep -h '^FREESWITCH_XML_CURL_USERNAME=' /root/QBX/.env | cut -d= -f2-)
  p=$(grep -h '^FREESWITCH_XML_CURL_PASSWORD=' /root/QBX/.env | cut -d= -f2-)
  [ -n "$u" ] && [ -n "$p" ] || { echo "MACHINE-AUTH-UNAVAILABLE"; return 1; }
  "${HOST_NS[@]}" curl -s -m 10 -u "$u:$p" -X POST http://127.0.0.1:3006/api/v1/fs/dialplan \
    --data-urlencode 'section=dialplan' --data-urlencode 'hostname=check' \
    --data-urlencode 'context=public' --data-urlencode "destination_number=$1"
}
s1=$(served leave-vm-direct C_NOLISTEN_SERVED1) || emit C-no-listen 3 "served leave-vm-direct unreadable"
s2=$(served "${C_NOLISTEN_UNALLOCATED:-15551230099}" C_NOLISTEN_SERVED2) || emit C-no-listen 3 "served unallocated render unreadable"
shits=$(grep -niE "$toks" <<<"$s1$s2" || true)
[ -z "$shits" ] || emit C-no-listen 1 "listen app in served render: $(printf '%s' "$shits" | head -2 | tr '\n' ' ')"
emit C-no-listen 0 "no listen apps: 0 code hits, 0 served-render hits (leave-vm-direct + unallocated-404)"
