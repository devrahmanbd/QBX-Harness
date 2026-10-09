#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
echo "{\"check\":\"ZZLEAK\",\"exit\":1,\"evidence\":\"pw=FREESWITCH_ESL_PASSWORD=hunter2\",\"ts\":\"x\"}"; exit 1
