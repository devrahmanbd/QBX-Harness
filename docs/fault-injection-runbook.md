# Fault-Injection Runbook (industry-grade-harness Task 3.1)

Monthly deliberate-fault proof that the harness catches real faults.
Policy: staging constructs ONLY — never degrade real traffic paths.
Each fault maps 1:1 to exactly one expected check. Caught → proof recorded
here + `fixes.log`. Missed → fix-or-explain item before the next scheduled run.

Safety gates for EVERY live fault (no exceptions):
- `nsenter -t 1 -n python3 /root/esl_api.py "show channels"` reads `0 total`
  BEFORE and AFTER. Non-zero → STOP, clear residue first, re-verify.
- Labeled artifacts only (`staging-fault-*`, `/tmp/qbx-fault-staging/`).
- Nothing touching prod listeners, nft rules, certs, or traffic paths.
  If any step risks production → STOP with NEEDS_CONTEXT, do not improvise.

## Fault 1 — Tenant-key violation → C2 (EXECUTED 2026-10-09, CAUGHT)

- Mapped check: `checks/C2-tenant-key.sh` (fixture mode; prod telephony scope untouched).
- Injection (staging-only):
  ```bash
  mkdir -p /tmp/qbx-fault-staging
  printf 'package staging\n\nconst StagingProbe = "fault-injection-clean"\n' \
    > /tmp/qbx-fault-staging/probe.go
  C2_SCAN_DIR=/tmp/qbx-fault-staging C2_ONLY=probe.go bash checks/C2-tenant-key.sh  # expect exit 0
  printf '\nvar stagingTenantRef = map[string]string{"tenant_id": "staging-fault-001"}\n' \
    >> /tmp/qbx-fault-staging/probe.go   # <-- THE FAULT
  C2_SCAN_DIR=/tmp/qbx-fault-staging C2_ONLY=probe.go bash checks/C2-tenant-key.sh  # expect exit 1
  ```
- Expected evidence signature (exit 1):
  `forbidden tenant key in code lines: /tmp/qbx-fault-staging/probe.go:7:var stagingTenantRef = map[string]string{"tenant_id": "staging-fault-001"}`
- Revert: restore the clean file (or `rm -rf /tmp/qbx-fault-staging`), re-run
  fixture → exit 0 `telephony scope clean (0 tenant_id/qbx_tenant_id code hits)`.
- Proof: fixes.log 2026-10-09 entry (green→red→green, channels 0 total both ends).

## Fault 2 — Dead gateway → I1 (DOCUMENTED, NOT YET EXECUTED)

- Mapped check: `checks/I1-carrier-health.sh` (sole carrier-health signal).
- Injection (staging-only; REQUIRES owner-designated staging gateway — never
  touch the prod DIDX nft rule or any live sofia gateway):
  ```bash
  # on the STAGING FreeSWITCH only: add gateway staging-dead-gw pointed at a
  # blackhole, rescan, confirm: sofia status gateway staging-dead-gw -> DOWN
  # then run the I1-equivalent assertion against the staging target.
  ```
- Expected evidence signature: TBD at first live execution. I1 only inspects
  the prod-host nft ruleset for the prod DIDX rule, so a staging-gateway-DOWN
  fault is NOT predicted to trip it — the nft-missing string must NOT be
  asserted as the outcome. Candidate pair I1 is kept honestly marked; the
  likely result is MISS → pre-filed fix-or-explain item: harness needs a
  dedicated gateway-status check (that finding IS the value).
- Revert: delete the staging gateway object, rescan, confirm gateway gone /
  I1-equivalent green; `show channels` 0 total after.
- Status: procedure approved in shape only. First live execution is a later
  monthly cycle with owner sign-off; if I1 does not go red, file the
  fix-or-explain item per spec (likely outcome: harness needs a dedicated
  gateway-status check — that finding IS the value).

## Fault 3 — Expired staging cert → H4 (DOCUMENTED, NOT YET EXECUTED)

- Mapped check: `checks/H4-tls-certs.sh` (`H4_HOST` override; ports 7443/5061 fixed).
- Injection (staging-only; loopback listeners ONLY — never bind 0.0.0.0, never
  touch prod certs on 88.99.250.99):
  ```bash
  # mint expired self-signed staging cert (enddate in the past), serve via
  # openssl s_server bound to 127.0.0.1 on the two H4 ports, then:
  H4_HOST=127.0.0.1 bash checks/H4-tls-certs.sh  # expect exit 1
  ```
- Expected evidence signature (exit 1): `cert days: p7443=<n>d p5061=<m>d < min=14`
  with negative/stale day counts from the expired staging cert.
- Revert: kill the staging `s_server` listeners, re-run H4 against the real
  host → exit 0 with positive day counts; `show channels` 0 total after.
- Status: DOCUMENTED, NOT EXECUTED (loopback-bind must first be verified
  conflict-free against prod listeners in the execution cycle).
- NOTE (review fix): exact `openssl s_server` bind commands + the
  loopback-conflict pre-check are NOT final — they MUST be fleshed out in
  Fault 3's execution cycle before its first live run. Read-only design input
  (2026-10-09, check-runner net namespace): `ss -ltn` shows no local 7443/5061
  listeners here, but prod 7443/5061 live on 88.99.250.99 and the execution
  cycle must re-verify `ss -ltn | grep -E ':(7443|5061)'` in the namespace
  where H4 will run, use explicit loopback binds only (never 0.0.0.0), and
  abort on any conflict. Nothing was bound or minted for this NOTE.

## Cadence log

| Date | Fault | Check | Verdict | Evidence pointer |
|------|-------|-------|---------|------------------|
| 2026-10-09 | tenant-key violation (`staging-fault-001`) | C2 | CAUGHT (exit 1, signature quoted) | fixes.log 2026-10-09T06:4xZ entry |
