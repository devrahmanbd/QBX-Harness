# checks/S7-public-egress-ban.sh
# memory-query: public context egress open relay outbound carrier bridge
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require python3 S7
# Open-relay attempt: international-shaped destination into the public (external)
# profile must fail closed, never bridge to a carrier. S7_PROBE_FILE injects
# canned sip_probe output for fixture tests.
if [ -n "${S7_PROBE_FILE:-}" ]; then
  [ -f "$S7_PROBE_FILE" ] || emit S7 3 "probe fixture missing: $S7_PROBE_FILE"
  out=$(cat "$S7_PROBE_FILE")
else
  out=$("${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/sip_probe.py" "${S7_HOST:-88.99.250.99}" "${S7_PORT:-5060}" INVITE "${S7_DEST:-011441234567890}" 2>&1) || \
    emit S7 1 "no response to relay probe: $(tr '\n' ' ' <<<"$out")"
fi
final=$(grep '^status=' <<<"$out" | tail -1)
grep -q '^status=SIP/2.0 404 Tenant DID Unallocated' <<<"$final" \
  || emit S7 1 "relay not banned (egress path?): $final"
grep -qiE '^status=SIP/2.0 (200|302)' <<<"$out" && emit S7 1 "relay bridged/redirected: $final"
emit S7 0 "egress banned: $final (dest=${S7_DEST:-011441234567890})"
