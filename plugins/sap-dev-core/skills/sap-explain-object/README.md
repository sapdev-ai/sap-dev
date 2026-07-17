# SAP Explain Object Skill

Read-only comprehension aid for an EXISTING ABAP object. Auto-detects the type
(program / include / function module / class) via RFC, acquires the active
source with its include tree, and builds a structure + call/data map — units,
PERFORM / CALL FUNCTION / CALL METHOD edges, DB read/write targets, SUBMIT /
CALL TRANSACTION, selection screen. Emits an explanation dossier
(`dossier.md`) plus a machine-readable `map.json`. **Never modifies SAP** —
pure read, no deploy, no activation, no edit.

With `--spec` the same comprehension base is upgraded into a **formal,
review-ready specification document** (Markdown, Word via `--format docx`, or
a filled `spec_template.xlsx` via `--format xlsx` that round-trips through
`/sap-docs-extract`) — the inverse of `/sap-gen-abap`'s spec-to-code flow.
Each section is marked **CONFIRMED** (read from the system) vs **INFERRED**
(reasoned). `--spec` folds in the former `/sap-document-object` skill.

## Skill Overview

1. Parse: object name + `--type` (default `auto`), `--callers`, `--no-gui`,
   `--depth N`, `--spec`, `--format md|docx|xlsx`, `--audience functional|technical`
2. Detect the object type over RFC (`TRDIR` / `TFDIR` / `SEOCLASS`; DDIC
   objects are redirected to `/sap-se11`)
3. Acquire source + includes — RFC (`Read-SapAbapSource`) for programs /
   includes / FMs; classes via the SE24 GUI download (skipped under `--no-gui`)
4. Build the structure / call map (`map.json`)
5. Optionally pull callers via the where-used list (`--callers`, needs GUI)
6. Synthesize `dossier.md`: purpose, flow walkthrough, data touched,
   dependencies, change-impact note, caveats
7. With `--spec`: enrich over RFC (DD02T table texts, DD03L keys, T100 message
   texts, AUTHORITY-CHECK objects) and render the spec deliverable

## Auto-Trigger Keywords

- `explain program ZHKR001`, `explain object <name>`
- `what does ZHK_GET_DATA do`, `how does class ZCL_HK_UTIL work`
- `document ZHKR001`, `generate a spec for ZHKR001`

## Usage

```text
/sap-explain-object ZHKR001
/sap-explain-object ZHK_GET_DATA --type fm
/sap-explain-object ZCL_HK_UTIL --type class --callers
/sap-explain-object ZHKR001 --no-gui --depth 5
/sap-explain-object ZHKR001 --spec --format docx --audience functional
```

Conversational forms:

- "Explain program ZHKR001"
- "What does function module ZHK_GET_DATA do?"
- "Write a spec document for ZHKR001 as Word"

## Prerequisites

- Pinned RFC connection (use `/sap-login` first); SAP NCo 3.1 (32-bit) in GAC
- Active SAP GUI session ONLY for class source download and `--callers`
- `anthropic-skills:docx` / `anthropic-skills:xlsx` for `--spec --format docx|xlsx`

## Directory Structure

```text
sap-explain-object/
├── SKILL.md                          # Skill definition (single source of truth)
└── references/
    └── sap_explain_parse.ps1         # Offline source -> map.json parser
```

Source acquisition, type probing, and enrichment reuse shared scripts
(`sap_rfc_read_source.ps1`, `sap_object_resolver.ps1`, `sap_rfc_lib.ps1`) plus
the SE24 / where-used VBS of the sibling skills.

## Limitations

- **Read-only by design** — never deploys, activates, or edits.
- DDIC objects (table / structure / data element / domain) are out of scope —
  redirected to `/sap-se11` display.
- Dynamic calls (`CALL FUNCTION lv_name`, `CALL METHOD (lv_meth)`) are not
  resolved — noted in the dossier. Macro-/generated-code parsing is best-effort.
- Class source over RFC is unsupported (until the planned ADT mode); the GUI
  download returns the pretty-printed *display* view — adequate for
  comprehension, flagged in the dossier.
- **`--spec` produces a DRAFT, not ground truth** — purpose and processing
  narrative are inferred and flagged; for human review, not sign-off without it.
- `--spec` DDIC / message enrichment is RFC-optional — a read failure degrades
  that section to `COULD_NOT_CHECK`, never a silent gap.
- `--spec --format xlsx` fidelity is best-effort — only sheets with a clear map
  source are filled; unmapped sheets are reported, never left looking complete.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
