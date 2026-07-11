---
name: sap-sql-query
description: |
  Runs ONE governed, read-only database JOIN/aggregate over RFC and returns a TSV with
  provenance — closing the gap that SE16N and RFC_READ_TABLE (single-table only) leave, so
  "VBAK joined to VBAP where…", "open orders by plant with credit block" stop decaying into
  several exports + manual Excel matching. Natural-language mode resolves NL → DDIC
  tables/fields via live DD02T/DD03 reads (never guessed) and shows the generated SQL with a
  name→description provenance table before executing. Two engines behind one whitelist: Engine
  A — a one-time, consent-gated, Remote-Enabled helper (Z_SQL_QUERY_RO) whose clause-slot
  interface + server-side re-validation + per-table VIEW_AUTHORITY_CHECK + hard caps make it a
  governed query path, not a generic SQL hole; Engine B — an explicit LOW-FIDELITY fallback
  (single-table RFC_READ_TABLE) for when the helper is absent and install is declined (PRD /
  security veto). Every accepted statement passes a deny-first whitelist parser (subqueries,
  UNION, INTO, writes, MANDT/CLIENT SPECIFIED, FOR ALL ENTRIES, comments, `;`, host-vars all
  rejected). Read-only; caps ≤10000 rows. Prerequisites: pinned RFC profile via /sap-login;
  for Engine A the dev-init function group (install deploys the helper into it); NCo 3.1 (32-bit).
argument-hint: "\"<natural-language question>\" | --sql \"SELECT ...\" [--max-rows N] [--dry-run] [--low-fidelity] | install | status"
---

# SAP SQL Query Skill

You answer a data question with ONE governed, read-only SELECT — validated by a deny-first
whitelist, decomposed into clause slots, executed under caps + per-table auth, and returned
as a TSV with the SQL and its provenance. You never run a raw statement and never write.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_sql_query_parse.ps1` | `-SqlFile` | Whitelist validator + clause decomposition (Layer 1) |
| `<SKILL_DIR>/references/sap_sql_query_parse.tests.ps1` | offline | 26-case injection/acceptance corpus |
| `<SKILL_DIR>/references/sap_sql_query_exec.ps1` | `-Action status\|exec` | Engine A caller (deployed helper) + preflight |
| `<SKILL_DIR>/references/sap_sql_query_lowfi.ps1` | `-Table -Fields -Where` | Engine B (LOW-FIDELITY, no deploy) |
| `<SKILL_DIR>/references/Z_SQL_QUERY_RO.abap` | source of record | Engine A FM (deployed by `install`) |
| `<SKILL_DIR>/references/ZSQLQ_CHUNK.tsv` · `ZSQLQ_CHUNK_TT.tsv` | SE11 defs | The RFC-safe chunk structure + table type |
| `/sap-se37` · `/sap-se11` | sub-skills | `install` (they resolve the TR — this skill never touches TRs) |
| `/sap-login` | sub-skill | Session / pinned profile |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_sql_query_run.json`). Pure RFC — no GUI.

## Step 1 — Parse & Dispatch

`"<NL question>"` (default) | `--sql "<SELECT>"` | `install` | `status`. Clamp `--max-rows`
(default 1000, hard cap 10000) + `--timeout`. Pinned profile via `/sap-login`.

## Step 2 — Helper Preflight

```bash
... sap_sql_query_exec.ps1 -Action status
```

`SQLQ_HELPER_MISSING` → offer `install` (Step 3) or `--low-fidelity` (Engine B). Present +
remote → Engine A available.

## Step 3 — install (consent-gated)

**Typed confirm:** "Deploy 3 objects (Z_SQL_QUERY_RO, ZSQLQ_CHUNK, ZSQLQ_CHUNK_TT) to
`<SID>/<client>`? Type the SID to proceed." Then deploy `ZSQLQ_CHUNK` + `ZSQLQ_CHUNK_TT` via
`/sap-se11`, `Z_SQL_QUERY_RO.abap` via `/sap-se37` (+ change-attributes REMOTE); authoritative
re-read `TFDIR.FMODE='R'` + version ping. Install is its own run. Production: surface that
security review may veto — Engine B exists for exactly that.

## Step 4 — NL resolution (NL mode)

Resolve NL → tables/fields via DD02T (table texts) + DD03/DD04T (field + data-element texts)
RFC reads; draft the SQL; show it with the name→description provenance table.

