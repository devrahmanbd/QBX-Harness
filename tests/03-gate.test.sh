# tests/03-gate.test.sh
#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
export MEM0_AGENT_ID="qbx-harness-gatetest-$$"
"$H/bin/ingest-memory" --sources "$H/tests/fixtures/ingest-sample.md" >/dev/null \
  || { echo "ingest failed"; exit 1; }
line=$("$H/bin/memory-gate"); rc=$?
[ "$rc" -eq 0 ] || { echo "gate should pass on seeded agent: $line"; exit 1; }
printf '%s' "$line" | jq -e '.check=="MEM-GATE" and .exit==0' >/dev/null \
  || { echo "gate line not valid MEM-GATE JSON"; exit 1; }
# empty agent must miss (eventual-consistency retry happens inside the gate)
export MEM0_AGENT_ID="qbx-harness-empty-$$"
line=$("$H/bin/memory-gate"); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$line" | jq -e '.exit==1' >/dev/null \
  || { echo "empty agent should exit 1"; exit 1; }
# cleanup seeded agent
export MEM0_AGENT_ID="qbx-harness-gatetest-$$"
for id in $("$H/bin/mem0" list | jq -r '.[].id // empty'); do "$H/bin/mem0" delete "$id" >/dev/null; done
echo ok
