# checks/H3-firewall-surface.sh
# memory-query: firewall nftables rules sip ports
# timeout: 20
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require nft H3
rules=$("${HOST_NS[@]}" nft list ruleset 2>/dev/null) || emit H3 3 "nft list ruleset failed"
miss=""
grep -qE 'udp dport 5060 .*counter' <<<"$rules" || miss="$miss udp5060"
grep -qE 'tcp dport 5060 .*counter' <<<"$rules" || miss="$miss tcp5060"
grep -qE 'tcp dport 5061 .*counter' <<<"$rules" || miss="$miss tcp5061"
grep -qE 'tcp dport 7443 .*counter' <<<"$rules" || miss="$miss tcp7443"
didx=$(grep -E 'ip saddr 198\.211\.99\.232 .*udp dport 5060' <<<"$rules" | head -1)
[ -z "$didx" ] && miss="$miss didx-rule"
[ -n "$miss" ] && emit H3 1 "missing rules:${miss}"
emit H3 0 "rules present; didx=$(printf '%s' "$didx" | grep -oE 'packets [0-9]+' | tr '\n' ' ')"
