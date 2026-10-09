# checks/H3-firewall-surface.sh
# memory-query: firewall nftables rules sip ports
# timeout: 20
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require nft H3
# H3_RULES_FILE injects a canned ruleset for fixture tests; live path reads nft.
if [ -n "${H3_RULES_FILE:-}" ]; then
  [ -f "$H3_RULES_FILE" ] || emit H3 3 "rules fixture missing: $H3_RULES_FILE"
  rules=$(cat "$H3_RULES_FILE")
else
  rules=$("${HOST_NS[@]}" nft list ruleset 2>/dev/null) || emit H3 3 "nft list ruleset failed"
fi
miss=""
grep -qE 'udp dport 5060 .*counter' <<<"$rules" || miss="$miss udp5060"
grep -qE 'tcp dport 5060 .*counter' <<<"$rules" || miss="$miss tcp5060"
grep -qE 'tcp dport 5061 .*counter' <<<"$rules" || miss="$miss tcp5061"
grep -qE 'tcp dport 7443 .*counter' <<<"$rules" || miss="$miss tcp7443"
didx=$(grep -m1 -E 'ip saddr 198\.211\.99\.232 .*udp dport 5060' <<<"$rules")
[ -z "$didx" ] && miss="$miss didx-rule"
# Wave-B extension (carrier-allowlist assertion ONLY): at least one
# carrier-scoped (ip saddr) 5060 accept rule must exist so carrier SIP is
# allowlisted rather than purely world-open. Live: DIDX + peers present.
# Checked before the per-rule misses so the allowlist property has its own
# fail signature (exit 1 either way; verdicts unchanged).
carriers=$(grep -cE 'ip saddr [0-9./]+ .*(udp|tcp) dport 5060' <<<"$rules" || true)
[ "${carriers:-0}" -ge 1 ] || emit H3 1 "carrier allowlist empty (no saddr-scoped 5060 rule)"
[ -n "$miss" ] && emit H3 1 "missing rules:${miss}"
emit H3 0 "rules present; didx=$(printf '%s' "$didx" | grep -oE 'packets [0-9]+' | tr '\n' ' '); carrier-allowlist=$carriers"
