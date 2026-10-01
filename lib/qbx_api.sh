# lib/qbx_api.sh — source after common.sh. qbx_login prints token; exit 1 on failure.
#!/usr/bin/env bash
qbx_login() {
  local B="${M1_BASE_URL:-http://127.0.0.1:3006}" jar csrf
  jar=$(mktemp); csrf=$(mktemp)
  # token lives in the RESPONSE HEADER X-Csrf-Token (body is {"status":"ok"})
  CSRF=$("${HOST_NS[@]}" curl -s -D - -o /dev/null -c "$jar" "$B/api/v1/csrf" 2>/dev/null \
         | grep -i '^X-Csrf-Token:' | tr -d '\r' | awk '{print $2}')
  if [ -z "$CSRF" ]; then rm -f "$jar" "$csrf"; return 1; fi
  TOKEN=$("${HOST_NS[@]}" curl -s -b "$jar" -c "$jar" -H 'Content-Type: application/json' \
         -H "X-CSRF-Token: $CSRF" -X POST "$B/api/v1/login" \
         -d "{\"email\":\"${QBX_ADMIN_EMAIL:?}\",\"password\":\"${QBX_ADMIN_PASSWORD:?}\"}" 2>/dev/null \
         | jq -r '.token // empty')
  rm -f "$jar" "$csrf"
  [ -n "$TOKEN" ] && [ "${#TOKEN}" -ge 100 ] || return 1
  printf '%s' "$TOKEN"
}
