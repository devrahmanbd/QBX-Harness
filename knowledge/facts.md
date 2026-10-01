source: facts.md
SIP port layout on the production host: the external sofia profile listens on UDP/TCP 5060, the internal profile for extensions listens on 5080, TLS signalling is 5061, WebSocket is 5067, and WSS is 7443 — checks S1/H3 expect exactly this surface (5060/5080 hits increasing, no unintended ports in the nftables counters).

source: facts.md
FreeSWITCH configuration is container-local at /etc/freeswitch inside the telecom-freeswitch-1 container and is (re)served by the mounted deploy/freeswitch/entrypoint.sh on every container start, so a restart restores the intended dynamic-only tree; the host never holds a writable config tree and no static .xml tenant files may exist on disk (mod_xml_curl is the only config authority; restart safety comes from the entrypoint, patches must live in entrypoint.sh sed commands).

source: facts.md
Canonical ESL runner command: `nsenter -t 1 -n python3 /root/esl_api.py "<cmd>"` — for example `nsenter -t 1 -n python3 /root/esl_api.py "status"` returns that FreeSWITCH "is ready"; nsenter is mandatory because the shell netns differs from the host netns.

source: facts.md
Tenant key rules: dialplan and resolver code set only the `qbx_sub_id` channel variable for tenant scoping; introducing `tenant_id` or `qbx_tenant_id` is forbidden — the only `tenant_id` hit in the Go tree is a comment (C2 hygiene invariant).

source: facts.md
Harness exit-code contract: 0=pass, 1=fail (open-finding candidate), 2=blocked (external dependency), 3=error; any other child code (e.g. 130) normalizes to 3 with `normalized_from` in evidence. The circuit breaker trips only on 3 consecutive error(3) exits — open-finding(1) and blocked(2) never count — and an operator SIGINT aborts the run (exit 130) without counting as a check error.

source: facts.md
Fixture flag + qbx-test-echo flow: the deterministic test dialplan is gated by `QBX_ENABLE_DETERMINISTIC_TEST_DIALPLAN=true` (set in /etc/qbx/env/*.service.env, the systemd units, and /root/QBX/.env), and `POST /api/v1/calls` with body `{"to_number":"qbx-test-echo","from_extension":"2100"}` returns 201 {call_id, job_id} where call_id equals the FreeSWITCH origination_uuid; the echo path runs CREATE→ANSWER→HANGUP with a matching `cdrs` row (script legend 0=pass, 1=fail, 2=exception, 3=blocked), and M2 SIP proof expects invite 200 with `app=echo` PCMU media.

source: facts.md
mem0 async semantics: `POST /v1/memories/` responds 200 `[{status:PENDING,event_id}]` and memories materialize in ≤7 s, so every write must poll before relying on it — `bin/mem0 add --wait` polls search for up to ~60 s, `bin/ingest-memory` stores chunks with `--wait`, non-2xx responses exit 4, and `bin/memory-gate` retries each probe (3 attempts × 5 s) before declaring a miss.

source: facts.md
DIDX inbound blocker state: the nftables rule `ip saddr 198.211.99.232 udp dport 5060 counter packets 0` currently shows 0 packets — check I1 therefore reports blocked(2) ("DIDX sent 0 packets, awaiting DIDX portal ring-to test") until the carrier delivers live UDP traffic to 88.99.250.99:5060.

source: facts.md
Login/CSRF/Idempotency-Key facts: `GET /api/v1/csrf` returns the token in the response header `X-Csrf-Token` (body is `{"status":"ok"}`) and must be sent as `X-CSRF-Token` on `POST /api/v1/login {email,password}` which yields `{token}` (length 427–435); admin credentials work for `POST /api/v1/calls` while operator gets "Insufficient permissions"; the `Idempotency-Key` header must be 16–128 printable characters, and a replayed create returns 201 with the same call_id.
