#!/usr/bin/env bash
# TDD for the C-every-render-tenant-prefix check: fixture RED (prefix-less
# renderer fails naming the offender, incl. an outbound render with actions
# but no prefix) then fixture GREEN, then live (3 families pinned + outbound
# no-live-route note).
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"; C="$H/checks/C-every-render-tenant-prefix.sh"
F="$H/tests/fixtures/tenant-prefix"
[ -x "$C" ] || { echo "check missing/not executable: $C"; exit 1; }
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
# RED 1: prefix-less feature renderer must exit 1 naming the offender family
mkdir -p "$TD/red"
cp "$F/bad-feature.xml" "$TD/red/feature.xml"
cp "$F/good-default.xml" "$TD/red/default.xml"
cp "$F/good-inbound.xml" "$TD/red/inbound.xml"
cp "$F/noroute-outbound.xml" "$TD/red/outbound.xml"
C_PREFIX_FIXTURE_DIR="$TD/red" bash "$C" >"$TD/red.json" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { echo "RED feature: want exit 1, got $rc: $(cat "$TD/red.json")"; exit 1; }
grep -q 'feature' "$TD/red.json" || { echo "RED feature: offender not named: $(cat "$TD/red.json")"; exit 1; }
# RED 2: outbound render WITH actions but no prefix must still fail (skip
# applies only to no-route docs, never to real renders)
mkdir -p "$TD/red2"
cp "$F/good-feature.xml" "$TD/red2/feature.xml"
cp "$F/good-default.xml" "$TD/red2/default.xml"
cp "$F/good-inbound.xml" "$TD/red2/inbound.xml"
cp "$F/bad-outbound.xml" "$TD/red2/outbound.xml"
C_PREFIX_FIXTURE_DIR="$TD/red2" bash "$C" >"$TD/red2.json" 2>&1; rc=$?
[ "$rc" -eq 1 ] || { echo "RED outbound: want exit 1, got $rc: $(cat "$TD/red2.json")"; exit 1; }
grep -q 'outbound' "$TD/red2.json" || { echo "RED outbound: offender not named: $(cat "$TD/red2.json")"; exit 1; }
# GREEN: all pinned (+ outbound no-route note) must exit 0
mkdir -p "$TD/green"
cp "$F/good-feature.xml" "$TD/green/feature.xml"
cp "$F/good-default.xml" "$TD/green/default.xml"
cp "$F/good-inbound.xml" "$TD/green/inbound.xml"
cp "$F/noroute-outbound.xml" "$TD/green/outbound.xml"
C_PREFIX_FIXTURE_DIR="$TD/green" bash "$C" >"$TD/green.json" 2>&1 \
  || { echo "GREEN fixture should pass: $(cat "$TD/green.json")"; exit 1; }
jq -e '.check=="C-every-render-tenant-prefix" and .exit==0' "$TD/green.json" >/dev/null \
  || { echo "GREEN fixture not exit 0: $(cat "$TD/green.json")"; exit 1; }
# OUT-OF-SCOPE: non-extension-targeted render (hangup-only, no prefix, no
# extension applications) must skip with an explicit token — NOT offender,
# NOT silent
mkdir -p "$TD/oos"
cp "$F/good-feature.xml" "$TD/oos/feature.xml"
cp "$F/good-default.xml" "$TD/oos/default.xml"
cp "$F/oos-hangup.xml" "$TD/oos/inbound.xml"
cp "$F/noroute-outbound.xml" "$TD/oos/outbound.xml"
C_PREFIX_FIXTURE_DIR="$TD/oos" bash "$C" >"$TD/oos.json" 2>&1 \
  || { echo "OOS fixture should skip-pass: $(cat "$TD/oos.json")"; exit 1; }
jq -e '.check=="C-every-render-tenant-prefix" and .exit==0' "$TD/oos.json" >/dev/null \
  || { echo "OOS fixture not exit 0: $(cat "$TD/oos.json")"; exit 1; }
grep -q 'inbound([^)]*)=out-of-scope-skipped' "$TD/oos.json" \
  || { echo "OOS token missing/not family-named: $(cat "$TD/oos.json")"; exit 1; }
# LIVE: served config must carry the prefix on every live-renderable family
bash "$C" >"$TD/live.json" 2>&1 \
  || { echo "LIVE should pass: $(cat "$TD/live.json")"; exit 1; }
jq -e '.check=="C-every-render-tenant-prefix" and .exit==0' "$TD/live.json" >/dev/null \
  || { echo "LIVE not exit 0: $(cat "$TD/live.json")"; exit 1; }
grep -q 'prefix-ok sub=' "$TD/live.json" || { echo "LIVE evidence lacks tenant key: $(cat "$TD/live.json")"; exit 1; }
echo ok
