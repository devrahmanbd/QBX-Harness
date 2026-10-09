# checks/S3-fail-closed.sh
# memory-query: unknown did fail closed unallocated 404
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require python3 S3
out=$("${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/sip_probe.py" "${S3_HOST:-88.99.250.99}" "${S3_PORT:-5060}" INVITE "${S3_DID:-15551230099}" 2>&1) || \
  emit S3 1 "no response from unallocated DID probe: $(tr '\n' ' ' <<<"$out")"
final=$(grep '^status=' <<<"$out" | tail -1)
grep -q '^status=SIP/2.0 404 Tenant DID Unallocated' <<<"$final" \
  || emit S3 1 "not fail-closed: $final"
# Book control (internal-only ruling): registered-extension profile must
# challenge calls. S3_INTERNAL_XML_FILE injects a fixture profile for tests.
if [ -n "${S3_INTERNAL_XML_FILE:-}" ]; then
  auth_xml=$(cat "$S3_INTERNAL_XML_FILE" 2>/dev/null) || emit S3 3 "internal profile fixture unreadable"
else
  auth_xml=$(docker exec "${FS_CONTAINER:-telecom-freeswitch-1}" cat /etc/freeswitch/sip_profiles/internal.xml 2>/dev/null) \
    || emit S3 3 "internal profile config unreadable"
fi
auth_line=$(grep -m1 'auth-calls' <<<"$auth_xml")
grep -q 'auth-calls" value="true"' <<<"$auth_line" \
  || emit S3 1 "internal auth-calls not true: $(tr '\n' ' ' <<<"$auth_line")"
emit S3 0 "fail-closed: $final (did=${S3_DID:-15551230099}); internal $(tr '\n' ' ' <<<"$auth_line"); external auth-calls=false deliberate opt-out (carrier inbound cannot be challenged)"
