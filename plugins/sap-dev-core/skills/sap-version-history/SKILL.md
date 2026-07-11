---
name: sap-version-history
description: |
  Reads the SAP version store over RFC (no GUI) to answer "who changed this
  program/FM, when, and what exactly changed" — the same-system TIME axis that
  complements /sap-compare's cross-system axis. Three read-only modes:
  `list` (version directory via SVRS_GET_VERSION_DIRECTORY_46 with a TR-status
  join — author, date, transport, released-flag, last-released), `diff` (unified
  line diff of any two stored versions, or the newest pair by default, with an AI
  change annotation), and `blame` (per-line attribution: which version / author /
  TR introduced each line, over a bounded window, honestly marking lines older
  than the window). Object kinds: programs, includes, function modules. Entirely
  RFC + local; nothing is written to SAP. Results register for /sap-evidence-pack.
  Use for: version history, "who changed Z...", program change history, diff two
  versions, version compare same system, blame ABAP lines, transport of a change.
  Prerequisites: an RFC-capable connection profile (/sap-login). No dev-init, no
  GUI session.
argument-hint: "<mode> <OBJECT> ...   list <OBJECT> [--type=program|include|fm] [--max=20]   |   diff <OBJECT> [<VERSNO_A> <VERSNO_B>] [--type=...] [--no-annotate]   |   blame <OBJECT> [--window=10] [--type=...]"
---

# SAP Version History — list · diff · blame (RFC)

You read the ABAP version store entirely over RFC (SAP NCo 3.1, 32-bit
PowerShell). **No GUI automation** — if RFC is unavailable you fail loud, never
half-drive SE38/SE37 version management. v1 is **pure read-only** (Rule 1); it
deploys nothing and writes nothing to SAP.

Task: $ARGUMENTS

Version content is read only through the SVRS function modules
(`SVRS_GET_VERSION_DIRECTORY_46`, `SVRS_GET_REPS_FROM_OBJECT`) — **never**
`RFC_READ_TABLE` on `VRSD` / `VRSX2` for source (VRSX2 stores compressed RAW
lines; the FM path is authoritative). The directory FM is more complete than a
capped raw `VRSD` read (verified: it surfaces the newest version a bounded VRSD
sample misses).

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/error_classes.md` | *(rule)* | `error_class` taxonomy (this skill's `VH_*` classes live here) |
| `<SKILL_DIR>/references/sap_version_rfc.ps1` | `%%RFC_LIB_PS1%%` (only) | RFC backend: `-Action list\|fetch`. `%%SAP_*%%` stay literal → `Connect-SapRfc` fills them from the pinned profile |
| `<SKILL_DIR>/references/sap_text_diff.ps1` | *(offline)* | Two-file LCS unified diff (context hunks); run directly, no tokens |
| `<SKILL_DIR>/references/sap_version_blame.ps1` | *(offline)* | Per-line blame (LCS-chained newest→oldest); run directly, no tokens |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect/disconnect; fills `%%SAP_*%%` from the pinned profile |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | *(CLI)* | Resolves the object token → `{pgmid, object, obj_name, kind}` (identity, no GET_R3TR FM) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `%%ARTIFACT_LIB_PS1%%` | Register list/diff/blame outputs for /sap-evidence-pack |

This skill drives no SAP GUI: no VBS, no golden-screen baseline, no session lock,
no GUI-Security sidecar.

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` + `artifact_dir` via the env-aware helper — do NOT read
`settings.json` directly:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('ARTIFACT_DIR=' + (Get-SapSettingValue 'artifact_dir' ((Get-SapWorkDir) + '\artifacts'))); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` (create if missing); `{RUN_TEMP}` = the
`RUN_TEMP=` value (all generated `*_run.ps1` and fetched source files go here).

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_version_history_run.json" -Skill sap-version-history -ParamsJson "{\"mode\":\"<MODE>\",\"object\":\"<OBJ>\"}"
```

---

## Step 1 — Parse Arguments & Dispatch Mode

The **first token** is the mode; the **second** is the object.

| Mode | Meaning | Write? |
|---|---|---|
| `list` | Version directory + TR-status join | read-only |
| `diff` | Unified diff of two stored versions (default: newest pair) + AI annotation | read-only |
| `blame` | Per-line attribution over a window | read-only |
| `restore` | **Phase 2** — not implemented; print "restore is planned for phase 2 (confirm-gated, delegates to /sap-se38//sap-se37); not available in v1" and stop. Never a partial write. |

