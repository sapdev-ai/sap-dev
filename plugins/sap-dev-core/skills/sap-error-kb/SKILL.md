---
name: sap-error-kb
description: |
  Curate the team frequently_errors knowledge base — the per-object store of
  recurring FM / class-method / codegen mistakes that sap-gen-abap reads to
  steer generation away from known traps. Deploy skills (sap-se38/se37/se24)
  and sap-atc auto-record new FM/METHOD errors here as CANDIDATE rows; this
  skill lets a human review and promote them.
  Four operations:
    - list    show CANDIDATE rows awaiting review (default; --all also shows CONFIRMED)
    - promote mark a CANDIDATE row CONFIRMED so it starts influencing generation
    - mute    suppress a row (seed or candidate) so it is never injected
    - show    print one per-object file for manual editing
  Pure-local: reads/writes {custom_url}\frequently_errors\ (team-shared, NOT
  MEMORY files). No SAP connection required.
argument-hint: "list [--all] | promote <OBJECT> <KEY> | mute <OBJECT> <KEY> | show <OBJECT>"
---

# SAP frequently_errors Knowledge-Base Curator

You curate the frequently_errors store — the team-shared catalog of recurring
FM / class-method / codegen traps + remedies. See the loop overview in
`<SAP_DEV_CORE_SHARED_DIR>/rules/frequently_errors.md`.

Task: $ARGUMENTS

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/frequently_errors.md` | The loop's contract — tiers, precedence, schema, statuses |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_error_hints.ps1` | CLI — this skill runs `-Action curate -Op list|promote|mute` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_error_hints_lib.ps1` | Engine dot-sourced by the CLI |
| `<SAP_DEV_CORE_SHARED_DIR>/tables/frequently_errors.tsv` | TIER-3 seed (read-only baseline) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | Start/step/end logging wrapper. State file: `{RUN_TEMP}\sap_error_kb_run.json`. Best-effort. |

---

## Step 0 — Resolve Work Directory + custom_url

Resolve `work_dir` and `custom_url` via the env-aware helper (do NOT read
`settings.json` directly — Rule 7):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` and ensure it exists.

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}`.

The per-object files live under `{custom_url}\frequently_errors\`. The
hand-authored override is `{custom_url}\frequently_errors.tsv`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_error_kb_run.json" -Skill sap-error-kb -ParamsJson "{\"args\":\"$ARGUMENTS\"}"
```

---

## Step 1 — Parse the operation

| Operation | Form | Meaning |
|---|---|---|
| `list` (default) | `list [--all]` | List CANDIDATE rows across all per-object files. `--all` also lists CONFIRMED rows. |
| `promote` | `promote <OBJECT> <KEY>` | Set a row's STATUS to CONFIRMED so it is injected into generation. |
| `mute` | `mute <OBJECT> <KEY>` | Set a row's STATUS to MUTE so it is never injected (suppresses a noisy seed/candidate). |
| `show` | `show <OBJECT>` | Print one `{custom_url}\frequently_errors\<OBJECT>.tsv` file for inspection / manual editing. |

`<OBJECT>` is the FM or class name (it is sanitized to the file stem). `<KEY>`
is the 4-part merge key shown by `list`: `OBJECT_TYPE|OBJECT_NAME|CONTEXT|ERROR_CLASS`.

---

## Step 2 — Run the operation

### list

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_error_hints.ps1" -Action curate -Op list -CustomUrl "{custom_url}"
```

Add `-IncludeConfirmed` for `--all`. Each `CAND` line is:
`CAND <file> <STATUS> occ=<n> seen=<date> <KEY> <wrong-pattern-preview>`.
Last line: `STATUS: LISTED count=<n>`.

Present the candidates as a readable table. For each, advise the user to
review the WRONG_PATTERN and add a CORRECT_PATTERN (the load-bearing remedy)
by editing the file (see `show` + manual edit) BEFORE promoting — a CANDIDATE
with no remedy teaches the generator nothing once promoted.

### promote / mute

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_error_hints.ps1" -Action curate -Op promote -CustomUrl "{custom_url}" -Object "<OBJECT>" -Key "<KEY>"
```

Use `-Op mute` to suppress instead. Output `STATUS: CONFIRMED <KEY>` /
`STATUS: MUTE <KEY>` (exit 0) or `STATUS: ERROR key-not-found <KEY>` (exit 1).

**Before promoting**, confirm the row has a CORRECT_PATTERN. If it is blank
(typical for an auto-recorded CANDIDATE), open the file (`show`), fill in the
remedy with the Edit tool, THEN promote. Promotion without a remedy is
allowed but discouraged — surface a warning to the user.

### show

Read `{custom_url}\frequently_errors\<sanitized-OBJECT>.tsv` with the Read
tool and present it. To edit (add a CORRECT_PATTERN, fix RELEASE, etc.), use
the Edit tool directly on that file — it is a plain TAB-separated TSV; keep
real TABs and UTF-8 (no BOM).

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_error_kb_run.json" -Status SUCCESS -ExitCode 0
```

On error use `-Status FAILED -ExitCode 1 -ErrorClass ERROR_KB_FAILED`.

---

## Notes

- This skill never touches SAP. It only reads/writes local TSV files under
  `{custom_url}`.
- The auto-record write path (deploy + ATC) lands rows as `CANDIDATE`. Only
  `CONFIRMED` rows are injected into `sap-gen-abap` generation by default
  (`frequently_errors_inject_status`); set that to `ALL` to also inject
  candidates if your team prefers fast feedback over curation.
- To share the knowledge base across a team, point `custom_url` at a shared
  drive or a checked-out git repo (it is the same folder that holds
  `customer_brief.md` and the other `{custom_url}` overrides).
