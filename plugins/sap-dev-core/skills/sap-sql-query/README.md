# SAP SQL Query Skill

Runs **one governed, read-only database JOIN/aggregate** over RFC and returns a
TSV with provenance — closing the gap that SE16N and `RFC_READ_TABLE`
(single-table only) leave, so "VBAK joined to VBAP where …" or "open orders by
plant" stop decaying into several exports plus manual Excel matching.
Natural-language mode resolves the question to real DDIC tables/fields via live
dictionary reads (never guessed) and shows the generated SQL with a
name→description provenance table before executing. Read-only; results are
capped at 10,000 rows.

## Skill Overview

1. Dispatch: NL question (default) | `--sql "<SELECT>"` | `install` | `status`
2. **Helper preflight** — probes for the Engine A helper FM; if missing,
   offers `install` or the `--low-fidelity` fallback
3. **NL resolution** (NL mode) — tables/fields resolved via DD02T / DD03 /
   DD04T RFC reads; the drafted SQL is shown with its provenance table first
4. **Whitelist validation (always)** — every accepted statement passes a
   deny-first parser: subqueries, UNION, INTO, writes, `MANDT`/`CLIENT
   SPECIFIED`, `FOR ALL ENTRIES`, comments, `;`, host variables are all
   rejected. `--dry-run` stops here showing SQL + decomposition
5. Execute on one of two engines behind the same whitelist:
   - **Engine A** — a one-time, consent-gated, Remote-Enabled helper
     (`Z_SQL_QUERY_RO`) whose clause-slot interface, server-side
     re-validation, per-table `VIEW_AUTHORITY_CHECK`, and hard caps make it a
     governed query path, not a generic SQL hole
   - **Engine B** — an explicit **LOW-FIDELITY** fallback (single-table
     `RFC_READ_TABLE`) for when the helper is absent and install is declined
     (e.g. a PRD security veto); joins/aggregates refuse loud
6. Render the TSV (UTF-8 BOM, provenance header: SQL, SID/client, engine,
   rowcount, truncation, elapsed, caps) and register it in the artifact index

## Auto-Trigger Keywords

- "join VBAK to VBAP where ...", "query across tables", `sql query`
- "open orders by plant", "count/sum/group by ... from <table>"
- combined table questions that a single SE16N export cannot answer

## Usage

```text
/sap-sql-query "open sales orders by plant with a credit block"
/sap-sql-query --sql "SELECT ... " --max-rows 500
/sap-sql-query --sql "SELECT ... " --dry-run
/sap-sql-query --sql "SELECT ... " --low-fidelity
/sap-sql-query install
/sap-sql-query status
```

`--max-rows` defaults to 1000 (hard cap 10000).

## Prerequisites

- Pinned RFC profile via `/sap-login` (no GUI session needed)
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC
- For Engine A: the dev-init function group — `install` deploys the helper
  into it via `/sap-se11` + `/sap-se37` behind a typed-SID confirmation

## Key Reference Files

| File | Purpose |
|---|---|
| `references/sap_sql_query_parse.ps1` | Whitelist validator + clause decomposition (Layer 1) |
| `references/sap_sql_query_parse.tests.ps1` | 26-case offline injection/acceptance corpus |
| `references/sap_sql_query_exec.ps1` | Engine A caller (deployed helper) + preflight |
| `references/sap_sql_query_lowfi.ps1` | Engine B (LOW-FIDELITY, no deploy) |
| `references/Z_SQL_QUERY_RO.abap` | Engine A FM source of record (deployed by `install`) |
| `references/ZSQLQ_CHUNK.tsv` · `ZSQLQ_CHUNK_TT.tsv` | SE11 definitions of the RFC-safe chunk structure + table type |

## Limitations / Safety

- **The verified security core is the whitelist parser** — a 26-case offline
  corpus passes (8 valid SELECTs accepted, 18 attacks rejected). Engine B and
  the Engine A `status` preflight are live-verified; the helper FM itself is
  deploy-to-verify (syntax-checked + activated at `install` time)
- Engine A types the result by the primary FROM table: single-table SELECTs
  return every requested field; a JOIN returns the primary table's columns
  (full join projection is a v1.5 item)
- Engine B is single-table only — a join/aggregate refuses loud and points at
  `install`; its output carries an `ENGINE=LOW_FIDELITY` banner
- The helper targets dev/QA — it must never be transported to PRD without the
  customer's security sign-off; Engine B is the PRD answer
- The FM source is 7.02-safe so one source activates on both ECC 6 and
  S/4HANA
- Roadmap: subqueries / LEFT OUTER JOIN in Engine B, foreign-key join
  advisor, `remove` (v1.5); saved query library, cross-system compare (v2)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
