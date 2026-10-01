# checks/H1-process-container.sh
# memory-query: freeswitch container health systemd
# timeout: 20
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require docker H1; require pgrep H1
st=$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "${FS_CONTAINER:-telecom-freeswitch-1}" 2>/dev/null) || emit H1 3 "docker inspect failed for ${FS_CONTAINER:-telecom-freeswitch-1}"
pid=$(pgrep -xo freeswitch) || emit H1 1 "freeswitch process not found (state=$st)"
case "$st" in running/healthy) emit H1 0 "container=$st freeswitch_pid=$pid";; *) emit H1 1 "container=$st freeswitch_pid=$pid (want running/healthy)";; esac
