# SAP Impact Analysis Skill

Pre-change / pre-release impact analysis — answers "**if I change this object,
what else might break?**" from SAP's system-maintained cross-reference index
(not by parsing source, and not by driving the slow GUI where-used). Resolves
the object, then gathers reverse dependencies (where-used), forward
dependencies (what it uses), runtime entry points (tcodes, jobs, variants,
RFC-enabled flag), and transport history. Computes a transparent
LOW / MEDIUM / HIGH risk band from where-used fan-out + the standard-object
flag, writes a markdown report + per-dimension TSVs + risk findings, and
registers them for `/sap-evidence-pack`. **Read-only** — RFC only, never
modifies SAP.

## Skill Overview

1. Parse the target: `<TYPE> <NAME>` (best signal), bare `<NAME>` (TADIR
   disambiguation), `TCODE <t>` (resolves the underlying program), or
   `TR <tr>` / `PACKAGE <pkg>` (expanded and analysed per object, capped —
   skips are logged, never silently truncated)
2. Run the cross-reference impact engine (32-bit PowerShell, RFC): reverse
   deps, forward deps, runtime entry points, transport history
3. Read the `IMPACT:` line — risk band + headline counts — and the markdown
   report; surface any `PARTIAL:` (could-not-check) dimensions
4. Report with two mandatory honesty caveats: incomplete dimensions are named,
   and the dynamic-dispatch blind spot is always disclosed
5. Recommend next steps: regression scope, `/sap-enhancement-advisor` for
   standard objects, `/sap-transport-readiness` / `/sap-evidence-pack`
   pre-release

## Auto-Trigger Keywords

- `impact analysis <name>`, `impact of changing <name>`
- `what breaks if I change table ZMM_ORDER`
- `who uses ZHKR001`, `where-used fan-out for FM Z_MM_POST`

## Usage

```text
/sap-impact-analysis TABLE ZMM_ORDER
/sap-impact-analysis PROGRAM ZMMR001
/sap-impact-analysis FM Z_MM_POST
/sap-impact-analysis TCODE ME21N
/sap-impact-analysis ZMMR001
/sap-impact-analysis TABLE ZMM_ORDER --high-fanout 80 --output C:\out
```

Conversational forms:

- "What would break if I change ZMM_ORDER?"
- "Run an impact analysis on ME21N before the release"

## Prerequisites

- SAP profile saved via `/sap-login` (RFC — creds resolve from the pinned
  profile)
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC

## Directory Structure

```text
sap-impact-analysis/
├── SKILL.md                          # Skill definition (single source of truth)
└── references/
    └── sap_impact_analysis.ps1       # The cross-reference impact engine (RFC)
```

The engine dot-sources the shared Phase-0 primitives (`sap_object_resolver.ps1`,
`sap_finding_lib.ps1`, `sap_artifact_lib.ps1`).

## Limitations

- **Direction coverage (MVP):** reverse where-used for table / global symbol /
  data element / domain / FM; forward (uses) for **programs** only.
- **Depth 1 only** (direct dependencies); transitive `--depth >1` is Phase 2.
- **Dynamic dispatch is invisible** to the cross-reference index (`CALL
  FUNCTION lv_name`, dynamic `SELECT`, `SUBMIT (rep)`) — always disclosed,
  never covered.
- Index tables (`D010TAB` / `D010INC` / `WBCROSSGT` / `CROSS` / `DD04L`) are
  authoritative for STATIC global references; the `OTYPE` / `TYPE` code values
  vary by release — reported, not hardcode-filtered.
- Include→program resolution is the cheap `D010INC` path; unresolved includes
  are reported by include name.
- The risk band is a transparent heuristic (fan-out bands + standard-object
  flag), not a guarantee — the dependency lists are the primary value.
- Read failures degrade to `COULD_NOT_CHECK`, never a silent gap or a false
  "clean".

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
