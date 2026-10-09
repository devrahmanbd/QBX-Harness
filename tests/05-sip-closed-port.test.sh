#!/usr/bin/env bash
# tests/05-sip-closed-port.test.sh — hermetic split of 05-sip: closed-port
# negatives only (silence must never pass). Live sections (S2 green-path on
# the QBX-SBC port, S2/S3/S1/S4 live) are live-only, see
# docs/harness-ci-contract.md. Netns-independent: closed ports stay closed in
# any netns.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
# closed-port negatives: silence must never pass
S2_HOST=127.0.0.1 S2_EXTERNAL_PORT=9 S2_INTERNAL_PORT=9 bash "$H/checks/S2-sip-identity.sh" >"$TD/s2-closed.json" 2>&1
[ $? -eq 1 ] || { echo "S2 closed-port should be 1"; exit 1; }
grep -q 'NO-RESPONSE' "$TD/s2-closed.json" || { echo "S2 evidence must show NO-RESPONSE"; exit 1; }
S3_HOST=127.0.0.1 S3_PORT=9 bash "$H/checks/S3-fail-closed.sh" >/dev/null 2>&1
[ $? -eq 1 ] || { echo "S3 closed-port should be 1"; exit 1; }
echo ok
