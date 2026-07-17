# SAP Forms Skill

Makes SAP forms legible to the suite: **SmartForms, SAPscript, and Adobe
forms**. `inventory` enumerates all three families (STXFADM SmartForms, TADIR
SAPscript/Adobe) with namespace/package filters and overlays the TNAPR
output-determination assignment (output types, channels, driver program,
routine) plus NAST usage counts in a date window — real usage evidence for
`/sap-cc-*` scope decisions instead of anecdotes. `download` + `explain`
export a form and parse it into a navigable page/window/text/code/condition
node tree (or SAPscript ITF into windows/formats/elements), with `--spec`
emitting a sap-docs work folder for re-implementation campaigns. `test-print`
delegates to `/sap-run-report` + `/sap-sp02`.

**Read-only except the confirm-gated report executions; no new Z objects.**

## Skill Overview

1. `inventory [--type all|smartforms|sapscript|adobe] [--namespace Z,Y | --all]
   [--packages ..] [--usage-days N] [--no-usage]` — RFC inventory →
   `forms_inventory.tsv` with TNAPR/NAST overlay
2. `download smartform <N>` — exports the XML via the SMARTFORMS
   Utilities→Download GUI menu (no FM route exists — `SSF_DOWNLOAD_FORM` is
   absent on both verified releases)
3. `download sapscript <N>` — exports ITF via `RSTXSCRP` (confirm-gated
   report execution)
4. `inspect adobe <N>` — readable Adobe metadata (TADIR + TNAPR usage); the
   FP* layout tables are NOT RFC-readable, so interface/context/layout report
   `COULD_NOT_CHECK` and there is no XDP extraction
5. `explain <kind> <N> [--spec]` — offline parse of a downloaded form into a
   node tree; `--spec` emits a sap-docs work folder
6. `test-print driver <PROG>` / `test-print nast <KAPPL> <KSCHL> <OBJKY>` —
   delegated to `/sap-run-report` + `/sap-sp02`

## Safety Gates

- Read modes (`inventory` / `inspect` / `explain` / `download smartform`)
  skip the confirmation gate.
- `download sapscript` (RSTXSCRP executes) and `test-print *` are
  **confirm-gated** (report execution).
- `test-print nast` pre-reads the single NAST row and **refuses a wildcard or
  missing OBJKY**; when the row's channel is `NACHA != 1` (not print), it
  additionally requires a **typed `REPROCESS`** confirmation before running
  `RSNAST00`.

## Auto-Trigger Keywords

- `forms inventory`, `list smartforms`, `which forms are used`
- `download smartform <name>`, `export sapscript <name>`
- `explain smartform <name>`, `inspect adobe form <name>`
- `test print <program>`, `reprint output for <key>`

## Usage

```text
/sap-forms inventory --type all --namespace Z,Y --usage-days 90
/sap-forms download smartform ZSF_INVOICE
/sap-forms download sapscript ZMEDRUCK
/sap-forms inspect adobe ZPDF_PO
/sap-forms explain smartform ZSF_INVOICE --spec
/sap-forms test-print driver ZPRINT_PROG
/sap-forms test-print nast EF NEU 4500000123
```

## Prerequisites

- Pinned RFC profile via `/sap-login`; SAP NCo 3.1 (32-bit) in GAC
- Active SAP GUI session for the download modes
- `/sap-dev-init` only for the v1.5 wrapper-FM enrichment (best-effort; the
  skill SKIPs with a prompt when the wrapper is absent — never auto-deploys)

## Directory Structure

```text
sap-forms/
├── SKILL.md                                  # Skill definition (single source of truth)
└── references/
    ├── sap_forms_inventory.ps1               # Forms inventory + TNAPR/NAST overlay (RFC)
    ├── sap_forms_fp_inspect.ps1              # Adobe inspect (TADIR + usage)
    ├── sap_forms_parse.ps1                   # Offline form parser (node tree)
    ├── sap_forms_sf_download.vbs             # SmartForm XML download (SMARTFORMS menu, GUI)
    └── sap_forms_sf_download.screens.json    # Golden-screen baseline (NEEDS_RECORDING rails)
```

## Limitations

- **Adobe FP* tables (FPLAYOUT / FPINTERFACE / FPCONTEXT) are NOT
  RFC-readable** (RAWSTRING columns) — proven live; `inspect adobe` reports
  interface/context/layout as `COULD_NOT_CHECK` and does no XDP extraction.
- **No SmartForm download FM exists** — the XML export is GUI-menu-only. The
  SMARTFORMS Utilities→Download menu position is release-specific and ships
  `NEEDS_RECORDING`-guarded: record it once via `/sap-gui-probe --record`, set
  `%%MENU_PATH%%`, retry.
- A usage column that cannot be read is reported `COULD_NOT_CHECK` /
  `>=N (capped)` — never "unused".
- Live-verified on S4D (S/4HANA 1909): inventory (11,134 forms), TNAPR+NAST
  overlay, explain, inspect adobe. The GUI download legs need a session and
  were not run autonomously. ECC 6 shares the identical path.
- Deferred: wrapper-FM enrichment in `explain` (v1.5); `patch smartform`
  text-node/condition edits (v2).

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
