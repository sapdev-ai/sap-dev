---
name: sap-docs-estimate
description: |
  Turn the spec pipeline's structural signals into a transparent, falsifiable effort estimate
  — no gut feel. `score` reads a spec work folder's `_*.txt` DDIC/process/interface counts and
  `/sap-docs-check` ambiguity rows, applies published weights, and maps the complexity class to
  a WIDE effort band with named drivers and an assumptions register. `--batch` rolls up a
  portfolio of specs; `--ledger` bands a `/sap-cc-triage` migration wave by (tier x object
  type). `record-actuals` appends real hours to an append-only ledger so every estimate becomes
  measurable; `calibrate` (v1.5) tightens the multipliers once enough pairs accrue. Pure-local,
  read-only, no SAP access in v1 (a `--live-delta` brownfield-credit RFC mode is v2). Every
  report is labelled UNCALIBRATED so a wide band can never masquerade as a commitment.
argument-hint: "<work-folder> [--brief <path>]  |  --batch <folder-of-folders>  |  --ledger <findings_triaged.tsv>  |  record-actuals <estimate-id> --actual <hours> [--phase build|test|total]"
---

# SAP Docs Estimate — Structural Effort Bands (uncalibrated, falsifiable)

Score effort from the spec pipeline's own structural signals instead of gut feel, and make
every estimate falsifiable via an actuals ledger. **Pure-local and read-only** — no SAP
access, no TR, no deploys in v1.

Task: $ARGUMENTS

**Anti-anchoring rule (mandatory):** every rendered estimate carries the header
`STRUCTURAL BAND — not a quote; calibration=<NONE|n pairs>`. An uncalibrated band is wide by
design and must never be presented as a commitment.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_docs_estimate.ps1` | `-Folder\|-Batch\|-Ledger …` | Deterministic offline scorer → SIGNAL/SCORE/BAND lines |
| `<SKILL_DIR>/references/sap_estimate_ledger.ps1` | `-Action record\|list\|pairs` | Append-only estimate/actuals ledger |
| `<SKILL_DIR>/references/estimate_weights.tsv` | weights | Per-signal complexity weights; override `{custom_url}\estimate_weights.tsv` |
| `<SKILL_DIR>/references/effort_bands.tsv` | bands | (type×class) + (tier×object) bands + DECLARED uplifts; override `{custom_url}\effort_bands.tsv` |
| `<SKILL_DIR>/references/fixtures/` | fixtures | Offline test fixtures (spec_min, spec_max, findings_triaged.tsv) |
| `/sap-docs-check` (Skill tool) | *(suggested)* | Suggested when `check_result_*.txt` are missing — improves the ambiguity signal |
| `/sap-log-analyze --builds` (Skill tool) | *(v1.5)* | Refresh build KPIs before `calibrate` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | Step 5 | Artifact index for /sap-evidence-pack |

## Step 0 — Resolve Work Dir + Metrics Dir

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom'))); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Ledger + calibration live at `{work_dir}\metrics\` (stable cross-run path — NOT `{RUN_TEMP}`).
Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed above (`Get-SapRunTemp` mints + creates the
per-run scratch dir holding the log state file) — for logging state only; mint it once here and
reuse (re-minting breaks the `-Action end` state-file lookup).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_docs_estimate_run.json" -Skill sap-docs-estimate -ParamsJson "{}"
```

## Step 1 — Mode Dispatch

- default `<work-folder>` → **score**; `--batch <folder>` → **portfolio**; `--ledger <tsv|campaign-id>`
  → **wave banding**; `record-actuals <id> --actual <h>` → **ledger append**.
- `calibrate` → **v1.5**: run `sap_estimate_ledger.ps1 -Action pairs`; if it returns
  `EST_CALIBRATION_INSUFFICIENT`, print the honest cold-start message (`need N more actuals`)
  and STOP. Writing adjusted multipliers ships in v1.5.
- `--live-delta` → **v2**: say `NOT_YET_IMPLEMENTED — brownfield RFC credit ships in v2` and
  continue with the offline score (never block).

## Step 2 — Input Inventory

