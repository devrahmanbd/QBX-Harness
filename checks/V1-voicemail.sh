# checks/V1-voicemail.sh
# memory-query: voicemail recordings storage writable
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require systemctl V1
systemctl is-active --quiet qbx-voicemail.service || emit V1 1 "qbx-voicemail.service not active: $(systemctl is-active qbx-voicemail.service 2>&1)"
dir="${RECORDINGS_DIR:-/root/QBX/storage/recordings}"
if t=$(mktemp "$dir/.harness-v1.XXXXXX" 2>/dev/null) && echo harness-write-test >"$t" 2>/dev/null && rm -f "$t"; then
  emit V1 0 "service=active; $dir writable (test file created+deleted)"
else
  [ -n "$t" ] && rm -f "$t" 2>/dev/null
  emit V1 1 "recordings dir not writable: $dir"
fi
