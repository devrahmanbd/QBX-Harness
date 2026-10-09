#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
echo "{\"check\":\"ZZ130\",\"exit\":130,\"evidence\":\"killed\",\"ts\":\"x\"}"; exit 130
