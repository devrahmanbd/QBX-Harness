# checks/L1-fs-logs.sh
# memory-query: freeswitch log errors crash
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep L1
require stat L1
require tail L1
LOG="${L1_LOG:-/root/QBX/logs/freeswitch/freeswitch.log}"
OFF_FILE="${L1_OFFSET_FILE:-$HARNESS_ROOT/state/l1.offset}"
[ -f "$LOG" ] || emit L1 3 "log missing: $LOG"
size=$(stat -c%s "$LOG"); off=0
[ -f "$OFF_FILE" ] && off=$(cat "$OFF_FILE" 2>/dev/null || echo 0)
note=""
if [ "$size" -lt "$off" ]; then off=0; note="log rotated/reset; "; fi
bytes=$((size - off)); [ "$bytes" -le 0 ] && bytes=0
new=$(tail -c +"$((off + 1))" "$LOG" 2>/dev/null)
errs=$(printf '%s' "$new" | grep -E '\[(ERR|ERROR|CRIT|ALERT|EMERG)\]' | grep -vc 'CRASH' || true)   # severity classes; the [CRIT] CRASH line is crash=, never double-counted
crash=$(printf '%s' "$new" | grep -c 'CRASH' || true)
printf '%s' "$size" > "$OFF_FILE" || emit L1 3 "cannot write offset file: $OFF_FILE"
if [ "$((errs + crash))" -gt 0 ]; then
  sample=$(printf '%s' "$new" | grep -E '\[(ERR|ERROR|CRIT|ALERT|EMERG)\]|CRASH' | tail -5 | cut -c1-200 | tr '\n' '|' )
  emit L1 1 "${note}new_errors=$errs new_crash=$crash scanned=$bytes sample=$sample"
fi
emit L1 0 "${note}new_errors=0 new_crash=0 scanned=$bytes"