## Step 5 — Validate (Layer 1, always)

Write the SELECT to `{RUN_TEMP}\query.sql` (a file — a `-Sql` CLI string loses inner `"`), then:

```bash
... sap_sql_query_parse.ps1 -SqlFile "{RUN_TEMP}\query.sql" -OutJson "{RUN_TEMP}\decomp.json"
```

`verdict=REJECT` → report the exact `reason`/`token` (`SQLQ_PARSE_REJECTED`); STOP. `--dry-run`
stops here showing the SQL + decomposition.

## Step 6 — Execute

- **Engine A** (helper present): `sap_sql_query_exec.ps1 -Action exec` with the decomposition
  clause slots (`-Fields -From -Where -GroupBy -Having -OrderBy -PrimaryTable=<tables[0]>
  -MaxRows`). `E_STATUS` A → `SQLQ_AUTH_REFUSED`, E → `SQLQ_EXEC_FAILED`; reassembles chunks → TSV.
- **Engine B** (`--low-fidelity` / helper absent + install declined): `sap_sql_query_lowfi.ps1
  -Table <tables[0]> -Fields <fields> -Where <where>`. Single-table only — a join/aggregate
  refuses loud (`SQLQ_LOWFI_UNSUPPORTED`) pointing at `install`. Banner `ENGINE=LOW_FIDELITY`.

## Step 7 — Render + Register

Write the TSV (UTF-8 BOM, `#` provenance header: SQL, SID/client, engine, rowcount, TRUNCATED,
elapsed, caps, helper version) + (NL mode) a `.provenance.md`. Register
(`Register-SapArtifact -Kind query_result`, coverage `CHECKED` / `COULD_NOT_CHECK` when Engine B
truncated). Preview table + the caveat banner.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class): `SQLQ_PARSE_REJECTED` / `SQLQ_NAME_UNKNOWN`
/ `SQLQ_AUTH_REFUSED` / `SQLQ_HELPER_MISSING` / `SQLQ_EXEC_FAILED` / `SQLQ_LOWFI_UNSUPPORTED` /
`RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **The verified security core is the whitelist parser** (Layer 1) — a **26-case offline corpus
  passes** (8 valid SELECTs accepted incl. joins/aggregates/IN/doubled-quote escape; 18 attacks
  rejected: semicolon, UNION, subquery, INTO, UPDATE/write, FOR ALL ENTRIES, CLIENT SPECIFIED,
  MANDT, BYPASSING, caller UP TO, backquote, host-var, hex, CONNECTION, DDL, `"`-comment,
  unbalanced quote, ROLLBACK). SQL is passed via `-SqlFile` (a `-Sql` CLI string silently loses
  inner `"`). **Engine B is live-verified** (single-table MARA SELECT with fields + WHERE + cap
  returned rows; join/aggregate refuse loud). **Engine A `status` preflight is verified**
  (helper-absent detection + install offer).
- **Engine A (Z_SQL_QUERY_RO) is deploy-to-verify:** the FM source ships as the source of record
  and is **syntax-checked + activated at `install` time** (via `/sap-se37` / `/sap-check-abap`) —
  it is not compiled in this build. Its containment (server-side forbidden-token re-scan,
  DD02L + `VIEW_AUTHORITY_CHECK` per table, ≤10000 clamp, clause-slot-only interface, no write
  statement anywhere) is defense-in-depth BEHIND the parser. It types the result itab by the
  primary FROM table (RTTS + `INTO CORRESPONDING FIELDS`): single-table SELECTs return every
  requested field; a JOIN returns the primary table's columns — for a full join projection use
  the helper's own join support once its per-field RTTS build lands (v1.5) or Engine B per table.
- **7.02-safe** so one FM source activates on ECC 6 (7.31) + S/4HANA; `VIEW_AUTHORITY_CHECK` +
  `DD02L` present on both per the plan's probe. **Security:** the helper targets dev/QA — it must
  never be transported to PRD without the customer's security sign-off (README); Engine B is the
  PRD answer. Reads run without confirmation (house precedent), but NL mode always shows the
  generated SQL first; `install` is typed-confirm-gated.
- **v1.5:** subqueries / LEFT OUTER JOIN in Engine B, DD08L foreign-key join advisor, `remove`
  (delete the 3 helper objects). **v2:** saved query library, cross-system compare.
