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
if [ "${pkts:-0}" -eq 0 ]; then
  emit I1 2 "blocked: DIDX sent 0 packets (rule counter), ts=$ts — awaiting DIDX portal ring-to test"
fi
emit I1 0 "carrier live: didx_packets=$pkts ts=$ts"
