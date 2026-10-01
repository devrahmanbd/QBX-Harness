# checks/S3-fail-closed.sh
# memory-query: unknown did fail closed unallocated 404
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require python3 S3
out=$("${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/sip_probe.py" "${S3_HOST:-88.99.250.99}" "${S3_PORT:-5060}" INVITE "${S3_DID:-15551230099}" 2>&1) || \
  emit S3 1 "no response from unallocated DID probe: $(tr '\n' ' ' <<<"$out")"
final=$(grep '^status=' <<<"$out" | tail -1)
grep -q '^status=SIP/2.0 404' <<<"$out" && grep -qi 'Tenant DID Unallocated' <<<"$out" \
  || emit S3 1 "not fail-closed: $final $(grep '^reason=' <<<"$out" | tr '\n' ' ')"
emit S3 0 "fail-closed: $final reason=Tenant DID Unallocated (did=${S3_DID:-15551230099})"
