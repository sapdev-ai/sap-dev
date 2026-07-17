---
name: sap-change-history
description: |
  Answers "who changed this object / this data, and when" headlessly over RFC — no more
  hand-joining CDHDR/CDPOS in SE16N and decoding cluster rows by eye. Resolves a business
  token (PO, customer, vendor, material, sales order, G/L account, cost center …) to its
  change-document class, scans CDHDR for the change headers, then pulls the fully DECODED
  field-level rows (table · field · old → new, with DDIC field labels) via CHANGEDOCUMENT_READ
  through the dev-init RFC wrapper — which sidesteps both the CDPOS 512-byte RFC_READ_TABLE
  limit and ECC-6's CDPOS cluster storage in one call. Renders an auditable timeline + an
  evidence-grade TSV, and (`--correlate`) time-orders the changes against transport imports
  and /sap-diagnose evidence so "TR imported → field changed 5 min later" reads as one story.
  Read-only; no writes, no SQL, no GUI. Also does `user <U>` / `window --from/--to` scans and
  a `classes` map dump. Prerequisites: pinned RFC profile via /sap-login; the dev-init wrapper
  Z_GENERIC_RFC_WRAPPER_TBL (via /sap-dev-init — never deployed by this skill); SAP NCo 3.1 (32-bit).
argument-hint: "<object> <key> [--from=YYYYMMDD] [--to] [--changenr=N] [--correlate] | user <U> [--from --to] | window --from=X [--to] [--class=C] | classes [--all]"
---

# SAP Change History Skill

You reconstruct a decoded, field-level change timeline for a business object (or a user /
time window) entirely over RFC, and never fabricate: an object with no change documents is
reported as such, and a decode that the object doesn't support is `CDH_NO_CHANGES`, never
"nothing changed".

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_change_history_rfc.ps1` | `-Action headers\|decode\|classes\|imports` | CDHDR scan · wrapper decode · TCDOB · E070 |
| `<SKILL_DIR>/references/sap_change_history_correlate.ps1` | offline | Time-order changes ⋈ imports ⋈ diagnose evidence |
| `<SKILL_DIR>/references/sap_change_history_objectclas_map.tsv` | map | Business token → OBJECTCLAS + key element (custom override honored) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | dot-sourced | NCo 3.1 connect/disconnect |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced | `Read-SapTableRows` (CDHDR/TCDOB/E070/DD03L/DD04T) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | Artifact registration + `Find-SapArtifacts` (correlate) |
| `/sap-login` · `/sap-dev-init` | sub-skills | Pinned RFC profile · deploys the wrapper (this skill never does) |

Custom map override: `{custom_url}\sap_change_history_objectclas_map.tsv` (same pattern as
`abap_naming_rules.tsv`). A raw `OBJECTCLAS:<class>` token bypasses the map for power users.

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_change_history_run.json`). Pure RFC — no GUI session.

## Step 1 — Parse & Dispatch

Modes: `object` (default: `<token> <key>`), `user <U>`, `window --from/--to`, `classes`.
`config <TABLE>` (DBTABLOG/SCU3) → **phase 2**, say not implemented + cite the roadmap, never
a partial read. Defaults: `--to`=today, `--from`=to−90d, `--max`=200, `--decode-max`=25 (cap 100).

## Step 2 — RFC Profile + Wrapper Preflight

Pinned RFC profile required (`/sap-login`) — missing → `RFC_LOGON_FAILED`, STOP. The `decode`
action self-checks the wrapper (TFDIR FMODE=R); absent → `CDH_WRAPPER_MISSING`, STOP, point to
`/sap-dev-init` (which owns the deploy consent — this skill never deploys).

## Step 3 — Resolve the object (`object` mode)

Map the token → `OBJECTCLAS` (+ `objectclas_s4_alt` if the pinned profile is S/4). Unknown
token → `CDH_CLASS_UNKNOWN`, list the curated tokens, STOP. Build `OBJECTID` by ALPHA-converting
the key to the key element's internal width — **numeric keys get leading zeros** (material
`100000022` → `000000000100000022`), **alphanumeric keys stay left-justified** (`M-01`). When
unsure of the width, spot-check with `-Action headers -ObjectClass <c>` and match the on-screen
`OBJECTID`.

## Step 4 — Headers

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_change_history_rfc.ps1" -Action headers -ObjectClass "<CLASS>" -ObjectId "<OBJECTID>" -Max 200 -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

