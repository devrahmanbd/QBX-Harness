#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness; F="$H/tests/fixtures"
st=$(mktemp -d); TD=$(mktemp -d)
trap 'rm -rf "$st" "$TD"' EXIT
# L1 red fixture
L1_LOG="$F/freeswitch-error.log" L1_OFFSET_FILE="$st/off" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-red.json" 2>&1
[ $? -eq 1 ] || { echo "L1 error fixture should be 1"; exit 1; }
# severity-class pin: fixture carries 1x[ERR] + 2x[ERROR] (the [CRIT] line is crash=) -> new_errors must be exactly 3, numerically (replaces the loose grep -q ERROR)
ne=$(grep -oE 'new_errors=[0-9]+' "$TD/l1-red.json" | grep -oE '[0-9]+')
[ "${ne:-0}" -eq 3 ] || { echo "L1 new_errors=${ne:-none} want 3 (fixture: 1x[ERR]+2x[ERROR])"; exit 1; }
# cursor advances on red too: second run on the SAME error fixture+offset reports only new bytes
L1_LOG="$F/freeswitch-error.log" L1_OFFSET_FILE="$st/off" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-red2.json" 2>&1
[ $? -eq 0 ] || { echo "L1 error fixture second run should be 0 (cursor advanced): $(cat "$TD/l1-red2.json")"; exit 1; }
grep -q 'scanned=0' "$TD/l1-red2.json" || { echo "L1 error fixture second run should scan 0 bytes: $(cat "$TD/l1-red2.json")"; exit 1; }
# L1 green fixture + baseline advance (second scan sees 0 new bytes)
L1_LOG="$F/freeswitch-clean.log" L1_OFFSET_FILE="$st/off2" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-green.json" 2>&1
[ $? -eq 0 ] || { echo "L1 clean fixture should pass"; exit 1; }
L1_LOG="$F/freeswitch-clean.log" L1_OFFSET_FILE="$st/off2" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-green2.json" 2>&1
grep -q 'scanned=0' "$TD/l1-green2.json" || { echo "second run should scan 0 bytes: $(cat "$TD/l1-green2.json")"; exit 1; }
# live checks
bash "$H/checks/Q1-queues.sh" >"$TD/q1.json" 2>&1 || { echo "Q1 should pass: $(cat "$TD/q1.json")"; exit 1; }
bash "$H/checks/V1-voicemail.sh" >"$TD/v1.json" 2>&1 || { echo "V1 should pass: $(cat "$TD/v1.json")"; exit 1; }
# E1 base: exit 0, or controller-ruled blocked(2) with pinned evidence while gateways are 0 (known pre-DIDX state)
E1_RESTART_PROBE=0 bash "$H/checks/E1-esl-reconnect.sh" >"$TD/e1.json" 2>&1; e1=$?
if [ "$e1" -ne 0 ]; then
  [ "$e1" -eq 2 ] && grep -q 'no gateways listed' "$TD/e1.json" \
    || { echo "E1 base should pass (or blocked-2 while trunk pending): $(cat "$TD/e1.json")"; exit 1; }
fi
# I1 is externally blocked today: expect exit 2 with counter evidence
bash "$H/checks/I1-carrier-health.sh" >"$TD/i1.json" 2>&1; i1=$?
if [ "$i1" -ne 2 ]; then
  # counter may have moved after the DIDX test — accept 0 only with packets>0 evidence
  [ "$i1" -eq 0 ] && grep -qE 'packets=[1-9]' "$TD/i1.json" || { echo "I1 want 2 (or 0 with traffic): $i1 $(cat "$TD/i1.json")"; exit 1; }
fi
# E1 restart probe (spec restart clause) — opt-in: outer env gates it (Task 10 runs the suite
# with E1_RESTART_PROBE=1); inner invocation keeps E1_RESTART_PROBE=1 for the check itself.
# Dormant until a trunk exists: zero gateways makes the check decline with blocked(2) BEFORE the probe block.
if [ "${E1_RESTART_PROBE:-0}" = "1" ]; then
  E1_RESTART_PROBE=1 bash "$H/checks/E1-esl-reconnect.sh" >"$TD/e1r.json" 2>&1; e1r=$?
  if [ "$e1r" -eq 2 ] && grep -q 'no gateways listed' "$TD/e1r.json"; then
    echo "restart probe declined: no gateways (trunk pending) — coverage resumes post-trunk"
  elif [ "$e1r" -ne 0 ]; then
    echo "E1 restart probe: $(cat "$TD/e1r.json")"; exit 1
  fi
fi
echo ok
