# SAP Compare Skill

Compares the SAME ABAP object across two SAP systems — the pinned connection
(LEFT) and a second saved profile selected with `--against <hint>` (RIGHT) —
and explains the differences. Use it for landscape drift ("works in QAS,
fails in DEV"), pre-transport sanity checks, and confirming an import landed.
Pure read-only on both systems.

## Skill Overview

1. Parse: object name + `--against <profile-hint>` (required) + optional
   `--type`, `--ddic` / `--source` mode override
2. Connect BOTH systems over RFC — LEFT from the pinned profile, RIGHT from
   the `--against` profile (ambiguous hints are refused loudly, never guessed)
3. Detect the object type on LEFT and pick the mode: DDIC objects (table /
   structure / data element / domain / table type) → field-by-field compare
   via `DDIF_FIELDINFO_GET`; programs / includes / FMs → source compare via
   RPY reads (`sap_rfc_read_source.ps1`)
4. Emit `diff.json` (structured field diff) or `diff.txt` (unified source
   diff) plus `left.def` / `right.def`
5. Synthesize `diff.md` — verdict, what differs, likely cause per difference
   (*real change* vs. *release skew*, using each system's saved
   `server_release_marker`), and a recommended action

The authoritative verdict is the `RESULT:` line: `IDENTICAL` / `DIFFERS` /
`COMPARE_UNAVAILABLE - <reason>`. A side that fails to read (`read_status:
FAILED`) or an object absent on both sides yields `COMPARE_UNAVAILABLE` —
never a false "identical".

## Auto-Trigger Keywords

- `compare <object> between <SID> and <SID>`, `diff <object> against <SID>`
- "works in QAS but fails in DEV", "did the import land in QAS?"
- `compare table ZHKTBL001 with QAS`, `diff program ZHKR001 against S4Q`

## Usage

```text
/sap-compare ZHKTBL001 --against S4Q
/sap-compare ZHKR001   --against S4Q/200/DEVELOPER --source
/sap-compare ZDOM_STATUS --against last --ddic
```

The `--against` hint accepts: a profile UUID, `last`, `default`, `<SID>`,
`<SID>/<CLIENT>/<USER>`, or a description substring.

Conversational forms:

- "Compare ZHKTBL001 between this system and QAS"
- "The report works in QAS but dumps in DEV — diff ZHKR001"
- "Verify the import: compare ZCL_HK_UTIL against the source system"

## Prerequisites

- BOTH systems saved via `/sap-login` (RFC password required) — under the
  **same Windows user**, because stored passwords are DPAPI-encrypted with
  CurrentUser scope
- RFC connectivity to both systems (`Connect-SapRfc` from the shared RFC
  library)

## Directory Structure

```
sap-compare/
├── SKILL.md
├── README.md
└── references/
    ├── sap_compare_ddic.ps1   # dual-connect DDIC fetch + structured field diff → diff.json
    └── sap_compare_diff.ps1   # normalize + unified text diff (source mode)
```

## Limitations

- **Read-only** — never modifies either system.
- **Class/interface source** is not comparable cross-system over RFC (ADT
  mode planned); DDIC and program/include/FM compares are fully supported.
- **Same-name assumption** in v1 — the object must be named identically on
  both sides (a future `--right-name` is planned).
- `reordered` fields in `diff.json` are informational, not a defect;
  append-structure ordering is normalized best-effort.
- Outputs land under the per-run scratch dir (`{RUN_TEMP}`), which is swept
  automatically — copy any `diff.md` you want to keep to a stable location.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
