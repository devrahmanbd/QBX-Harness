# tests/07-media.test.sh
#!/usr/bin/env bash
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
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
# M1 residue containment (fixture, hermetic — no live infra): planted legs must be
# force-cleaned with residue-cleaned=N at exit 0; unkillable legs must exit 1 naming uuids
m1u1="11111111-2222-4333-8444-555555555555"
m1u2="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
printf '{"result":"pass","validation":{"passed":true},"call_id":"fixture-call-1","events":[{"event_type":"CHANNEL_ANSWER"},{"event_type":"CHANNEL_HANGUP_COMPLETE"}]}\n' > "$TD/m1-residue-art.json"
cat > "$TD/fake-esl.py" <<'EOF'
#!/usr/bin/env python3
# fake ESL_API (esl() always execs python3 $ESL_API): state file $FAKE_STATE holds
# `show channels` body; $FAKE_KILL_FAIL lists unkillable uuids, one per line.
import os, re, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
state = os.environ.get("FAKE_STATE", "/dev/null")
killfail = os.environ.get("FAKE_KILL_FAIL", "/dev/null")
def read():
    try:
        with open(state) as f:
            return f.read()
    except OSError:
        return ""
if cmd == "show channels":
    sys.stdout.write(read())
elif cmd.startswith("show channels like "):
    u = cmd[len("show channels like "):]
    for line in read().splitlines():
        if line.startswith(u):
            print(line)
elif cmd.startswith("uuid_kill "):
    u = cmd[len("uuid_kill "):].split()[0]
    try:
        with open(killfail) as f:
            bad = {l.strip() for l in f}
    except OSError:
        bad = set()
    if u in bad:
        print("-ERR kill failed")
        sys.exit(1)
    lines = [l for l in read().splitlines() if not l.startswith(u)]
    n = sum(1 for l in lines if re.match(r'^[0-9a-f]{8}-[0-9a-f-]{27}', l))
    lines = [l for l in lines if not re.match(r'^[0-9]+ total\.', l)] + ["%d total." % n]
    with open(state, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("+OK")
else:
    print("-ERR unknown: " + cmd)
    sys.exit(1)
EOF
m1_fix_run() { # m1_fix_run <state> <killfail> <out> -> rc (M1_BASE_URL blackholed: must stay hermetic)
  FAKE_STATE="$1" FAKE_KILL_FAIL="$2" ESL_API="$TD/fake-esl.py" M1_SKIP_LIVE=1 M1_CDR_FAKE="completed/10/200/NORMAL_CLEARING" \
    M1_BASE_URL=http://127.0.0.1:1 M1_ART_FILE="$TD/m1-residue-art.json" RUN_DIR="$TD" \
    bash "$H/checks/M1-lifecycle.sh" >"$3" 2>&1
}
{ echo "$m1u1,inbound,2026-10-09 12:00:01,1,loopback/qbx-test-echo-a,CS_EXECUTE,2100,2100,x,qbx-test-echo,echo,,XML,default"
  echo "$m1u2,inbound,2026-10-09 12:00:02,2,loopback/qbx-test-echo-b,CS_EXECUTE,2100,2100,x,qbx-test-echo,echo,,XML,default"
  echo "2 total."; } > "$TD/m1-state-a.txt"
: > "$TD/m1-killfail-empty.txt"
m1_fix_run "$TD/m1-state-a.txt" "$TD/m1-killfail-empty.txt" "$TD/m1-fix-a.json"; [ $? -eq 0 ] \
  || { echo "M1 residue fixture should be 0: $(cat "$TD/m1-fix-a.json")"; exit 1; }
grep -q 'residue-cleaned=2' "$TD/m1-fix-a.json" || { echo "M1 must report residue-cleaned=2: $(cat "$TD/m1-fix-a.json")"; exit 1; }
grep -q '^0 total\.' "$TD/m1-state-a.txt" || { echo "M1 left residue behind: $(cat "$TD/m1-state-a.txt")"; exit 1; }
{ echo "$m1u1,inbound,2026-10-09 12:00:01,1,loopback/qbx-test-echo-a,CS_EXECUTE,2100,2100,x,qbx-test-echo,echo,,XML,default"
  echo "1 total."; } > "$TD/m1-state-b.txt"
printf '%s\n' "$m1u1" > "$TD/m1-killfail-one.txt"
m1_fix_run "$TD/m1-state-b.txt" "$TD/m1-killfail-one.txt" "$TD/m1-fix-b.json"; [ $? -eq 1 ] \
  || { echo "M1 unkillable fixture should be 1: $(cat "$TD/m1-fix-b.json")"; exit 1; }
grep -q "$m1u1" "$TD/m1-fix-b.json" || { echo "M1 must name unkillable uuid: $(cat "$TD/m1-fix-b.json")"; exit 1; }
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