(user/window modes: `-User <U> -FromDate <YYYYMMDD> -ToDate <YYYYMMDD> [-Tcode T]`.) 0 rows →
`CDH_NO_CHANGES` (honest empty — "no change documents in window; object may not be
change-doc-enabled"), register nothing, STOP. Emit `headers.tsv` from the `CDH:header` lines.

## Step 5 — Decode (field-level old → new)

```bash
... -Action decode -ObjectClass "<CLASS>" -ObjectId "<OBJECTID>" [-ChangeNr <N>] -SharedDir "..."
```

Parses `CDH:change` lines: `nr, date, time, user, tcode, tab, field, label, ind, old, new`
(DATS/currency come pre-formatted by the FM; `ind` = I/U/D). The wrapper's decode is the
authoritative field-level source (it reads through the CDPOS cluster / >512-byte limit). A
`STATUS: CDH_NO_CHANGES (no decodable positions)` means the object class isn't decodable this
way (archived / not change-doc-enabled) — report it, never fabricate. In `user`/`window` modes,
decode fans out over the distinct `(class,id)` pairs from the header scan up to `--decode-max`;
pairs beyond the cap stay header-only and register `-Coverage COULD_NOT_CHECK` for the remainder.
Write `changes.tsv`.

## Step 6 — Correlate (`--correlate` only)

Run `-Action imports -FromDate <X> -ToDate <Y>` → `imports.tsv`; optionally `Find-SapArtifacts`
(diagnose evidence overlapping the window) → an evidence TSV. Then:

```bash
... sap_change_history_correlate.ps1 -ChangesTsv changes.tsv -ImportsTsv imports.tsv [-EvidenceTsv ev.tsv] -OutTsv correlate.tsv
```

→ one time-ordered stream; changes within ±`--window` minutes of a transport import are flagged
`near_import=Y`. This registers change-history as a /sap-diagnose evidence source too.

## Step 7 — Render + Register

Claude renders `change_timeline.md` — grouped by change number, `who · when · tcode`, then
`field label: old → new` per row (+ the correlate narrative when present). Register each artifact
(`Register-SapArtifact -Kind change-history\|change-headers\|change-timeline\|change-correlation`,
`-ScopeKey CD_<CLASS>_<OBJECTID>` / `CD_USER_<U>` / `CD_WINDOW_<from>_<to>`, coverage tri-state,
`-Rows`, `-Ticket` when supplied). Print the result table + artifact paths.

## classes mode

`-Action classes [-All]` dumps the curated map validated against live `TCDOB`/`TCDOBT`
(`--all` = every TCDOB class). Read-only.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class): `CDH_CLASS_UNKNOWN` / `CDH_NO_CHANGES` /
`CDH_WRAPPER_MISSING` / `CDH_DECODE_CAPPED` / `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **v1 (live-verified on S4D, S/4HANA 1909):** `object` (headers + decode), `user`, `window`,
  `classes`, `--correlate`. **Decode is fully verified end-to-end** — e.g. a real material's 59
  change rows (STPRS 0→10,000 JPY, DISMM ND→PD, PRCTR →8000999 …) decoded with DDIC field labels,
  matching a CDPOS spot-check. Headers/classes/imports are direct `RFC_READ_TABLE`; decode is
  `CHANGEDOCUMENT_READ` through `Z_GENERIC_RFC_WRAPPER_TBL` (asXML PARAMETER-TABLE, `EDITPOS`
  bound as the `TT_CDRED` table type). **Decode facts (hard-won, live):** the FM keys on
  `OBJECTCLASS+OBJECTID` (change-number alone raises `NO_POSITION_FOUND`); date-range params must
  be ISO `YYYY-MM-DD` in the asXML; a non-decodable object surfaces as the wrapper's
  `DYNAMIC_CALL_FAILED` and is treated fail-SOFT as `CDH_NO_CHANGES`.
- **ECC 6 (SID ERP) parity:** CDHDR (TRANSP), TCDOB/TCDOBT (POOL — open-SQL readable), E070/E071,
  and the wrapper + `CHANGEDOCUMENT_READ` are all present per the plan's probe; **CDPOS is CLUSTER
  on ECC**, which is exactly why decode goes through the FM (never a raw CDPOS read) — one code
  path, no release variant. TCDOB pool-read failure degrades `classes` to map-only (`COULD_NOT_CHECK`).
- **Phase 2:** `config <TABLE>` (customizing/table history from DBTABLOG via `DBLOG_READ_TABLE`
  through the wrapper — SCU3 headless); the v1.5 RSSCD100 GUI fallback via `/sap-run-report` for
  RFC users lacking table-read auth. Not implemented in v1 (fail-loud stub).
- **Read-only, always** (Rule 1/2): only read FMs + `RFC_READ_TABLE`; the wrapper is invoked ONLY
  with `CHANGEDOCUMENT_READ`. Wrapper missing → fail loud + point to `/sap-dev-init`; never deploys.
- **Bounded by design:** `user`/`window` CDHDR scans are window- + `--max`-bounded (CDHDR's key
  starts with OBJECTCLAS, so user/date selections scan wide) — the `--class` filter is strongly
  advised for window mode. Output contains usernames (that is the audit purpose); logs honor
  `log_redact_keys`. `--decode-max` caps the decode fan-out with honest `COULD_NOT_CHECK` coverage
  for the remainder, never a silent short list.
