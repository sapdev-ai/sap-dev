# SAP Enhancement Advisor Skill

Finds the safest extension point for a requested SAP behavior change and
recommends which enhancement mechanism to use — so a project doesn't fail by
modifying the wrong place (copying standard, editing a fragile exit, missing
the right BAdI). Complements `/sap-se19` (which IMPLEMENTS a BAdI) and
`/sap-cmod`: this skill DECIDES. Read-only; never modifies SAP.

## Skill Overview

1. Parse the target — three auto-detected modes:
   - **BAdI / enhancement spot** (`BADI <name>`) — classify
     classic/new/migrated + list existing implementations
   - **SMOD enhancement** (`ENHANCEMENT <smod>` / `SMOD <name>`) — components
     + the CMOD projects using it
   - **Program / tcode** (`PROGRAM <p>` / `TCODE <t>` / bare name) — enumerate
     candidates (enhancement spots, referenced BAdIs, user-exit includes)
2. Run the advisor engine (32-bit PowerShell, RFC via the pinned profile)
3. Score candidates with a transparent heuristic: released enhancement
   interface > BAdI > exit > implicit; standard modification is avoided
4. Present the recommendation, the full candidate table (so you can
   override), existing implementations (EXTEND vs. CREATE — it always asks
   before creating and never auto-suffix-bumps a name), and risk flags
5. Hand off: BAdI → `/sap-se19`, SMOD exit → `/sap-cmod`, user-exit include →
   `/sap-se38`; then `/sap-impact-analysis` before changing behavior. Outputs
   are registered in the artifact index for `/sap-evidence-pack`

An optional trailing quoted string is the **business intent** — it is echoed
in the report but does NOT change the ranking (the ranking is structural).

## Auto-Trigger Keywords

- `where should I enhance <program/tcode>`, `find a badi for <tcode>`
- `which user exit for <transaction>`, `enhancement point for <program>`
- "safest way to add a check before PO save"

## Usage

```text
/sap-enhancement-advisor BADI ME_PROCESS_PO_CUST
/sap-enhancement-advisor ENHANCEMENT MM06E005
/sap-enhancement-advisor PROGRAM SAPMV45A
/sap-enhancement-advisor TCODE ME21N "validate PO item before save"
```

Conversational forms:

- "Where is the safest place to validate the PO item before save in ME21N?"
- "Classify BAdI ME_PROCESS_PO_CUST and list its implementations"
- "Which CMOD projects use enhancement MM06E005?"

Engine outputs `candidates.tsv`, an implementations/risk TSV set, and a
Markdown report; exit `0` = ok, `1` = context not found, `2` = RFC failure.

## Prerequisites

- SAP profile saved via `/sap-login` (RFC password required)
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC

## Directory Structure

```
sap-enhancement-advisor/
├── SKILL.md
├── README.md
└── references/
    └── sap_enhancement_advisor.ps1   # the advisor engine (RFC, 32-bit PS)
```

## Limitations

- **The ranking is structural/heuristic, not semantic** — always verify the
  recommended interface's method signature actually exposes the data your
  intent needs.
- **Program/tcode enumeration is non-exhaustive** — implicit enhancements,
  dynamically-called BAdIs, and the full SMOD-for-transaction list are not
  covered; SE84/SE81 is the exhaustive tool. A `PARTIAL:` line names any
  tables that could not be read.
- **Never modifies SAP** — never creates an implementation, never auto-names;
  implementation is handed to `/sap-se19` / `/sap-cmod` / `/sap-se38`.
- BAdI and SMOD inspection reuse verified table knowledge from `/sap-se19`
  and `/sap-cmod`; the program-mode candidate list is best-effort.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
