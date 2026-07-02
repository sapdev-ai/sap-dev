---
name: sap-compare
description: |
  Compare the SAME ABAP object across two SAP systems — the pinned connection
  (LEFT) and a second saved profile selected with --against <hint> (RIGHT).
  DDIC objects (table / structure / data element / domain / table type) are
  compared field-by-field over RFC on BOTH sides (DDIF_FIELDINFO_GET). Programs
  / includes / function modules are compared by source over RFC via
  RPY_PROGRAM_READ (sap_rfc_read_source.ps1). Emits a structured field diff
  (diff.json), a unified source diff, and an AI summary that annotates each
  difference with the likely cause — including release skew using each system's
  saved release marker. Read-only: never modifies either system.
  Prerequisites: BOTH systems saved via /sap-login (RFC password required, same
  Windows user — DPAPI is CurrentUser-scoped). Class source compare is limited
  (RFC class source unsupported until ADT mode).
argument-hint: "<OBJECT_NAME> --against <profile-hint> [--type ...] [--ddic|--source]"
---

# SAP Compare Skill

Diffs one repository object between two systems and explains the differences.
Use it for landscape drift ("works in QAS, fails in DEV"), pre-transport sanity
checks, and confirming an import landed. Pure read-only on both systems
(observes `shared/rules/skill_operating_rules.md`).

## Shared Resources

| File | Path | Purpose |
|---|---|---|
| `sap_settings_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1` | `Get-SapSettingValue` |
| `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1` | `Get-SapWorkDir`, `Resolve-SapProfileHint`, `Get-SapCurrentConnectionProfile` |
| `sap_dpapi.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1` | decrypt RIGHT password (`-Action unprotect`; invoked as a subprocess) |
| `sap_rfc_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1` | `Connect-SapRfc`, `Disconnect-SapRfc`, `New-RfcReadTable` |
| `sap_rfc_read_source.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1` | `Read-SapAbapSource` (cross-system source) |
| `sap_compare_ddic.ps1` | `<SKILL_DIR>\references\sap_compare_ddic.ps1` | dual-connect DDIC fetch + structured field diff -> `diff.json` |
| `sap_compare_diff.ps1` | `<SKILL_DIR>\references\sap_compare_diff.ps1` | normalize + text diff (source mode) |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |

Parse `WORK_DIR=` and `RUN_TEMP=` from stdout.

Set `{WORK_TEMP}` = `{work_dir}\temp` and `{RUN_TEMP}` = the `RUN_TEMP=` value
(`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`). Set
`{OUT}` = `{RUN_TEMP}\compare\{OBJECT}` — per-run private scratch, so concurrent
`/sap-compare` runs never clobber each other's `left.def`/`right.def`/`diff.json`.
Ensure `{OUT}` exists:
```bash
cmd /c if not exist "{OUT}" mkdir "{OUT}"
```

