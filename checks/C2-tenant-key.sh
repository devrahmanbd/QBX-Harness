# checks/C2-tenant-key.sh
# memory-query: tenant key qbx_sub_id subscription
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C2
dir="${C2_SCAN_DIR:-/root/QBX}"
[ -d "$dir" ] || emit C2 3 "scan dir missing: $dir"
# Revised invariant (user decision): tenant_id is forbidden in the telephony/call
# path only; a parallel tenant_id model exists outside it. Scan exactly these dirs.
telepaths="backend/services/api-gateway/internal/handler backend/services/api-gateway/internal/freeswitchresolver backend/services/call-control-service backend/pkg/telecom backend/services/websocket-gateway deploy/freeswitch"
if [ -n "${C2_ONLY:-}" ]; then
  target="$dir/$C2_ONLY"
  [ -e "$target" ] || emit C2 3 "target missing: $target"
  hits=$(grep -rEnH '\btenant_id\b|qbx_tenant_id' --include='*.go' "$target" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*//' || true)
else
  for t in $telepaths; do [ -d "$dir/$t" ] || emit C2 3 "telephony path missing: $dir/$t"; done
  hits=$(for t in $telepaths; do grep -rEnH '\btenant_id\b|qbx_tenant_id' --include='*.go' --include='*.sh' "$dir/$t" 2>/dev/null; done | grep -vE ':[0-9]+:[[:space:]]*//' || true)
fi
# note: grep -c prints the count itself even on no-match (exit 1) — never append `|| echo 0`
sub=$(grep -c 'qbx_sub_id=' "$dir/backend/pkg/telecom/dialplan.go" 2>/dev/null || true); sub=${sub:-0}
res=$(grep -c 'qbx_sub_id' "$dir/backend/services/api-gateway/internal/freeswitchresolver/resolver.go" 2>/dev/null || true); res=${res:-0}
if [ -n "${C2_ONLY:-}" ]; then sub=1; res=1; fi   # fixture mode skips anchor checks
[ "$sub" -ge 1 ] && [ "$res" -ge 1 ] || \
  emit C2 1 "qbx_sub_id anchors missing (dialplan=$sub resolver=$res)"
if [ -n "$hits" ]; then
  emit C2 1 "forbidden tenant key in code lines: $(printf '%s' "$hits" | head -3 | tr '\n' ' ')"
fi
emit C2 0 "qbx_sub_id anchors dialplan=$sub resolver=$res; telephony scope clean (0 tenant_id/qbx_tenant_id code hits)"
