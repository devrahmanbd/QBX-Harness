# checks/S2-sip-identity.sh
# memory-query: sip user agent identity options external
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require python3 S2
host="${S2_HOST:-88.99.250.99}"
ext=$("${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/sip_probe.py" "$host" "${S2_EXTERNAL_PORT:-5060}" OPTIONS "$host" 2>&1)
ext_rc=$?
int=$("${HOST_NS[@]}" python3 "$HARNESS_ROOT/checks/lib/sip_probe.py" "$host" "${S2_INTERNAL_PORT:-5080}" OPTIONS "$host" 2>&1)
int_rc=$?
[ "$ext_rc" -ne 0 ] && emit S2 1 "external OPTIONS no response: $(tr '\n' ' ' <<<"$ext")"
grep -q 'status=SIP/2.0 200' <<<"$ext" && grep -qi 'QBX-SBC' <<<"$ext" \
  || emit S2 1 "external identity wrong: $(tr '\n' ' ' <<<"$ext")"
[ "$int_rc" -ne 0 ] && emit S2 1 "internal OPTIONS no response: $(tr '\n' ' ' <<<"$int")"
int_ua=$(grep -m1 '^ua=' <<<"$int"); int_srv=$(grep -m1 '^server=' <<<"$int")
if grep -qi 'freeswitch' <<<"$int_ua" || grep -qi 'freeswitch' <<<"$int_srv"; then
  emit S2 1 "internal identity leak: $(tr '\n' ' ' <<<"$int") | external: $(grep 'status=' <<<"$ext" | tr '\n' ' ')"
fi
emit S2 0 "external=$(grep 'status=' <<<"$ext" | tr '\n' ' ') internal=$(grep 'status=' <<<"$int" | tr '\n' ' ')"
