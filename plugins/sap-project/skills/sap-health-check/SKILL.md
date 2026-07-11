---
name: sap-health-check
description: |
  The daily morning health sweep as one repeatable, baselined command — read-only over
  RFC. Runs six probe families (stuck IDocs via EDIDC, tRFC backlog via ARFCSSTATE, qRFC
  queue depth via the queue monitor FMs, spool finishing-errors via TSP02, aborted jobs
  via TBTCO, ABAP dumps via SNAP), delegates to /sap-diagnose's sm13/sm12/slg1 readers,
  and — the genuinely new value — classifies every finding NEW vs known-RECURRING against
  a persisted per-system baseline, each with a ready-made /sap-diagnose drill-in command.
  Replaces the 30–60-minute ST22/SM13/SM37/SM12/SMQ1-2/SP01/WE02 walk judged from memory.
  `baseline accept/show/reset` manages the per-system baseline. Prerequisites: pinned
  profile via /sap-login (RFC); SAP NCo 3.1 (32-bit). No GUI (except an optional /sap-st22
  dump-detail leg), no Z-object, no dev-init — safe to point at production.
argument-hint: "[--profile morning] [--connection PROFILE] [--window-hours N] [--no-gui] [--json]  |  baseline <accept|show|reset>"
---

# SAP Health Check — Baselined Morning Sweep

You do the morning "are the interfaces healthy?" walk as ONE command, and — unlike a
manual walk judged from memory — classify every finding **NEW vs known-recurring**
against a persisted per-system baseline. Read-only; safe to point at production.

Task: $ARGUMENTS

**Pure read-only on SAP** in every v1 mode. The only GUI touch is an optional
/sap-st22 dump-detail leg (skipped without a live GUI session). `baseline accept`
writes only local state but changes future verdicts → plain confirm first.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_health_rfc_probes.ps1` | `-WindowHours [-Max -IdocMap] -OutDir` | The six RFC probe families → findings.tsv |
| `<SKILL_DIR>/references/sap_health_baseline.ps1` | `-Action classify\|accept\|show\|reset -BaselineFile [-FindingsTsv -Stamp] -OutDir` | Baseline NEW/RECURRING/RESOLVED delta |
| `<SKILL_DIR>/references/health_probe_matrix.tsv` | matrix | Per-area source/thresholds/enable; override at `{custom_url}\health_probe_matrix.tsv` |
| `<SKILL_DIR>/references/health_idoc_status_map.tsv` | map | IDoc status → ERROR/WAITING class (direction-aware); same override path |
| `/sap-diagnose` (Skill tool) | `--reader sm13\|sm12\|slg1` | Delegated update-failure / stale-lock / app-log readers |
| `/sap-st22` (Skill tool) | dump detail | Optional GUI leg (liveness-checked; `--no-gui` skips) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | Step 7 | Artifact index for /sap-evidence-pack |

---

## Step 0 — Resolve Work Directory, OUT, Baseline

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('STAMP=' + (Get-Date -Format 'yyyyMMddHHmmss'))"
```

Resolve the pinned connection's SID+client (from the profile / an `IDENT` line). Set
`{RUN_TEMP}`; `{OUT}` = `Get-SapArtifactDir -ScopeKey SYS_<SID>_<CLIENT> -Skill
sap-health-check`. **Baseline file (Bucket A, durable — NOT temp):**
`{work_dir}\runtime\health\<SID>_<CLIENT>_baseline.json`.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_health_check_run.json" -Skill sap-health-check -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Mode

Default `--profile morning`. `baseline accept|show|reset` → Step 8. `--connection
PROFILE` (else pinned), `--window-hours N` (default 24), `--no-gui`, `--json`.
`--trend` is **v1.5 (ships dark — needs ≥2 weeks of snapshots; `HC_NO_HISTORY` under 2)**;
`--profile close` and `--compare` are **v2** → say NOT_YET_IMPLEMENTED and STOP.

## Step 2 — Run the Six RFC Probes

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_health_rfc_probes.ps1" -WindowHours <N> -IdocMap "<SKILL_DIR>\references\health_idoc_status_map.tsv" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Parse `HC:` / `HC_AREA:` lines + `STATUS:`. A connect failure → exit 2, `RFC_LOGON_FAILED`,
**no verdict emitted**. A `HC_AREA: coverage=COULD_NOT_CHECK` area (auth/RFC failure) is
carried as such — never a silent healthy. The engine writes `findings.tsv`.

## Step 3 — Delegate the /sap-diagnose Readers

