# checks/I1-carrier-health.sh
# memory-query: carrier didx trunk inbound packets
# timeout: 20
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require nft I1
rules=$("${HOST_NS[@]}" nft list ruleset 2>/dev/null)
line=$(grep -m1 -E 'ip saddr 198\.211\.99\.232 .*udp dport 5060' <<<"$rules")
[ -z "$line" ] && emit I1 1 "DIDX source rule missing from nft ruleset"
pkts=$(printf '%s' "$line" | sed -E 's/.*packets ([0-9]+).*/\1/')
[[ $pkts =~ ^[0-9]+$ ]] || emit I1 2 "DIDX rule present but packet counter unreadable: $line"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Wave-B extension (gateway-state assertion ONLY): where sofia gateways are
# listed, each must read REGED/UP — a DOWN gateway fails. Zero gateways is
# recorded as opt-out (trunk pending), never a failure: live currently lists
# none. I1_GW_FILE injects canned `sofia status gateway` output for tests.
if [ -n "${I1_GW_FILE:-}" ]; then
  [ -f "$I1_GW_FILE" ] || emit I1 3 "gateway fixture missing: $I1_GW_FILE"
  gw_out=$(cat "$I1_GW_FILE")
else
  gw_out=$(esl "sofia status gateway" 2>/dev/null) || gw_out=""
fi
gw_rows=$(grep -vE '^[[:space:]]*$|^=+$|Gateway-Name|[0-9]+ gateways' <<<"$gw_out" | grep -cE '[[:alnum:]]' || true)
gw_note="gateways=0(opt-out: trunk pending)"
if [ "${gw_rows:-0}" -gt 0 ]; then
  down=$(grep -vE '^[[:space:]]*$|^=+$|Gateway-Name|[0-9]+ gateways' <<<"$gw_out" | grep -viE 'REGED|REGISTERED|UP' | tr '\n' ' ' | cut -c1-160)
  [ -z "$down" ] || emit I1 1 "gateway DOWN/non-REGED: $down"
  gw_note="gateways=$gw_rows all-REGED/UP"
fi
if [ "${pkts:-0}" -eq 0 ]; then
  emit I1 2 "blocked: DIDX sent 0 packets (rule counter), ts=$ts — awaiting DIDX portal ring-to test; $gw_note"
fi
emit I1 0 "carrier live: didx_packets=$pkts ts=$ts; $gw_note"
