# SAP Fix FM Skill

Fix ABAP `CALL FUNCTION` parameter issues found by sap-check-fm. Renames wrong parameters, adds missing mandatory parameters, and moves parameters to the correct section — with a backup created before any changes.

## Skill Overview

This skill reads the result file produced by **sap-check-fm**, reconnects to SAP to fetch the authoritative FM parameter lists, then proposes and applies fixes to the ABAP source file:

- **RENAME** — `UNKNOWN_PARAM` entries: replaces the incorrect parameter name with the correct one by pairing it with the corresponding `MISSING_MANDATORY` entry or by fuzzy-matching against the FM's actual parameter list
- **ADD STUB** — `MISSING_MANDATORY` entries (not already paired with a rename): inserts a new parameter line under the correct section keyword with a `space   " TODO` placeholder
- **MOVE** — `WRONG_SECTION` entries: moves the parameter assignment from the wrong section keyword to the correct one

A timestamped backup (`.bak`) is always created before the source file is modified.

## Workflow

```
sap-check-fm → <abap-file>.check_fm.tsv → sap-fix-fm → patched ABAP source
```

Run sap-check-fm first, then pass the same ABAP file to sap-fix-fm.

## RFC Function Module Used

| RFC FM | Purpose |
|---|---|
| `RPY_FUNCTIONMODULE_READ_NEW` | Retrieve actual FM parameter lists for fix planning |

## Fix Logic

| Issue code | Fix applied |
|---|---|
| `UNKNOWN_PARAM` + paired `MISSING_MANDATORY` (same FM + section) | Rename old param name to correct mandatory param name |
| `UNKNOWN_PARAM` alone | Fuzzy-match against FM's actual params; confirm with user if ambiguous |
| `MISSING_MANDATORY` alone | Add stub parameter line with placeholder value |
| `WRONG_SECTION` | Move parameter assignment to correct section keyword |
| `FM_NOT_FOUND` | Skipped — FM does not exist in this SAP system |
| `TYPE_*` / `PARAM_NAME_OK` / `OK` | Not touched — type issues require manual correction |

## Auto-Trigger Keywords

- fix CALL FUNCTION parameters, fix ABAP FM parameters
- rename wrong parameter, add missing mandatory parameter
- fix unknown parameter ABAP, move parameter to correct section
- fix sap-check-fm issues, apply FM fixes, patch ABAP CALL FUNCTION

## Directory Structure

```
sap-fix-fm/
├── SKILL.md                        # Main skill workflow
└── README.md                       # This file
```

FM parameter signatures are fetched via the **shared** helper at
`<sap-dev-core>/shared/scripts/sap_rfc_lookup_fm.ps1` (with per-system
disk cache), reused across `sap-gen-abap`, `sap-check-fm`, and this skill.

## Usage

```
/sap-fix-fm C:\src\ZPROGRAM.abap DEV_100
```

Or with explicit result file:
```
/sap-fix-fm C:\src\ZPROGRAM.abap C:\src\ZPROGRAM.abap.check_fm.tsv DEV_100
```

Or:
- "Fix the CALL FUNCTION issues in ZPROGRAM.abap found by check-fm"
- "Apply FM parameter fixes to my ABAP source using the check result"
- "Rename wrong parameters and add missing mandatory params in ZPROGRAM.abap"

## Prerequisites

- **sap-check-fm** must have been run first to produce the result file
- SAP NCo 3.1 (32-bit, .NET 4.0) installed in GAC
- 64-bit Windows with `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` (standard on all 64-bit Windows)
- SAP user with `S_RFC` authorization for: `RPY_FUNCTIONMODULE_READ_NEW`

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-04-05

## License

GPL-3.0 — See LICENSE file in repository root.
