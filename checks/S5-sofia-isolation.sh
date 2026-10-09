# checks/S5-sofia-isolation.sh
# memory-query: sofia profiles isolation internal external context registrations
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require python3 S5
# S5_STATUS_FILE / S5_PROFILE_EXT_FILE / S5_PROFILE_INT_FILE inject canned ESL
# output for fixture tests; live path queries ESL read-only.
if [ -n "${S5_STATUS_FILE:-}" ]; then
  [ -f "$S5_STATUS_FILE" ] || emit S5 3 "status fixture missing: $S5_STATUS_FILE"
  status=$(cat "$S5_STATUS_FILE")
  ext_prof=$(cat "${S5_PROFILE_EXT_FILE:?fixture needs S5_PROFILE_EXT_FILE}")
  int_prof=$(cat "${S5_PROFILE_INT_FILE:?fixture needs S5_PROFILE_INT_FILE}")
else
  status=$(esl "sofia status" 2>/dev/null) || emit S5 3 "sofia status unreadable"
  ext_prof=$(esl "sofia status profile external" 2>/dev/null) || emit S5 3 "external profile status unreadable"
  int_prof=$(esl "sofia status profile internal" 2>/dev/null) || emit S5 3 "internal profile status unreadable"
fi
ext_row=$(grep -m1 '^[[:space:]]*external[[:space:]]' <<<"$status") || emit S5 1 "external profile absent from sofia status"
int_rows=$(grep '^[[:space:]]*internal[[:space:]]' <<<"$status"); [ -n "$int_rows" ] || emit S5 1 "internal profile absent from sofia status"
ext_port=$(grep -oE ':[0-9]+' <<<"$ext_row" | tail -1 | tr -d ':')
ext_ctx=$(grep -m1 '^Context' <<<"$ext_prof" | awk '{print $NF}'); [ -n "$ext_ctx" ] || emit S5 1 "external context unreadable"
int_ctx=$(grep -m1 '^Context' <<<"$int_prof" | awk '{print $NF}'); [ -n "$int_ctx" ] || emit S5 1 "internal context unreadable"
[ "$ext_ctx" = public ] || emit S5 1 "external context isolation broken: ctx=$ext_ctx (want public)"
[ "$int_ctx" = default ] || emit S5 1 "internal context isolation broken: ctx=$int_ctx (want default)"
[ "$ext_ctx" != "$int_ctx" ] || emit S5 1 "profiles share context $ext_ctx (cross-profile bleed path)"
while IFS= read -r row; do
  p=$(grep -oE ':[0-9]+' <<<"$row" | tail -1 | tr -d ':')
  [ "$p" != "$ext_port" ] || emit S5 1 "port overlap: internal binds external port $ext_port"
done <<<"$int_rows"
ext_reg_out=""
if [ -n "${S5_PROFILE_EXT_FILE:-}" ] && [ -n "${S5_STATUS_FILE:-}" ]; then
  ext_reg_out="$ext_prof"
else
  ext_reg_out=$(esl "sofia status profile external reg" 2>/dev/null) || emit S5 3 "external reg status unreadable"
fi
ext_reg=$(grep -m1 'Total items returned:' <<<"$ext_reg_out" | grep -oE '[0-9]+' | tail -1); ext_reg=${ext_reg:-unknown}
[ "$ext_reg" = 0 ] || emit S5 1 "external profile holds registrations ($ext_reg): carrier side must stay registration-free"
emit S5 0 "isolated: external=:$ext_port/$ext_ctx internal_ctx=$int_ctx ports-disjoint external-reg=0"
