#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness; F="$H/tests/fixtures"
st=$(mktemp -d); TD=$(mktemp -d)
trap 'rm -rf "$st" "$TD"' EXIT
# L1 red fixture
L1_LOG="$F/freeswitch-error.log" L1_OFFSET_FILE="$st/off" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-red.json" 2>&1
[ $? -eq 1 ] || { echo "L1 error fixture should be 1"; exit 1; }
grep -q 'ERROR' "$TD/l1-red.json" || { echo "L1 evidence must quote ERROR"; exit 1; }
# L1 green fixture + baseline advance (second scan sees 0 new bytes)
L1_LOG="$F/freeswitch-clean.log" L1_OFFSET_FILE="$st/off2" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-green.json" 2>&1
[ $? -eq 0 ] || { echo "L1 clean fixture should pass"; exit 1; }
L1_LOG="$F/freeswitch-clean.log" L1_OFFSET_FILE="$st/off2" bash "$H/checks/L1-fs-logs.sh" >"$TD/l1-green2.json" 2>&1
grep -q 'scanned=0' "$TD/l1-green2.json" || { echo "second run should scan 0 bytes: $(cat "$TD/l1-green2.json")"; exit 1; }
# live checks
bash "$H/checks/Q1-queues.sh" >"$TD/q1.json" 2>&1 || { echo "Q1 should pass: $(cat "$TD/q1.json")"; exit 1; }
bash "$H/checks/V1-voicemail.sh" >"$TD/v1.json" 2>&1 || { echo "V1 should pass: $(cat "$TD/v1.json")"; exit 1; }
bash "$H/checks/E1-esl-reconnect.sh" >"$TD/e1.json" 2>&1 || { echo "E1 base should pass: $(cat "$TD/e1.json")"; exit 1; }
# I1 is externally blocked today: expect exit 2 with counter evidence
bash "$H/checks/I1-carrier-health.sh" >"$TD/i1.json" 2>&1; i1=$?
if [ "$i1" -ne 2 ]; then
  # counter may have moved after the DIDX test — accept 0 only with packets>0 evidence
  [ "$i1" -eq 0 ] && grep -qE 'packets=[1-9]' "$TD/i1.json" || { echo "I1 want 2 (or 0 with traffic): $i1 $(cat "$TD/i1.json")"; exit 1; }
fi
# E1 restart probe (spec restart clause) — runs once here; requires 0 live channels
E1_RESTART_PROBE=1 bash "$H/checks/E1-esl-reconnect.sh" >"$TD/e1r.json" 2>&1 || { echo "E1 restart probe: $(cat "$TD/e1r.json")"; exit 1; }
echo ok