## Step 0.5 — Start Logging (best-effort)
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_compare_run.json" -Skill sap-compare -ParamsJson "{\"args\":\"{RAW_ARGS}\"}"
```

## Step 1 — Parse Arguments
- `{OBJECT}` = first positional, uppercased.
- `--against <hint>` -> `{AGAINST}` (**required**). Uses `Resolve-SapProfileHint`
  grammar: UUID, `last`, `default`, `<SID>`, `<SID>/<CLIENT>/<USER>`, or a
  description substring.
- `--type` -> `{TYPE}` (default `auto`).
- `--ddic` / `--source` -> force `{MODE}` (otherwise derived in Step 3).

## Step 2 — Resolve & Connect BOTH Systems

The reference scripts own the dual connection. For source mode, the SKILL can
also drive it directly. Resolution refuses on ambiguity (mirrors the broker
"ambiguous = refuse loudly" rule):

```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1'

# LEFT = pinned (empty params => Connect-SapRfc falls back to the pinned profile)
$left = Connect-SapRfc -DestName "CMP_LEFT"
if (-not $left) { Write-Output "ERROR: LEFT not connected (run /sap-login)"; exit 2 }

# RIGHT = --against profile, explicit creds
$cands = @(Resolve-SapProfileHint -Hint '{AGAINST}')
if ($cands.Count -eq 0) { Write-Output "ERROR: profile '{AGAINST}' not found"; exit 2 }
if ($cands.Count -gt 1) { Write-Output "ERROR: '{AGAINST}' is ambiguous — qualify as <SID>/<CLIENT>/<USER>"; exit 2 }
$t  = $cands[0]
$pw = (& '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dpapi.ps1' -Action unprotect -Value "$($t.password_dpapi)" 2>$null) -as [string]
$right = Connect-SapRfc -Server $t.application_server -Sysnr $t.system_number `
          -MessageServer $t.message_server -LogonGroup $t.logon_group -SystemID $t.system_id `
          -Client $t.client -User $t.user -Password $pw -Language $t.language -DestName "CMP_RIGHT"
if (-not $right) { Write-Output "ERROR: RIGHT '{AGAINST}' not connected (RFC creds / DPAPI / reachability)"; exit 2 }
```
Record `{LEFT_SID}` / `{RIGHT_SID}` and each profile's `server_release_marker` for the Step 5 annotation.

> Note: `Connect-SapRfc` publishes `$g_*` caller-scope vars (last call wins) and
> `Disconnect-SapRfc` cleans up the *last* config. Keep `$left`/`$right` and let
> the reference scripts own lifecycle; don't rely on `$g_*` after the 2nd connect.

## Step 3 — Detect Type (on LEFT, RFC) & Pick Mode
If `{TYPE}=auto`, probe LEFT via `New-RfcReadTable` (same table set as
`/sap-explain-object` Step 3: `TRDIR`/`TFDIR`/`SEOCLASS`/`DD02L`/`DD04L`/`DD01L`/`DD40L`).

| Detected type | `{MODE}` |
|---|---|
| table, structure, data element, domain, table type | `ddic` |
| program, include, fm | `source` |
| class / interface | `source` (RFC source unsupported -> see Limitations) |

`--ddic` / `--source` override the mapping.

## Step 4a — DDIC Mode
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_compare_ddic.ps1" -Object "{OBJECT}" -Type "{DDIC_TYPE}" -Against "{AGAINST}" -OutDir "{OUT}"
```
`sap_compare_ddic.ps1` connects both systems, fetches the definition on each
(`DDIF_FIELDINFO_GET` for table/structure; `DDIF_DTEL_GET` / `DD01L` / `DD40L`
for DE/domain/table type — the chain from `sap_rfc_lookup_ddic.ps1`,
parameterized by `-Dest`), and writes `{OUT}\diff.json` + `left.def` / `right.def`.

`diff.json`:
```json
{ "object":"{OBJECT}","type":"{DDIC_TYPE}",
  "left":{"sid":"{LEFT_SID}","exists":true,"read_status":"OK"},
  "right":{"sid":"{RIGHT_SID}","release":"...","exists":true,"read_status":"OK"},
  "verdict":"DIFFERS","reason":"",
  "identical":false,
  "added":[{"field":"ZZREASON","datatype":"CHAR","len":"40","dec":"0"}],
  "removed":[], "type_changed":[{"field":"MENGE","left":"QUAN","right":"QUAN"}],
  "length_changed":[{"field":"NAME1","left":"30.0","right":"40.0"}],
  "reordered":["WERKS","MATNR"] }
```

**`read_status` per side** distinguishes a genuine absence from a fetch failure:
`OK` (read, present), `ABSENT` (read, object not found), `FAILED` (RFC/read error
— state unknown). **`verdict`** is the authoritative result — the script emits
`IDENTICAL`/`DIFFERS` only when BOTH sides read OK; if either side is `FAILED`, or
both sides are `ABSENT`, it emits **`COMPARE_UNAVAILABLE`** (exit 1) with `reason`,
never a false `IDENTICAL`. One side `ABSENT` + the other `OK` → `DIFFERS` ("exists
only on LEFT/RIGHT").

**Parse the `RESULT:` line:**
| Last-but-one line | Meaning |
|---|---|
| `RESULT: IDENTICAL` | both read OK + structurally equal |
| `RESULT: DIFFERS` | both read (fields differ, or exists on exactly one side) |
| `RESULT: COMPARE_UNAVAILABLE - <reason>` | a side failed to read, or absent on both — **do not** report identical; surface the reason and stop |

## Step 4b — Source Mode
```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1'
$L = Read-SapAbapSource -Name '{OBJECT}' -Type '{TYPE}' -OutDir '{OUT}\left'  -Dest $left  -WithIncludes
$R = Read-SapAbapSource -Name '{OBJECT}' -Type '{TYPE}' -OutDir '{OUT}\right' -Dest $right -WithIncludes
```
Then unified diff (per file; includes matched by name):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_compare_diff.ps1" -LeftDir "{OUT}\left" -RightDir "{OUT}\right" -OutFile "{OUT}\diff.txt"
```
Handle `Status` per side: `NOT_FOUND` -> record "exists only on LEFT/RIGHT";
`UNSUPPORTED` (class) -> stop with the class-limitation message.

## Step 5 — Synthesize `diff.md`
Read `diff.json` (ddic) or `diff.txt` (source) plus both release markers; write `{OUT}\diff.md`:
1. **Verdict** — identical / differs / exists only on one side / **compare unavailable**
   (a side's `read_status` is `FAILED`, or both `ABSENT`). Never render a
   `COMPARE_UNAVAILABLE` result as "identical" — report the `reason` instead.
2. **What differs** — concrete fields or source hunks with line refs.
3. **Likely cause** — classify each diff: *real change* vs. *release skew*
   (a field/statement present only on the higher `server_release_marker` is
   probably a version delta, not a defect).
4. **Recommended action** — e.g., "retrofit ZZREASON into {LEFT_SID} before transport."

## Step 6 — Report & Clean Up
Print `{OUT}` + the verdict. Disconnect both destinations. `{OUT}` and the
`_run.json` state live under `{RUN_TEMP}` (per-run private scratch), swept
automatically by `Remove-SapStaleRunTemp` — copy any `diff.md` the user wants to
keep to a stable location before it ages out.

## Final — Log End
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_compare_run.json" -Status SUCCESS -ExitCode 0
```
(On failure use `-Status FAILED -ExitCode 1`. `-Status` must be one of `SUCCESS|FAILED|SKIPPED|EXISTED|ABANDONED`.)

## Composition
- After a diff, run `/sap-explain-object {OBJECT}` to understand one side's logic,
  or feed `diff.md` into a fix on the lagging system (`/sap-se38` / `/sap-se11` / ...).
- Pairs with a transport pipeline: compare target vs. source post-import to verify the import.

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: profile not found` / `ambiguous` | bad `--against` hint | qualify as `<SID>/<CLIENT>/<USER>` |
| RIGHT decrypt fails | profile saved by a different Windows user (DPAPI CurrentUser) | re-save via `/sap-login` as the current user |
| `UNSUPPORTED` (source) | class/interface over RFC | use ADT mode (planned) or compare on the GUI-attached system only |
| many spurious source diffs | gen-timestamp / formatting | extend `sap_compare_diff.ps1` normalization rules |

## Limitations
- **Source compare needs `sap_rfc_read_source.ps1`** (RPY); without it, source mode is unavailable.
- **Class/interface source** not comparable cross-system until ADT mode (planned).
- **Same-name assumption** in v1 (object named identically on both sides); future `--right-name <name>`.
- **Client-dependent DDIC** edge cases and append-structure ordering are normalized best-effort; `reordered` is informational, not a defect.
- DPAPI is **CurrentUser**-scoped — both profiles must be saved under the same Windows account.
