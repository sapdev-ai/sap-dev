---
name: sap-check-fix
description: |
  Routes "check and fix" / "check" / "fix" requests for an existing SAP object to
  the correct workbench skill (sap-se38, sap-se37, sap-se24, or sap-se11) based
  on an explicit object-type keyword in the user's request. When no keyword is
  given, probes SE38 → SE37 → SE24 → SE11 (table → data type → domain) via the
  Display button to auto-detect the object type, then dispatches.

  Invoke when the user says any of:
    - "check and fix <kind> <name>"
    - "check <kind> <name>"
    - "fix <kind> <name>"
  where <kind> is one of: report / program / pgm, function module / fm,
  class / interface / method, dictionary / ddic / table / structure / view /
  data element / domain / table type / type group / search help / lock object,
  or omitted entirely.

  Prerequisites: Active SAP GUI session (use /sap-login first). Does not deploy
  new objects — the target object must already exist in the SAP system.
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

## Step 0 — Resolve Work Directory

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>` to the plugin root, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`, `custom_url`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp`

Ensure the temp directory exists:
```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

---

## Step 0.5 — Start Logging

Start a structured log run. The helper persists `run_id` in a state file
(`{WORK_TEMP}\sap_check_fix_run.json`) so subsequent steps and the final
log-end call append to the same run. Best-effort: silently no-ops if
`userConfig.log_enabled=false` or the lib can't load.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_check_fix_run.json" -Skill sap-check-fix -ParamsJson "{\"request\":\"<REQUEST>\"}"
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

If a keyword was found, **skip Step 2** and jump to **Step 3**.

If no keyword was found (user said only "check and fix `<NAME>`" / "check `<NAME>`" / "fix `<NAME>`"), continue with **Step 2 — Probe**.

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

For each step (using SE38 as the example), generate a per-probe PS1, run it, then run cscript. Use the absolute path of the sibling skill's `references/` directory by going up 1 level from `<SKILL_DIR>` to the `skills/` folder.

```powershell
# Example for probe 1 (SE38):
$content = Get-Content '<SKILL_DIR>\..\sap-se38\references\sap_se38_check.vbs' -Raw
$content = $content -replace '%%PROGRAM_NAME%%','THE_OBJECT_NAME'
Set-Content '{WORK_TEMP}\sap_check_fix_probe_se38.vbs' $content -Encoding Unicode
```

Then:
```bash
powershell -ExecutionPolicy Bypass -File "{WORK_TEMP}\sap_check_fix_probe_se38.ps1"
cscript //NoLogo "{WORK_TEMP}\sap_check_fix_probe_se38.vbs"
```

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
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_check_fix_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_check_fix_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
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
