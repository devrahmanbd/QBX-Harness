# checks/L2-auth-jail.sh
# memory-query: freeswitch auth fail2ban jail active storm
# timeout: 60
#!/usr/bin/env bash
# L2 asserts the freeswitch-auth fail2ban jail is ACTIVE and sighted on the
# live 1.10 log format: (1) fail2ban server reachable, (2) jail exists and
# reports its failregex, (3) recent live log still contains sofia_reg.c
# "Can't find user ... from <ip>" lines the filter was built for (format drift
# = jail blind = red). V9 PIN policy is PENDING and out of scope: jail only,
# no PIN assertions. Read-only probes; never enables or bans.
# Test hooks: L2_FAIL2BAN_CLIENT (stub client path), L2_LOG (log path),
# L2_JAIL (jail name, default freeswitch-auth).
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require fail2ban-client L2
F2B="${L2_FAIL2BAN_CLIENT:-fail2ban-client}"
LOG="${L2_LOG:-/root/QBX/logs/freeswitch/freeswitch.log}"
JAIL="${L2_JAIL:-freeswitch-auth}"
[ -f "$LOG" ] || emit L2 3 "log missing/unreadable: $LOG"
st=$($F2B status "$JAIL" 2>&1) || emit L2 1 "jail not active: $(tr '\n' ' ' <<<"$st" | cut -c1-200) (owner enablement pending? see docs/L2-auth-jail-storm-proof.md)"
grep -qiE "status for the jail|currently banned" <<<"$st" || emit L2 1 "jail status unreadable: $(tr '\n' ' ' <<<"$st" | cut -c1-200)"
fr=$($F2B get "$JAIL" failregex 2>&1) || emit L2 1 "jail has no failregex: $(tr '\n' ' ' <<<"$fr" | cut -c1-160)"
[ -n "$fr" ] || emit L2 1 "empty failregex for $JAIL"
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
tail -c 200000 "$LOG" 2>/dev/null | grep -aE '\[WARNING\] sofia_reg\.c:[0-9]+ Can.t find user \[[^]]+@[^]]+\] from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -3 >"$TD/hits" || true
n=$(wc -l <"$TD/hits" | tr -d ' ')
[ "$n" -ge 1 ] || emit L2 1 "live log format drift: no sofia_reg.c unknown-user lines in recent 200KB (filter blind; re-derive failregex from live 1.10 lines)"
sample=$(tail -1 "$TD/hits" | cut -c1-160)
emit L2 0 "jail $JAIL active; failregex set; live 1.10 format confirmed (recent_hits>=$n sample='$sample')"
