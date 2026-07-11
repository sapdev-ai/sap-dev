# sap-health-check

**The daily morning health sweep as one repeatable, baselined command** — read-only
over RFC. Replaces the 30–60-minute ST22/SM13/SM37/SM12/SMQ1-2/SP01/WE02 walk that's
judged from memory and skipped exactly when it matters.

```
/sap-health-check [--profile morning] [--connection PROFILE] [--window-hours N] [--no-gui] [--json]
/sap-health-check baseline <accept|show|reset>
```

## What it does

- **Six RFC probe families**, one connection: stuck **IDocs** (EDIDC error/waiting
  statuses), **tRFC** backlog (ARFCSSTATE by dest×state), **qRFC** queue depth (the
  TRFC_QIN/QOUT queue-monitor FMs), **spool** finishing-errors (TSP02), aborted **jobs**
  (TBTCO STATUS='A' by name-stem), ABAP **dumps** (SNAP by user×host).
- **Composition, not duplication** — delegates to `/sap-diagnose`'s `sm13`/`sm12`/`slg1`
  readers (update failures, stale locks, app-log errors) and optionally `/sap-st22` for
  dump detail (only when a GUI session is live; `--no-gui` skips it).
- **The genuinely new value: a persisted per-system baseline.** Every finding is a coarse
  fingerprint classified **NEW** vs known-**RECURRING**, with **RESOLVED** for things that
  cleared — so a morning sweep judges each signal against a known-good baseline instead of
  memory. Each finding carries a ready-to-paste `/sap-diagnose` drill-in command.
- `baseline accept/show/reset` manages the baseline (`accept` marks the current NEW
  findings as known-recurring — a plain confirm, since it changes future verdicts).

## Honest by construction

An area that can't run (auth/RFC) is `COULD_NOT_CHECK`, never a silent healthy; any
COULD_NOT_CHECK caps the verdict at DEGRADED. The window is date-granularity and stated as
such; row caps surface honestly; the ST22 leg is skipped (with a note) when no GUI session
is live, and SNAP counts remain the authoritative dump signal either way.

## Reads

`EDIDC` (IDocs), `ARFCSSTATE` (tRFC), `TRFC_QIN/QOUT_GET_CURRENT_QUEUES` (qRFC), `TSP02`
(spool), `TBTCO` (jobs), `SNAP` (dumps). All FMODE=R / TRANSP, identical on both releases.
The baseline + snapshots are local JSON under `{work_dir}\runtime\health\` and
`{artifact_dir}`.

Read-only on SAP (the only GUI touch is the optional /sap-st22 dump leg); no Z-object, no
dev-init — safe to point at production, same posture as /sap-diagnose. `--trend` rollups,
the `close` posting-period profile, and hypercare snapshot `--compare` are the next phases.
Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP).
