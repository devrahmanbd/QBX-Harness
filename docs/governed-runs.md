# Governed Harness Runs (Task 1.1)

Standing supervised verification for the FreeSWITCH platform loop.
Owner: TBD (user decision). Proposed cadence: daily 03:00 UTC (timer ships DISABLED).

## Manual run

```bash
bash /root/qbx-harness/bin/loop            # full run (memory degrades gracefully while quota dead)
bash /root/qbx-harness/bin/loop --only I1  # single check
bash /root/qbx-harness/bin/loop --no-memory # no mem0 paths at all (quota freeze)
```

Artifacts land in `/root/qbx-harness/runs/<ts>/` (`results.jsonl` + `report.md`).
Every claim must round-trip to `results.jsonl`; see `bin/report` Notes wording.

## Timer install (owner step — NOT yet enabled)

```bash
ln -s /root/qbx-harness/systemd/qbx-harness-run.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemd-analyze verify qbx-harness-run.service qbx-harness-run.timer
systemctl enable --now qbx-harness-run.timer   # ONLY with owner-approved cadence
```

## Exit contract

- `0` complete (findings listed are real: fix, accept, or escalate)
- `1` breaker tripped (3 consecutive error-3) — investigate before any release
- `2` never a loop exit (per-check blocked only); `130` aborted by signal

## Notes

- E1 restart probe never runs under the timer (no `E1_RESTART_PROBE` in unit env).
- M1/M2/S4 place labeled, self-cleaning test calls on every run — expected.
- mem0 quota dead until 2026-11-01: runs report `memory_degraded=1`; use
  `--no-memory` for zero mem0 contact during the freeze.
- L1 tolerated-red (accepted cost, 2026-10-07): M3's deposit teardown logs
  `sofia_presence.c:555 Cannot find profile qbx.qubickle.com` on most sweeps, so
  L1 exits 1 while the loop still exits 0 (only exit-3 trips the breaker). The
  call itself succeeds; the ERR is FS looking up the domain as a profile name
  during `mod_voicemail` teardown. Distinguish this known string from any NEW
  error class before triaging. Durable options (separate tickets, not this doc):
  QBX-side presence/teardown fix, or L1/M3 adjustment.

## Timer policy (Task 1.1 live, 2026-10-09)

- Cadence: daily 03:00 UTC (`systemd/qbx-harness-run.timer`,
  `RandomizedDelaySec=600`, `Persistent=true`). Owner approval to enable
  recorded by controller 2026-10-09; timer is `enabled` + `active (waiting)`.
- Proof: 2026-10-09 timer fire ran a real sweep end to end —
  `journalctl -u qbx-harness-run.service` shows start 05:01:29 CEST / finish
  05:05:10 CEST, artifact `runs/20261009T030129Z-2439678/` (21 result lines,
  loop exit 0). Watchdog verdict on that artifact: `H2=1` pages (exit-1),
  `E1=2 I1=2` recorded in the non-paging `qbx_harness_check_note` series
  (spec pages exit 1 only), `tolerated-excluded=2` (L1 string + MEM-GATE).
  Silence is the green signal: green sweeps record exit 0 and fire no alert.
- Each sweep ends with `ExecStartPost=/root/qbx-harness/bin/watchdog.sh`
  (`-`-prefixed: watchdog never fails the unit), which exports the verdict
  to the node_exporter textfile
  `/var/lib/prometheus/node-exporter/qbx-harness.prom`.

## Tolerated-red paging exclusion

- `bin/watchdog.sh` pages ONLY untolerated exit-1 checks (check names in the
  `qbx_harness_check_exit{check,run_id}` series → `QBXHarnessRedSweep`
  (`== 1`) → Alertmanager `telegram` receiver). Untolerated exit 2/3 lines go
  to the non-paging `qbx_harness_check_note` series. Tolerated-red matches are
  counted in `qbx_harness_tolerated_red_count` and recorded in `results.jsonl`,
  never paged.
- Canonical tolerated substrings (keep `bin/watchdog.sh` TOLERATED in sync):
  - `Cannot find profile qbx.qubickle.com` — L1 accepted cost above.
  - MEM-GATE exit 1 while the mem0 quota freeze lasts (its evidence line
    carries no stable string, so the check ID is the key; `TOLERATED_IDS` in
    watchdog, expires 2026-11-01 — remove after re-verifying gate green).
- Missed run: no `runs/<ts>/` artifact past fire time + 30 min grace
  (`--grace-min`, spec window 15–30) → watchdog exit 1 +
  `QBXHarnessMissedRun` incident (metric `qbx_harness_missed_run`, plus a
  staleness backstop `time() - qbx_harness_last_run_timestamp_seconds > 90000`).
- Rules: `/etc/prometheus/rules/qbx-harness.yml` (same shape as
  `qbx-failures.yml`; `promtool check rules`, Prometheus SIGHUP-loaded).
- Watchdog contract: `0` ok / `1` incident (missed or untolerated red) /
  `130` aborted; `64` bad usage; `2` never used. `tests/14-watchdog.test.sh`.
