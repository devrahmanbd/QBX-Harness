# checks/C-ctx-exact-match.sh
# memory-query: dialplan exact match anchored condition context realm scoping
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C-ctx; require awk C-ctx
# Every destination_number condition in the live render authority must be an
# exact anchor (^literal$ or ^+QuoteMeta(destination)+$). Two deliberate
# exceptions, allowlisted by renderer: UnallocatedDIDDocument `.*` (fail-closed
# 404, respond action verified below) and renderDeterministicTestContext
# `^(.*)$` (realm-gated echo fixture).
src="${C_CTX_SRC:-/root/QBX/backend/services/api-gateway/internal/freeswitchresolver}"
[ -d "$src" ] || emit C-ctx 3 "render source missing: $src"
r="$src/resolver.go"; [ -f "$r" ] || emit C-ctx 3 "resolver.go missing in $src"
other=$(grep -rln 'destination_number' /root/QBX/backend --include='*.go' 2>/dev/null \
  | grep 'expression' | grep -v _test | grep -vE 'freeswitchresolver/|pkg/telecom/' || true)
[ -z "$other" ] || emit C-ctx 1 "condition renderer outside authority: $(tr '\n' ' ' <<<"$other")"
# *_test.go furnish policy fixtures (forbidden-input strings) — production renders only.
gofiles=$(ls "$src"/*.go | grep -v '_test\.go$')
scan() { awk 'FNR==1{fn=""} /^func /{fn=$2; sub(/\(.*/, "", fn)} /destination_number/ && /expression/ {print fn" :: "FILENAME" :: "$0}' $gofiles; }
unanchored=$(scan | while IFS= read -r row; do
  case "$row" in *QuoteMeta*|*'"^'*) : ;; *) printf '%s\n' "$row" ;; esac
done)
if [ -n "$unanchored" ]; then
  total=$(printf '%s' "$unanchored" | grep -c . || true)
  allow=$(printf '%s' "$unanchored" | grep -c '^UnallocatedDIDDocument ::' || true)
  [ "$allow" = "$total" ] && [ "$total" = 1 ] || \
    emit C-ctx 1 "unanchored destination condition outside 404 allowlist: $(printf '%s' "$unanchored" | head -2 | tr '\n' ' ')"
  grep -q 'respond.*404 Tenant DID Unallocated' "$r" || emit C-ctx 1 "404 allowlist lacks fail-closed respond action"
fi
catchall_fn=$(awk 'FNR==1{fn=""} /^func /{fn=$2; sub(/\(.*/, "", fn)} /expression.*\^\(\.\*\)\$/ && !/QuoteMeta/ {print fn}' $gofiles | sort -u | tr '\n' ' ')
case " $catchall_fn" in
  ""|" renderDeterministicTestContext ") : ;;
  *) emit C-ctx 1 "catch-all ^(.*)\$ outside test fixture: $catchall_fn" ;;
esac
n=$(grep -h 'destination_number' $gofiles | grep -c 'expression' || true)
emit C-ctx 0 "exact-match holds: $n destination conditions anchored; catch-all only in test fixture; 404 fail-closed allowlisted"
