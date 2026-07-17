# SAP Evidence Pack Skill

Generates a reviewer / customer / audit-ready **delivery evidence pack** from
the artifact index — answering "what did we change, how was it checked, and
why is it safe?". It does NOT run checks; it COLLECTS what the other
delivery-assurance skills (`/sap-transport-readiness`, `/sap-impact-analysis`,
`/sap-atc`, `/sap-check-abap`, `/sap-run-abap-unit`, …) already registered,
into one categorized pack folder with a human-readable `index.md`. Pure-local
and read-only with respect to SAP.

## Skill Overview

1. Determine the scope from the arguments: a TR, an object (`<TYPE> <NAME>`),
   a package, `--ticket <id>`, or `--since <date>`
2. For an **object** scope only, resolve the name to its canonical scope key
   (TADIR object code, e.g. `PROG_ZMMR001`) via the shared object resolver —
   one RFC call; TR / package / ticket / date scopes are fully offline
3. Run the pure-local pack assembler: query the artifact manifest
   (`Find-SapArtifacts`), copy the matching artifacts into the pack folder
4. Present `index.md`: executive summary, rolled-up verdict (NO_GO wins over
   GO_WITH_WARNINGS wins over GO), a contents table (which skill produced
   what, with verdicts and coverage), and — crucially — an honest **"Missing
   evidence"** section that states what was NOT produced instead of
   pretending everything was checked
5. For each gap, recommend the skill that would fill it (e.g. missing
   `atc_findings` → `/sap-atc <obj>`)

Engine exit: `0` = ok (even with 0 artifacts — it writes an honest "no
evidence" pack) · `2` = error.

## Auto-Trigger Keywords

- `evidence pack <TR>`, `delivery evidence for <object>`
- `build the audit pack`, `collect the release evidence`
- "what proof do we have that DEVK900123 is safe?"

## Usage

```text
/sap-evidence-pack DEVK900123
/sap-evidence-pack PROGRAM ZMMR001
/sap-evidence-pack PACKAGE ZHK_MM
/sap-evidence-pack --ticket SAP-4821
/sap-evidence-pack --since 2026-06-01
/sap-evidence-pack DEVK900123 --output D:\packs --include-logs
```

Conversational forms:

- "Build the evidence pack for transport DEVK900123"
- "Collect everything we checked on ZMMR001 for the reviewer"
- "What evidence exists for ticket SAP-4821?"

## Prerequisites

- The other delivery-assurance skills must have **run first** and registered
  their artifacts in the artifact index — the pack is only as complete as
  what was registered
- SAP NCo 3.1 (32-bit) is needed **only** when resolving an object name to a
  scope key; all other scopes need no SAP connection

## Directory Structure

```
sap-evidence-pack/
├── SKILL.md
├── README.md
└── references/
    └── sap_evidence_pack.ps1   # the pure-local pack assembler
```

## Limitations

- **Collects, does not check.** An empty index yields an honest "no
  evidence" pack — never a fabricated verdict. Do not read the pack as
  proof of coverage it does not claim.
- **Formats:** Markdown `index.md` + copied source artifacts (TSV/JSON/MD).
  HTML / PDF export, bilingual summaries, signed-approval section, and
  ticket-system upload are Phase 2.
- `--include-logs` pulls raw JSONL run logs only if they were registered as
  `raw_log` artifacts (off by default to keep packs lean).
- Artifacts referenced by the index but moved/deleted on disk are flagged as
  `missing_files` rather than silently skipped.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
