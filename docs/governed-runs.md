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