List which `_*.txt` / `check_result_*.txt` exist in the folder (the coverage matrix). If
`check_result_*` are missing, **suggest** `/sap-docs-check` (do not auto-run) so the ambiguity
signal is populated.

## Step 3 — Score

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_docs_estimate.ps1" -Folder "<work-folder>" -WeightsFile "<SKILL_DIR>\references\estimate_weights.tsv" -BandsFile "<SKILL_DIR>\references\effort_bands.tsv" -CustomUrl "{custom_url}"
```

Use `-Batch`/`-Ledger` for those modes. Parse `SIGNAL:` (per-signal count/weight/contrib/
coverage), `SCORE: raw=… class=… covered=c/t program_type=…`, `BAND: … total_low=… total_high=…
calibration=…`, and `STATUS:`. A signal with `coverage=COULD_NOT_CHECK` means its input file
was absent — the band is widened and confidence drops; **never render it as low complexity**.
No scoreable inputs → `EST_INPUT_MISSING`, exit 1, nothing written.

## Step 4 — Render

Write `estimate_<doc>.md` + `.tsv` into the work folder (batch: `portfolio_estimate.*` beside
the folders; ledger: `wave_estimate.*`). The report leads with the anti-anchoring header, then:
build band + total-with-uplift band, complexity class, **named drivers**, the **coverage
matrix** (every COULD_NOT_CHECK signal listed), and the **assumptions register** (every DECLARED
uplift factor + every missing signal is one row). Append an ESTIMATE row to the ledger:

```bash
… sap_estimate_ledger.ps1 -Action record -Id "<estimate-id>" -Kind ESTIMATE -ScopeKey "<PROG_…>" -Class <c> -BandLow <lo> -BandHigh <hi> -LedgerFile "{work_dir}\metrics\estimate_ledger.tsv"
```

Print the estimate-id and the exact `record-actuals` follow-up command.

## Step 5 — record-actuals

```bash
… sap_estimate_ledger.ps1 -Action record -Id "<estimate-id>" -Kind ACTUAL -Phase <build|test|total> -Hours <n> -Source "<timesheet>" -Note "…" -LedgerFile "{work_dir}\metrics\estimate_ledger.tsv"
```

Unknown id → `EST_ID_UNKNOWN` (fail-loud, no silent new row). Corrupt ledger → `EST_LEDGER_IO`.
Echo the pairing status (how many actuals now recorded for the id).

## Step 6 — Register & Log End

Register each rendered file via `Register-SapArtifact -Kind estimate -Coverage
CHECKED|COULD_NOT_CHECK` (no gate verdict — estimates are not gates). Then:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_docs_estimate_run.json" -Status SUCCESS -ExitCode 0
```

---

## Scope & Limitations

- **v1 implemented:** `score` (one folder), `--batch` (portfolio), `--ledger` (triage-wave
  banding by tier×object type), `record-actuals` (append-only ledger). Deterministic and
  pure-local — same inputs → identical score (verified). No SAP access.
- **Honest by construction:** a missing input file = that signal `COULD_NOT_CHECK` (band
  widened, never a silent zero); every report is labelled UNCALIBRATED; uplift factors are
  DECLARED (kept in the assumptions register, never folded silently into the band);
  `record-actuals` on an unknown id is refused; `calibrate` below `--min-pairs` (default 8) is
  refused with a cold-start message — no fake calibration.
- **Bands are deliberately wide** and only as good as the shipped `effort_bands.tsv` until the
  actuals ledger + `calibrate` (v1.5) tighten them. The value compounds: the ledger makes every
  estimate measurable, so improvement is provable rather than asserted.
- **EC2 / release independence:** the skill is pure-local, so it works regardless of the
  connected system; there is no SAP surface to diverge. (The v2 `--live-delta` brownfield-credit
  RFC mode is claimed for S/4HANA only.)
- **Not yet:** `calibrate` writing adjusted multipliers (v1.5, joins the ledger to
  `/sap-log-analyze` build KPIs); `--live-delta` RFC brownfield credit — objects the spec
  defines that already exist score as UPDATE not CREATE (v2, read-only RFC_READ_TABLE).
