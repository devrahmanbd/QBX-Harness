# tests/07-media.test.sh
#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness
TD=$(mktemp -d)
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$TD" "$RUN_DIR"' EXIT   # covers json scratch + RUN_DIR on every path (R-tmp), not just success
# M2 selector hermetic pin: newest-by-created_epoch beats an older zombie — pure function of its input, no live infra
eval "$(sed -n '/^m2_select_echo_leg()/,/^}/p' "$H/checks/M2-echo-media.sh")"
ch_rows=$(cat <<'EOF'
810ffe97-2110-4d73-9431-88bdfde7112b,inbound,2026-10-02 00:22:51,1790900571,loopback/qbx-test-echo-b,CS_EXECUTE,4000,4000,88.99.250.99,qbx-test-echo,echo,,XML,default
b418e1ab-2dad-4059-a8b4-cc271d99e91a,inbound,2026-10-02 01:42:27,1790905347,sofia/internal/4000@88.99.250.99,CS_EXECUTE,4000,4000,88.99.250.99,qbx-test-echo,echo,,XML,default
EOF
)
sel=$(m2_select_echo_leg "$ch_rows")
[ "$sel" = "b418e1ab-2dad-4059-a8b4-cc271d99e91a" ] || { echo "M2 selector must pick newest-by-created_epoch, got '${sel:-none}'"; exit 1; }
# M1 offline red: unreachable API must be error(3), not a crash
M1_BASE_URL=http://127.0.0.1:1 RUN_DIR="$TD" bash "$H/checks/M1-lifecycle.sh" >"$TD/m1-red.json" 2>&1
[ $? -eq 3 ] || { echo "M1 offline should be 3: $(cat "$TD/m1-red.json")"; exit 1; }
grep -q 'api login failed' "$TD/m1-red.json" || { echo "M1 evidence must say login failed"; exit 1; }
# M1 live: full lifecycle + CDR + no leftover channels
export RUN_DIR
bash "$H/checks/M1-lifecycle.sh" >"$TD/m1.json" 2>&1 || { echo "M1 live should pass: $(cat "$TD/m1.json")"; exit 1; }
jq -e '.exit==0' "$TD/m1.json" >/dev/null || { echo "M1 JSON exit != 0"; exit 1; }
jq -e '.result=="pass"' "$RUN_DIR/m1-lifecycle.json" >/dev/null || { echo "artifact not pass"; exit 1; }
# M2 live: counters above noise floor both directions, clean teardown
bash "$H/checks/M2-echo-media.sh" >"$TD/m2.json" 2>&1 || { echo "M2 live should pass: $(cat "$TD/m2.json")"; exit 1; }
ev=$(jq -r .evidence "$TD/m2.json")
printf '%s' "$ev" | grep -qE 'in=[0-9]+ out=[0-9]+' || { echo "M2 evidence lacks counters"; exit 1; }
in_n=$(printf '%s' "$ev" | grep -oE '(^| )in=[0-9]+' | grep -oE '[0-9]+'); out_n=$(printf '%s' "$ev" | grep -oE '(^| )out=[0-9]+' | grep -oE '[0-9]+')
[ "${in_n:-0}" -gt 50 ] && [ "${out_n:-0}" -gt 50 ] || { echo "counters below floor: in=$in_n out=$out_n"; exit 1; }
grep -q 'invite=.*200' "$RUN_DIR/m2-caller.out" && grep -q 'bye=.*200' "$RUN_DIR/m2-caller.out" \
  || { echo "caller did not complete cleanly"; exit 1; }
left=$(nsenter -t 1 -n python3 /root/esl_api.py "show channels" 2>/dev/null | grep -oE '^[0-9]+ total\.' | sed 's/ total\.//')
[ "${left:-1}" -eq 0 ] || { echo "channels not empty after checks (total=${left:-none})"; exit 1; }  # numeric "N total." == 0 means truly empty
echo ok
