# checks/C1-config-integrity.sh
# memory-query: config integrity reloadxml entrypoint mounts
# timeout: 40
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require docker C1
# NOTE: esl() is a shell function; timeout(1) cannot exec functions, so inline its body here, interpolating the shared ${HOST_NS[*]} array.
full=$(run_to 20 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py reloadxml" 2>/dev/null)
out=$(head -1 <<<"$full")
case "$out" in +OK*|OK*) :;; "") emit C1 3 "reloadxml timeout/empty";; *) emit C1 1 "reloadxml rejected: $out";; esac
mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "${FS_CONTAINER:-telecom-freeswitch-1}" 2>/dev/null)
[ -n "$mounts" ] || emit C1 3 "docker inspect failed: cannot verify mounts for ${FS_CONTAINER:-telecom-freeswitch-1}"
if grep -qx '/etc/freeswitch' <<<"$mounts"; then
  emit C1 1 "/etc/freeswitch is host-mounted (config not container-local)"
fi
ep="${C1_ENTRYPOINT:-/root/QBX/deploy/freeswitch/entrypoint.sh}"
[ -f "$ep" ] || emit C1 1 "entrypoint missing: $ep"
grep -qE 'FS_[A-Z_]*_SIP_PORT' "$ep" || emit C1 1 "entrypoint lost FS_*_SIP_PORT contract: $ep"
emit C1 0 "reloadxml=$out; /etc/freeswitch container-local; entrypoint contract present ($(grep -cE 'FS_[A-Z_]*_SIP_PORT' "$ep") hits)"