Invoke `/sap-diagnose --reader sm13`, `sm12`, `slg1` via the **Skill tool** (skill→skill,
never the reference `*.ps1` directly). Fold their evidence into the finding stream
(update failures, stale locks, app-log errors) as extra `HC:`-shaped rows. SM37 is NOT
delegated — the windowed aborted-job count lives in the probe engine (cheaper).

## Step 4 — Optional ST22 Dump Detail (GUI)

Only if **not** `--no-gui` AND a GUI session is live: run
`sap_check_gui_login_status.vbs` (32-bit cscript); on `LOGGED_IN` invoke `/sap-st22` for
top-N dump detail and enrich the dump fingerprints. Anything but `LOGGED_IN` skips the
leg (SNAP counts remain the authoritative dump signal — coverage stays CHECKED) and is
noted in the report.

## Step 5 — Baseline Delta

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_health_baseline.ps1" -Action classify -BaselineFile "{work_dir}\runtime\health\<SID>_<CLIENT>_baseline.json" -FindingsTsv "{OUT}\findings.tsv" -Stamp <STAMP> -OutDir "{OUT}"
```

Parse `DELTA: class=NEW|RECURRING|RESOLVED …` + `STATUS: OK new=.. recurring=.. resolved=..`.
A corrupt baseline → `HC_BASELINE_CORRUPT` (fail loud, STOP). Writes `health_snapshot.json`
and updates the baseline last-seen.

## Step 6 — Render the Report (you write this)

Write `health_report.md` into `{OUT}`. Per-area table: area / count / **new** / recurring /
worst severity. **Grounding rule: every row traces to findings.tsv.** For each finding give
a ready-to-paste **`/sap-diagnose` anchor command** to drill in (e.g.
`/sap-diagnose --object VBELN:… --reader sm13` for an update failure; `/sap-idoc find
--status <n>` for an IDoc cluster; `/sap-rfc-monitor --dest <d>` for a tRFC cluster).
Verdict `HEALTH: HEALTHY|DEGRADED|CRITICAL` (GO/GO_WITH_WARNINGS/NO_GO): any HIGH →
CRITICAL, any MEDIUM or any COULD_NOT_CHECK → at least DEGRADED, NEW findings raise a notch.
A clean sweep with any COULD_NOT_CHECK caps at DEGRADED (never HEALTHY).

## Step 7 — Register & Log End

Register `health_snapshot.json` (kind `health_snapshot`), `health_report.md` (kind
`health_report`), `findings.tsv` (kind `findings`) via `Register-SapArtifact` under scope
`SYS_<SID>_<CLIENT>` with Coverage + Verdict. Echo:

```
HEALTH: <verdict> areas=<n> new=<x> recurring=<y> could_not_check=<z>
```

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_health_check_run.json" -Status SUCCESS -ExitCode 0
```

## Step 8 — baseline accept / show / reset

`baseline show` → print the baseline. `baseline reset` → clear it (confirm first). `baseline
accept` → run the probes first (Step 2), then **list exactly which NEW fingerprints will be
marked recurring** and ask a plain confirm (it changes future verdicts — no typed
confirmation, no SAP write), then `-Action accept`.

---

## Scope & Limitations

- **v1 implemented:** `morning` sweep (6 RFC probe families + /sap-diagnose sm13/sm12/slg1
  delegation + optional /sap-st22 dump leg) with a persisted per-system baseline
  (NEW/RECURRING/RESOLVED), and `baseline accept/show/reset`. Read-only on SAP.
- **Single code path on ECC 6 and S/4HANA** — all six sources exist identically; verified
  live on S4D (S/4HANA 1909: 4876 tRFC LUWs, 1523 aborted jobs, 325 dumps clustered) and
  ERP (ECC 6: ARFCSSTATE 1854, TBTCO 32, SNAP 649, 87 qRFC queues) 2026-07-11.
- **Honesty (tri-state):** an area that can't run is `COULD_NOT_CHECK`, never a silent
  healthy; any COULD_NOT_CHECK caps the verdict at DEGRADED. Window is date-granularity
  (workstation clock; both systems are China time) — stated in the report; row caps
  (default 5000) surface honestly. The baseline is coarse-fingerprinted by design.
- **Not yet:** `--trend` month/week rollups (v1.5 — ships dark; `HC_NO_HISTORY` under 2
  snapshots); `--profile close` (posting periods / held docs / blocked billing) and
  `--compare` hypercare snapshot diff (v2); watch mode (v3).
- **The genuinely new value** vs a manual walk: every finding classified NEW vs recurring
  against the baseline, each with a ready-made drill-in command — no SUIM/SM-transaction
  screenshot gives that.