Flags: `--type=program|include|fm` (optional; auto-resolved in Step 2 if absent),
`--max=N` (list, default 20), `--window=N` (blame, default 10, **hard cap 25**),
`--no-annotate` (diff). Unknown/missing mode → usage and stop.

---

## Step 2 — Resolve Object Identity

Resolve the token to a repository object and map it to the VRSD key:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1" -Token "<user object token>"
```

Read the `STATUS:` line:
- `RESOLVED` → take `kind`. Map to the SVRS `OBJTYPE`: **program / include → `REPS`**,
  **function module → `FUNC`**. If the user passed `--type`, it overrides (still
  program/include→REPS, fm→FUNC).
- `NOT_FOUND` / `AMBIGUOUS` → fail loud with the candidate list; register nothing.
- A **class / interface** token → `VH_TYPE_UNSUPPORTED` (per-include class
  versioning is v2); say so and stop.

Carry `{OBJ}` (the technical name, upper-cased) and `{OBJTYPE}` (`REPS`/`FUNC`)
into the backend calls.

---

## Step 3 — Materialize the RFC backend (all modes)

Substitute **only** `%%RFC_LIB_PS1%%`; leave every `%%SAP_*%%` token literal so
`Connect-SapRfc` fills them from the pinned profile:

```powershell
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_version_rfc.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
[IO.File]::WriteAllText('{RUN_TEMP}\vh_rfc_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
Write-Host 'Done'
```

### list (runs first in every mode)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\vh_rfc_run.ps1" -Action list -ObjName "{OBJ}" -ObjType "{OBJTYPE}" -OutFile "{RUN_TEMP}\version_list.tsv"
```

- Parse the `VER:` lines into a table: **VERSNO · active · released · author ·
  date · time · TR · TR-status · TR-func**, and the `STATUS: OK n=… numbered=…
  last_released=… via=…` tail. `via=vrsd` means the SVRS FM fell back to a raw
  VRSD read (still valid).
- `STATUS: VH_NO_VERSIONS` → report honestly ("no transported version history yet
  — versions are written on release/generation") and stop (log `SUCCESS`). This is
  a legitimate state for a freshly built object, **never** rendered as an error or
  "no differences".
- `STATUS: RFC_LOGON_FAILED` / `RFC_ERROR` → surface + stop with the manual hint
  (run `/sap-login`, or use SE38/SE37 → Utilities → Versions in the GUI).
- **TR-status honesty**: `trstatus=UNKNOWN` means the version's originating TR is
  not in this system's E070 (e.g. objects imported from an upstream system —
  common on QA/PRD/ECC); report it as UNKNOWN, never as released.

For `list` mode, apply `--max` when rendering (show newest N numbered + the active
row), register (Step 6), and finish.

---

## Step 4 — diff

1. Choose the two versions:
   - `diff <OBJ> <A> <B>` → those two `VERSNO`s.
   - `diff <OBJ>` (no versnos) → the **two newest numbered** versions from Step 3.
     If only one numbered version exists → `VH_NO_VERSIONS`-style "only one stored
     version; nothing to diff" and stop.
2. Fetch each side to `{RUN_TEMP}`:
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\vh_rfc_run.ps1" -Action fetch -ObjName "{OBJ}" -ObjType "{OBJTYPE}" -Versno <A> -OutFile "{RUN_TEMP}\v<A>.abap"
   ```
   `STATUS: VH_VERSION_NOT_FOUND` for either side → stop with that class (the
   version isn't in the store).
3. Unified diff (offline, no tokens):
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_text_diff.ps1" -LeftFile "{RUN_TEMP}\v<A>.abap" -RightFile "{RUN_TEMP}\v<B>.abap" -OutFile "{ARTIFACT}\diff_<A>_vs_<B>.diff" -LeftLabel "v<A>" -RightLabel "v<B>"
   ```
   Read the `DIFF: added=… removed=… hunks=…` (or `DIFF: identical`) line.
   **`identical` is a real, common answer** (an object re-released across TRs
   without a source change) — report it plainly, not as a failure.
4. Unless `--no-annotate`, **Read the `.diff` file and write `diff_summary.md`**
   in the artifact dir: what changed (structural summary), the likely intent, and
   risk flags (auth checks, DB writes, commit/rollback, hard-coded values). Ground
   every claim in the diff; add nothing not visible in it.

---

## Step 5 — blame

1. From Step 3, take the newest `--window` (default 10, cap 25) numbered versions.
   Set `HasOlder` = there are more numbered versions than the window.
2. Fetch each to `{RUN_TEMP}\v<N>.abap` (as in Step 4.2), newest first.
3. Run the offline blame engine:
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_version_blame.ps1" -Files "<newest>=<path>,...,<oldest>=<path>" -MetaTsv "{RUN_TEMP}\version_list.tsv" -OutTsv "{ARTIFACT}\blame.tsv" -OutAnnotated "{ARTIFACT}\blame_annotated.txt" [-HasOlder]
   ```
   Read `BLAME: lines=… versions=… older_than_window=…`.
4. Render a rollup in chat: lines per author, per TR, and how many are
   `OLDER_THAN_WINDOW` (honestly: "attribution older than the N-version window;
   raise `--window` to go deeper").

---

## Step 6 — Register artifacts

Register each output produced (dot-source `sap_artifact_lib.ps1` and call
`Register-SapArtifact -Skill sap-version-history -ScopeKey (New-SapScopeKey …)
-Kind <kind> -Format <fmt> -Path <p> -Coverage CHECKED -Rows <n>`):

| File | Kind |
|---|---|
| `version_list.tsv` | `version-list` |
| `diff_<A>_vs_<B>.diff` + `diff_summary.md` | `version-diff` |
| `blame.tsv` + `blame_annotated.txt` | `version-blame` |

Use `-Coverage COULD_NOT_CHECK` if any FM fetch degraded (never a fabricated
result). No gate verdict — these are analytical outputs.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_version_history_run.json" -Status <SUCCESS|FAILED> -ExitCode <0|1> [-ErrorClass <CLASS> -ErrorMsg "<short>"]
```

`error_class` values (in `shared/rules/error_classes.md`): `VH_NO_VERSIONS`,
`VH_VERSION_NOT_FOUND`, `VH_TYPE_UNSUPPORTED`; plus infra `RFC_LOGON_FAILED` /
`RFC_ERROR`.

---

## Safety & gates (summary)

- **Rule 1** — read-only; version content via SVRS FMs, never SQL/`RFC_READ_TABLE`
  on the version tables.
- **Rule 2** — deploys nothing (no consent gate needed in v1).
- **Fail-loud (Rule 10)** — `VH_NO_VERSIONS` (empty store), `VH_VERSION_NOT_FOUND`
  (out-of-range versno), `VH_TYPE_UNSUPPORTED` (class/interface), NOT_FOUND /
  AMBIGUOUS object; a degraded FM fetch is `COULD_NOT_CHECK`, never an empty/false
  diff. `trstatus=UNKNOWN` is disclosed, never shown as released.

## Limitations

- **`--active` / `--last-released` (diff against the live source) are v1.1** —
  they need the active source read via `Read-SapAbapSource` (RPY) wired in; v1
  diffs stored-version-vs-stored-version only (explicit pair, or the newest two).
- **Classes / interfaces are v2** (per-include CPUB/CPRO/CPRI/method versioning) →
  `VH_TYPE_UNSUPPORTED` in v1.
- **`restore` is phase 2** — confirm-gated, delegating the deploy to /sap-se38 //
  sap-se37 (which own activation + TR resolution via /sap-transport-request).
- **Dev-system sparseness** — versions are written only on release/generation, so
  a freshly built Z object can legitimately have zero versions (`VH_NO_VERSIONS`),
  and consecutive versions are often byte-identical (re-released without change) →
  `diff` reports `identical` honestly.
- **Single code path on ECC 6 and S/4HANA** — all SVRS FMs are RFC-enabled and
  behave identically on both (verified S4D 1909 + EC2/ERP ECC 6, 2026-07-11); no
  release-variant handling.
- A future consolidation could host `sap_text_diff.ps1` as a shared unified-diff
  engine (and upgrade /sap-compare's set-diff onto it); kept skill-local for now.
