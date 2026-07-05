---
name: sap-check-fix
description: |
  Routes "check and fix" / "check" / "fix" requests for an EXISTING SAP object to
  the correct workbench skill (sap-se38 / sap-se37 / sap-se24 / sap-se11) by an
  explicit object-type keyword, or — when no keyword is given — auto-detects the
  type by probing SE38 → SE37 → SE24 → SE11 (Display), then dispatches in
  check-and-fix mode. If the object matches an SAP-enhancement-component pattern
  (function-exit FM EXIT_SAP*, exit include ZX*, table-enhancement CI_*, SAPLX*
  screen exit), it is confirmed via MODSAP and routed to /sap-cmod instead (which
  edits the correct underlying object — for a function exit the ZX* customer
  include, never the standard FM — and re-activates the CMOD project). Invoke on
  "check and fix / check / fix <kind> <name>" where <kind> is report/program, FM,
  class/interface, a DDIC type, or omitted.
  Prerequisites: active SAP GUI session (/sap-login first). Does not deploy new
  objects — the target must already exist.
argument-hint: "[<kind>] <object-name>"
---

# SAP Check & Fix Router Skill

You route a "check and fix" request to the correct underlying workbench skill
based on the object kind the user named, or by probing the system when the
user gave only an object name.

This skill never modifies source on its own — it dispatches to the relevant
skill (`sap-se38`, `sap-se37`, `sap-se24`, `sap-se11`) in **check-and-fix mode**
(no source file argument), which opens the object, runs syntax check, downloads
the source, fixes detected errors, re-uploads, and activates.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — this skill dispatches to GUI-driving skills (sap-se38, sap-se37, sap-se24, sap-se11) which must observe the rule |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — this router dispatches to skills that touch ABAP source (sap-se38/37/24) and to the check/fix loop (sap-check-abap → sap-fix-abap), so the quality bar applies end-to-end |

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{RUN_TEMP}\sap_check_fix_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_check_fix_run.json" -Skill sap-check-fix -ParamsJson "{\"request\":\"<REQUEST>\"}"
```

---

## Step 1 — Parse Request

Extract two things from `$ARGUMENTS`:

1. **Object kind keyword** (optional)
2. **Object name** (always required, force UPPERCASE for SAP)

Match the keyword case-insensitively against this table; on hit, jump
straight to the matching skill in **Step 3**:

| Keyword(s) in request | Target skill | SE11 object type (if applicable) |
|---|---|---|
| `report`, `program`, `pgm`, `executable`, `include`, `module pool`, `subroutine pool` | `sap-se38` | — |
| `function module`, `function`, `fm` | `sap-se37` | — |
| `class`, `interface`, `method` | `sap-se24` | — |
| `table` (alone), `database table`, `transparent table` | `sap-se11` | `TABLE` |
| `view` | `sap-se11` | `VIEW` |
| `structure` | `sap-se11` | `DATATYPE` |
| `data element`, `dataelement`, `dtel` | `sap-se11` | `DATATYPE` |
| `table type`, `tabletype`, `ttyp` | `sap-se11` | `DATATYPE` |
| `type group`, `typegroup`, `tygr` | `sap-se11` | `TYPEGROUP` |
| `domain`, `doma` | `sap-se11` | `DOMAIN` |
| `search help`, `searchhelp`, `shma` | `sap-se11` | `SEARCHHELP` |
| `lock object`, `lockobject`, `enqu` | `sap-se11` | `LOCKOBJECT` |
| `dictionary`, `ddic` *(no specific subtype)* | `sap-se11` | *(probe DDIC subtypes — see Step 2.SE11)* |

Notes:
- For `class XXX` / `interface XXX` → pass `XXX` to `sap-se24`.
- For `method CLASS=>METH` or `method CLASS->METH` → pass the class part (`CLASS`) to `sap-se24`; SE24's editor exposes the method.
- If keyword and name cannot be separated cleanly, treat the last whitespace
  token as the object name and everything before it as the kind hint.

**Before any dispatch**, always apply **Step 1.5 — Enhancement Component
Detection** first (it runs on both the keyword and no-keyword paths).

If Step 1.5 does not divert to `/sap-cmod`:
- If a keyword was found, **skip Step 2** and jump to **Step 3**.
- If no keyword was found (user said only "check and fix `<NAME>`" / "check
  `<NAME>`" / "fix `<NAME>`"), continue with **Step 2 — Probe**.

---

## Step 1.5 — Enhancement Component Detection (route to /sap-cmod)

Some objects are **components of an SAP enhancement** and must be handled by
`/sap-cmod`, not edited in isolation — because (a) a function-exit module
`EXIT_SAP*` is SAP-standard and must **never** be edited directly (you edit its
customer `ZX*` include), and (b) editing any enhancement component requires
**re-activating the enclosing CMOD project** afterward, or the exit never fires.

Trigger this step when the object name matches an enhancement-component prefix:

| Object (workbench) | Name prefix | Notes |
|---|---|---|
| Program (SE38) | `ZX*` | exit-function-group customer include |
| Function module (SE37) | `EXIT_SAP*` | function exit — edit its `ZX*` include, not the FM |
| DDIC structure (SE11) | `CI_*` | table / append enhancement |
| Screen (SE51) | program `SAPLX*` (+ dynpro) | screen exit — pass `<program> <dynpro>` |

Confirm membership and resolve the owning enhancement via the sap-cmod RFC
helper (**32-bit PowerShell** — NCo is 32-bit):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\..\sap-cmod\references\sap_cmod_query.ps1" -Action find-enhancement -Component <NAME> [-Dynpro <nnnn>]
```

Parse the result:
- `ENHANCEMENT_COMPONENT: YES` (plus `ENHANCEMENT: <ENH>`, `TYP`, `MEMBER`) →
  **delegate to `/sap-cmod`** and STOP (do not run Step 2/3). Invoke, e.g.:
  > `/sap-cmod edit component <NAME> of enhancement <ENH>`

  `/sap-cmod` (Step 12) resolves the actual editable object — for `TYP=E` that
  is the `ZX*` customer include, **not** the `EXIT_SAP*` FM — dispatches to the
  correct workbench skill in **check-and-fix mode** (no source file), then
  resolves and activates the enclosing CMOD project (`find-project` → Step 8).
- `ENHANCEMENT_COMPONENT: NO` → not an enhancement component; fall through to the
  normal keyword routing (Step 1 table) or probe (Step 2).

If the object name has **no** enhancement-component prefix (and no SAPLX* screen
was named), skip this step entirely.

---

## Step 2 — Probe (only when no kind keyword was given)

Probe in this order, stopping at the first hit:

| Order | Probe via | If `EXIST` → dispatch to |
|---|---|---|
| 1 | `sap-se38/references/sap_se38_check.vbs` (program in TRDIR) | `sap-se38` |
| 2 | `sap-se37/references/sap_se37_check.vbs` (FM via SE37 Display) | `sap-se37` |
| 3 | `sap-se24/references/sap_se24_check.vbs` (class via SE24 Display) | `sap-se24` |
| 4 | `sap-se11/references/sap_se11_check.vbs` with `OBJECT_TYPE=TABLE` | `sap-se11` (TABLE) |
| 5 | `sap-se11/references/sap_se11_check.vbs` with `OBJECT_TYPE=DATATYPE` | `sap-se11` (DATATYPE — covers data element / structure / table type) |
| 6 | `sap-se11/references/sap_se11_check.vbs` with `OBJECT_TYPE=DOMAIN` | `sap-se11` (DOMAIN) |

Each check VBScript prints `EXIST` or `NOT_EXIST` (or `ERROR:`) on the last line.

### Probe driver

For each step (using SE38 as the example), write a per-probe PS1 to `{RUN_TEMP}`, run it (it materializes the `.vbs`), then run the `.vbs` with 32-bit cscript. Use the absolute path of the sibling skill's `references/` directory by going up 1 level from `<SKILL_DIR>` to the `skills/` folder.

The sibling `sap_*_check.vbs` templates all declare `Const SESSION_PATH = "%%SESSION_PATH%%"` and `ExecuteGlobal`-include `%%ATTACH_LIB_VBS%%` (parallel-safe attach). **Both tokens MUST be substituted** — leaving `%%ATTACH_LIB_VBS%%` in place makes the FSO include try to open a file literally named `%%ATTACH_LIB_VBS%%` and the probe crashes before it reaches SAP.

Write `{RUN_TEMP}\sap_check_fix_probe_se38.ps1`:
```powershell
# Example for probe 1 (SE38):
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\..\sap-se38\references\sap_se38_check.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%PROGRAM_NAME%%','THE_OBJECT_NAME'
# Session-attach plumbing (mandatory — the check.vbs includes the attach lib).
$content = $content -replace '%%SESSION_PATH%%', ''
$content = $content -replace '%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_check_fix_probe_se38.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

Then run the PS1 (writes the VBS) and execute the VBS:
```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\sap_check_fix_probe_se38.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo "{RUN_TEMP}\sap_check_fix_probe_se38.vbs"
```

For probes 2–6 use the sibling template and its own token(s) (SE37 `%%FM_NAME%%`, SE24 `%%CLASS_NAME%%`, SE11 `%%OBJECT_TYPE%%` + `%%OBJECT_NAME%%`) plus the same two session-attach substitutions above, writing to `sap_check_fix_probe_<se37|se24|se11>.ps1` / `.vbs`.

Token names per probe:

| Probe | Token(s) to replace |
|---|---|
| SE38 | `%%PROGRAM_NAME%%` |
| SE37 | `%%FM_NAME%%` (verify the actual token name in `sap_se37_check.vbs`) |
| SE24 | `%%CLASS_NAME%%` (verify the actual token name in `sap_se24_check.vbs`) |
| SE11 | `%%OBJECT_TYPE%%`, `%%OBJECT_NAME%%` |

Read each check VBS's header comment to confirm the exact token names before generating the PS1 (token names are documented at the top of every check script).

If all 6 probes return `NOT_EXIST`, stop and tell the user:
> "Object `<NAME>` was not found as a program (SE38), function module (SE37), class (SE24), table / data type / domain (SE11). Please specify the object kind explicitly, e.g. `/sap-check-fix <kind> <NAME>`."

If any probe returns `ERROR:`, surface the full output and stop — do not silently fall through to the next probe (an `ERROR` usually means SAP GUI is not attached or the user is not logged in).

---

## Step 3 — Dispatch

Hand off to the matched skill in **check-and-fix mode** by invoking it with
the object name and **no source file**:

| Target skill | Invocation |
|---|---|
| sap-se38 | `/sap-se38 <NAME>` |
| sap-se37 | `/sap-se37 <NAME>` |
| sap-se24 | `/sap-se24 <NAME>` |
| sap-se11 (TABLE / VIEW / DATATYPE / DOMAIN / TYPEGROUP / SEARCHHELP / LOCKOBJECT) | `/sap-se11 <SE11-TYPE> <NAME>` |

The downstream skill performs:
1. Display the object.
2. Run syntax / consistency check.
3. Download the source / definition.
4. Apply fixes for any errors detected.
5. Re-upload and activate.

Forward the downstream skill's outcome to the user verbatim.

---

## Step 4 — Summary

Report:
```
sap-check-fix
=============
Object name : <NAME>
Routed to   : <skill> [<SE11-type if applicable>]
Detection   : explicit keyword | probe (step <n>)
Outcome     : <forwarded from downstream skill>
```

If detection failed in Step 2, list which probes were attempted and their results.

---

## Final — Log End

Log the run-end record. Best-effort: silently no-ops if logging disabled.
On success:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_check_fix_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_check_fix_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `CHECK_FIX_FAILED`, `DISPATCH_FAILED`.

---

## Notes & Limitations

- This skill never **creates** new objects. If the target does not exist, it
  reports the miss and stops — use the relevant skill (`/sap-se38`, `/sap-se37`,
  `/sap-se24`, `/sap-se11`) directly to create.
- For `method <CLASS>=><METH>` requests, the underlying SE24 fix opens the full
  class; the user can then locate the method in the editor.
- Probe order matters: a name that exists as both a program and a function
  module (rare) will be treated as a program. To override, pass the kind
  keyword explicitly.
- DDIC probe covers only the most common subtypes (TABLE, DATATYPE, DOMAIN).
  For VIEW, TYPEGROUP, SEARCHHELP, LOCKOBJECT, the user must give the keyword.
