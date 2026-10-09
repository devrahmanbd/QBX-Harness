#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
AG="qbx-harness-test-$$"
export MEM0_AGENT_ID=$AG
trap 'for i in $("$H/bin/mem0" list | jq -r ".[].id // empty"); do "$H/bin/mem0" delete "$i" >/dev/null; done' EXIT
MARK="mem0-marker-$$-ping is the test marker used by the qbx harness QA run"
out=$("$H/bin/mem0" add --wait "$MARK" 2>&1) && \
  hit=$("$H/bin/mem0" search "$MARK" | grep -c "$MARK") || { echo "add failed: $out"; exit 1; }
[ "${hit:-0}" -ge 1 ] || { echo "search miss for marker"; exit 1; }
for id in $("$H/bin/mem0" list | jq -r '.[].id // empty'); do "$H/bin/mem0" delete "$id" >/dev/null; done
sleep 2
left=$("$H/bin/mem0" list | jq -e 'if type=="array" then length else -1 end')
[ "$left" = "0" ] || { echo "list not empty after delete: $left"; exit 1; }
# non-2xx must be exit 4, and the key must never leak into output
bad=$(MEM0_API_KEY=m0-invalid-key-for-test "$H/bin/mem0" search anything 2>&1); rc=$?
[ "$rc" -eq 4 ] || { echo "want exit 4 got $rc"; exit 1; }
case "$bad" in *m0-invalid-key-for-test*) echo "key leaked"; exit 1;; esac
echo ok
