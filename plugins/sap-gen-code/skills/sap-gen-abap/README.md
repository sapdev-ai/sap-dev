# Generate ABAP Skill

Generates ABAP source code from a process text file (`{doc_name}_process.txt`)
produced by `/sap-docs-extract`. Customer Brief-aware: reads
`customer_brief.md` to drive ABAP release / OOP scaffolding / performance
gate / authz / unit-test decisions.

## Skill Overview

1. Read `customer_brief.md` (per-project profile) and
   `abap_naming_rules.tsv` (variable naming prefixes, overridable per
   customer)
2. Parse the process text file: program info, field definitions, file mapping,
   validation rules, processing flow, fixed-value tables
3. Decide the artefact type from the program info:
   - **Dialog / Module Pool program**
   - **Report (帳票/バッチ)**
   - **Function module / RFC**
4. **Pre-fetch FM signatures** (Step 1.5): scan the spec for `CALL FUNCTION 'X'`
   mentions, fetch each via `RPY_FUNCTIONMODULE_READ_NEW`, cache per-system on
   disk so subsequent generations don't re-fetch. Eliminates AI-hallucinated
   parameter names. *Optional — skipped when RFC unavailable or
   `userConfig.fm_cache_enabled=false`.*
5. Generate the ABAP source applying:
   - Modern syntax for the customer brief's `abap_release` (e.g. inline DATA,
     CORRESPONDING #(...), VALUE #(), etc., when supported)
   - Customer naming prefixes (`lv_`, `gs_`, `lt_`, …) per
     `abap_naming_rules.tsv`
   - OOP scaffolds (local class with PUBLIC SECTION, exception classes,
     ABAP Unit shell)
   - Performance gates (avoid SELECT * loops, prefer FOR ALL ENTRIES /
     CDS views per release)
   - Authz hooks (`AUTHORITY-CHECK` for declared S_* objects)
   - **Real FM signatures from Step 4 take precedence over training-data guesses**
6. Offer to save, then write the generated source to `Z<PROGRAM_ID>.abap` in
   the work folder, plus sibling `Z<PROGRAM_ID>.deps.txt` /
   `.traceability.txt` / `.messages.txt` / `.text_elements.txt` files (and
   `Z<PROGRAM_ID>_TEST.abap` when unit tests are on)

## Auto-Trigger Keywords

- `generate abap`, `gen abap`, `produce abap from process text`
- `build report from spec`, `build dialog from spec`

## Usage

```text
/sap-gen-abap <path-to-process-txt>  [--refresh-cache]
```

Examples:

```text
/sap-gen-abap C:\sap_dev_work\source_code\work\Spec_20260501\Spec_process.txt
/sap-gen-abap C:\sap_dev_work\source_code\work\Spec_20260501\
/sap-gen-abap C:\sap_dev_work\source_code\work\Spec_20260501\ --refresh-cache
```

Flags:

- `--refresh-cache` — Bypass the FM signature cache for this run. Forces re-fetch
  of every FM via RFC. Use after modifying a `Z*` FM whose 1-day TTL hasn't expired
  yet, or when you suspect a stale cache is causing wrong code generation.

Conversational forms:

- "Generate ABAP from this work folder"
- "Build the report described in `Spec_process.txt`"
- "Produce a dialog program from the extracted spec"
- "Re-generate ABAP with fresh FM signatures" (triggers `--refresh-cache`)

## Prerequisites

- Run `/sap-docs-extract` first to produce `{doc_name}_process.txt`
- Recommended: run `/sap-docs-check` to catch unclear parts / DDIC issues before
  generation
- Customer Brief at `{custom_url}\customer_brief.md` (or shared default) —
  drives release / OOP / perf decisions

## Suggested next steps

After generation completes, chain into:

- `/sap-check-abap` — validate all dimensions (naming, types, SQL fields, CALL FUNCTION signatures, compiler syntax) against live SAP
- `/sap-fix-abap` — auto-patch detected issues (incl. CALL FUNCTION fixes + a bounded syntax loop)
- `/sap-se38` (or `/sap-se37` / `/sap-se24`) — deploy and activate
- `/sap-atc` — final quality gate

## Limitations

- Generated code is a **starting point**, not production-ready. Always run
  through validation, fix, ATC, and human review before deploying.
- Stub methods are emitted with `" TODO: Implement` markers for any flow
  step the spec describes only at a high level.
- Customer Brief is currently authoritative — if it's missing or empty, the
  skill asks before continuing and, on confirmation, falls back to safe
  defaults (classic ABAP, FORM routines, no unit tests, `$TMP` package).
  Fill out `<sap-dev-core>/shared/templates/customer_brief.md` and save it
  to `{custom_url}\customer_brief.md` to get release-aware modern ABAP /
  OOP / ABAP Unit generation.

## Version

- Skill Version: 1.1.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
