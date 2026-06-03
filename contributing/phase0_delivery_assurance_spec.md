# Phase-0 Foundation Spec — Delivery-Assurance Skills

> **STATUS: PROPOSAL** (design spec, not yet adopted). Defines the three shared
> primitives that must exist *before* `/sap-impact-analysis`,
> `/sap-enhancement-advisor`, `/sap-transport-readiness`, and
> `/sap-evidence-pack` are built. Author each downstream skill on top of these;
> do not let any of the four reinvent object resolution, artifact tracking, or
> the finding format.

## Why Phase 0 exists

The four delivery-assurance skills share three concerns that, if each skill
solves independently, produce four incompatible vocabularies and a fragile
evidence-pack that scrapes the filesystem. This spec pins them down once:

| Primitive | New shared file | Solves |
|---|---|---|
| `sap_object_resolver` | `shared/scripts/sap_object_resolver.ps1` | "Given `PROGRAM ZMMR001` / `ZMMR001` / `TCODE ME21N` / `TR …` / `PACKAGE …`, what is the canonical object identity + package, and does it exist?" |
| `sap_artifact_index` | `shared/scripts/sap_artifact_lib.ps1` | "Where did each skill write its outputs, and how does evidence-pack find them by scope/ticket/date without scraping?" |
| Reconciled finding model | `shared/scripts/sap_finding_lib.ps1` + `shared/scripts/sap_gate_policy.ps1` | "One severity/category/coverage/gate vocabulary that impact, readiness, ATC, and check-abab all map into — and that never renders *didn't-run* as *passed*." |

> **Build status (2026-06-03):** all three primitives are **built, wired into
> CLAUDE.md, and offline-verified** — `sap_object_resolver.ps1` (parse + 14
> kind-map + WHERE-splitter asserts; still needs live-RFC validation),
> `sap_artifact_lib.ps1` (14 assertions), `sap_finding_lib.ps1` +
> `sap_gate_policy.ps1` (36 assertions). The `artifact_dir` setting is added.
> Downstream skills are not yet built.

All three are **read-only** (resolver + index never mutate SAP; finding model
is in-memory + file output), so they are fully compliant with
`shared/rules/skill_operating_rules.md` with no write-API question to answer.

### Conventions these inherit (already in the repo)

- **RFC**: dot-source `%%RFC_LIB_PS1%%`; use `New-RfcReadTable` /
  `Add-RfcField` / `Add-RfcOption`; return arrays with the `,$rows` idiom
  (`sap_dev_artefacts.ps1:69-93` is the reference parse pattern). The REPOSRC
  guard (`sap_rfc_lib.ps1:378-398`) stays in force — **none of these read
  source.**
- **Logging**: dot-source `%%LOG_LIB_PS1%%`; `Start-SapLog` / `Write-SapLog` /
  `Stop-SapLog`; reuse the `$env:SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID`
  propagation so the artifact index and the log share one `run_id`.
- **Settings**: `Get-SapSettingValue` / `Get-SapWorkDir` (Rule 7 merge); new
  keys land as blank schema defaults in `settings.json`, writes go to
  `{work_dir}\runtime\userconfig.json`.
- **CLI shape** (mirror `sap_check_object_name.ps1`): `param(...)` block,
  parseable `KEY: value | …` stdout lines, a `STATUS:` last line, exit
  `0`=ok / `1`=not-found-or-findings / `2`=ambiguous-or-unknown /
  `3`=RFC-fail, best-effort logging that never breaks the skill.
- **Canonical type vocabulary** = TADIR `OBJECT` codes (`PROG`, `CLAS`,
  `INTF`, `FUGR`, `FUNC`, `TABL`, `DTEL`, `DOMA`, `VIEW`, `SHLP`, `TTYP`,
  `ENQU`, `TRAN`, `MSAG`, `DEVC`, `ENHS`, `ENHO`). Resolver output,
  `finding.object`, and `artifact.scope.object` all speak this. One vocabulary.

---

## A. `sap_object_resolver` — RFC contract

**File**: `plugins/sap-dev-core/shared/scripts/sap_object_resolver.ps1`
**Token**: `%%OBJECT_RESOLVER_PS1%%`
**Tables read** (all RFC_READ_TABLE-safe — none on the forbidden list):
`TADIR`, `TFDIR`, `ENLFDIR`, `TSTC`, `TSTCT`, `E070`, `E071`, `TDEVC`,
`DWINACTIV` (existence/active probe only).

### Function

```powershell
# Dot-source mode (preferred — caller already holds an RFC destination):
$obj = Resolve-SapObject -Destination $g_dest -Token "PROGRAM ZMMR001"
$objs = Resolve-SapObject -Destination $g_dest -Token "TR DEVK900123" -Expand
```

```powershell
function Resolve-SapObject {
    param(
        [Parameter(Mandatory)] $Destination,   # RfcDestination from Connect-SapRfc
        [Parameter(Mandatory)] [string] $Token, # raw user token, with or without leading KIND
        [string] $TypeHint = '',                # PROGRAM|CLASS|FM|TABLE|TCODE|PACKAGE|TR|... when name is bare
        [switch] $Expand                        # TR/PACKAGE → return one record per contained object
    )
    # returns ONE PSCustomObject, or an array when -Expand on a TR/PACKAGE.
}
```

### Returned record (canonical object identity)

```json
{
  "pgmid":       "R3TR",        // R3TR (master) | LIMU (sub-object, e.g. FUNC, METH)
  "object":      "PROG",        // TADIR OBJECT code — the canonical type
  "obj_name":    "ZMMR001",
  "kind":        "PROGRAM",     // normalized user-facing kind (1:1 with object)
  "package":     "ZMM_CORE",    // TADIR DEVCLASS ("$TMP" / "" if local/none)
  "exists":      true,
  "active":      true,          // false if DWINACTIV has a matching row; null if not probed
  "system":      "S4D",
  "client":      "100",
  "resolved_via":"TADIR",       // TADIR|TFDIR|ENLFDIR|TSTC|E071|TDEVC|TYPE_HINT|AMBIGUOUS
  "confidence":  "HIGH",        // HIGH=authoritative index hit; MEDIUM=hint-resolved; LOW=guess
  "note":        ""
}
```

### Resolution logic (in order)

1. **Parse leading KIND keyword** if present (`PROGRAM ZMMR001` → kind=PROGRAM,
   name=ZMMR001). Otherwise use `-TypeHint`, else treat as bare name.
2. **TR** (`kind=TR`, or name matches `^[A-Z0-9]{3}K[0-9]{6}$` confirmed via
   `E070`): the token *is* a transport, not a repository object.
   - Without `-Expand`: return a single TR-kind record (`object="TRAN"`? no —
     use a synthetic `kind=TR`, `object=""`, `obj_name=<TRKORR>`).
   - With `-Expand`: read `E071` (`TRKORR EQ '<tr>'` → `PGMID`/`OBJECT`/
     `OBJ_NAME`), and for each distinct `(PGMID,OBJECT,OBJ_NAME)` emit a
     resolved record (look up `DEVCLASS` via TADIR). This is the inventory
     that `/sap-transport-readiness` and `/sap-evidence-pack` consume.
3. **TCODE** (`kind=TCODE`): `TSTC` (`TCODE EQ '<t>'` → `PGMNA`). Emit **two**
   records: the tcode itself (`object="TRAN"`, package via `TADIR R3TR TRAN`)
   and its underlying program (`object="PROG"`, package via `TADIR R3TR PROG`).
   Caller decides which to act on.
4. **PACKAGE** (`kind=PACKAGE`): `TDEVC` existence; with `-Expand`, read
   `TADIR` (`DEVCLASS EQ '<pkg>'`) and emit one record per child.
5. **FUNCTION MODULE** (`kind=FM`, or bare name found in `TFDIR`): FMs are
   **not** TADIR objects. Bridge: `TFDIR` (`FUNCNAME` → `PNAME`, `FMODE`) +
   `ENLFDIR` (`FUNCNAME` → `AREA` = function group). Then the package is
   `TADIR R3TR FUGR <AREA>`.`DEVCLASS`. Emit `pgmid=LIMU object=FUNC` with the
   FG and package attached in `note` (e.g. `fugr=ZFG_MM`).
6. **Bare name, any other type**: `TADIR` (`OBJ_NAME EQ '<name>'`) — the
   authoritative object directory. Returns `PGMID`/`OBJECT`/`DEVCLASS`.
   - Exactly one row → resolved, `confidence=HIGH`.
   - Multiple rows (same name as e.g. both a DTEL and a DOMA) → if `-TypeHint`
     disambiguates, use it (`confidence=MEDIUM`); else return `resolved_via=
     AMBIGUOUS` with all candidates in `note`, exit code 2.
   - Zero rows → `exists=false`, exit code 1.

### CLI mode (parseable)

```
OBJECT: pgmid=R3TR object=PROG name=ZMMR001 kind=PROGRAM package=ZMM_CORE exists=true active=true via=TADIR confidence=HIGH
STATUS: RESOLVED            # | NOT_FOUND | AMBIGUOUS | RFC_ERROR
```
Exit: `0` resolved · `1` not found · `2` ambiguous/unknown-type · `3` RFC fail.

### Why this is the right first brick

`sap_check_object_name.ps1` only pattern-validates a name; `sap-check-fix`
*probes* type by opening SE38→SE37→SE24→SE11 in the GUI. Neither gives a
fast, RFC-only "name → type + package + existence". All four new skills need
exactly that, repeatedly, in bulk (a TR has dozens of objects). Build it once.

---

## B. `sap_artifact_index` — manifest schema

**File**: `plugins/sap-dev-core/shared/scripts/sap_artifact_lib.ps1`
**Token**: `%%ARTIFACT_LIB_PS1%%`
**New setting**: `artifact_dir` (default `{work_dir}\artifacts`; merged via
Rule 7). Reports are user deliverables → they live under `artifacts\`, NOT
`runtime\` (which holds machine state: connections, registry, userconfig).

### On-disk layout

```
{artifact_dir}\
  index.jsonl                         # append-only manifest (UTF-8 no BOM)
  TR_DEVK900123\                      # one folder per scope_key
    sap-transport-readiness\
      a1b2c3d4\                       # run_id
        DEVK900123_readiness.md
        object_inventory.tsv
        atc_findings.tsv
    sap-evidence-pack\
      e5f6...\ index.md  summary.html
  PROG_ZMMR001\
    sap-impact-analysis\ b7c8.../ ...
```

`scope_key` slug rules: `<OBJECT>_<OBJ_NAME>` for objects
(`PROG_ZMMR001`, `CLAS_ZCL_MM_PRICE_CHECK`), `TR_<TRKORR>`, `PKG_<DEVCLASS>`.
Build it from a resolver record so the vocabulary matches §A.

### Manifest record (one JSONL line per artifact file)

```json
{
  "schema":        "sapdev.artifact/1",
  "ts":            "2026-06-03T14:30:45.123+09:00",
  "run_id":        "a1b2c3d4",            // SAME id as sap_log_lib for this run
  "parent_run_id": "9f8e...",
  "skill":         "sap-transport-readiness",
  "scope": {
    "kind":   "TR",                       // TR | PROGRAM | PACKAGE | CLASS | ...
    "key":    "TR_DEVK900123",
    "system": "S4D", "client": "100",
    "object": { "pgmid":"", "object":"", "obj_name":"DEVK900123" }
  },
  "artifact": {
    "kind":   "readiness_report",         // controlled vocab below
    "format": "md",                       // md|tsv|json|jsonl|html|png
    "path":   "TR_DEVK900123/sap-transport-readiness/a1b2c3d4/DEVK900123_readiness.md",
    "title":  "TR DEVK900123 readiness",
    "rows":   null, "bytes": 10342
  },
  "coverage": "CHECKED_FINDINGS",         // see §C honesty contract
  "verdict":  "NO_GO",                    // GO|NO_GO|GO_WITH_WARNINGS|"" (gate-bearing artifacts only)
  "ticket":   "SAP-4821",
  "supersedes": null                      // run_id of a prior artifact this replaces
}
```

`artifact.kind` controlled vocabulary (extend deliberately): `impact_report`,
`object_inventory`, `dependencies`, `reverse_dependencies`,
`runtime_entrypoints`, `transport_history`, `risk_findings`,
`enhancement_advice`, `candidates`, `recommended_plan`, `readiness_report`,
`inactive_objects`, `locks`, `atc_findings`, `unit_results`,
`dependency_findings`, `release_notes`, `rollback_notes`, `evidence_index`,
`raw_log`, `screenshot`, `graph`.

### Helper functions

```powershell
New-SapScopeKey  -Resolved $obj                       # -> "PROG_ZMMR001"
Get-SapArtifactDir -ScopeKey 'TR_DEVK900123' -Skill 'sap-transport-readiness' -RunId $rid
                                                       # -> creates + returns the folder
Register-SapArtifact -Skill -ScopeKey -Object $resolved -Kind -Format -Path `
                     [-Coverage] [-Verdict] [-Ticket] [-Rows] [-RunId] [-Supersedes]
                                                       # -> appends one index.jsonl line
Find-SapArtifacts    [-ScopeKey] [-Since <date>] [-Ticket] [-Kind] [-Skill]
                                                       # -> records newest-first; honors `supersedes`
```

`Find-SapArtifacts` is the entire data layer for `/sap-evidence-pack`: query
by `scope_key` (or `--ticket`, or `--since`), get every artifact the other
three skills produced, render `index.md`, copy/reference the files, and emit
a **"missing evidence"** section for any expected `artifact.kind` absent from
the result (so the pack states honestly what was *not* produced).

---

## C. Reconciled finding model + gate policy

**Files**: `shared/scripts/sap_finding_lib.ps1` (build/serialize findings) +
`shared/scripts/sap_gate_policy.ps1` (compute `gate` from severity + brief).
**Tokens**: `%%FINDING_LIB_PS1%%`, `%%GATE_POLICY_PS1%%`.

### The honesty contract (the most important part)

Every *check* (not just every finding) reports a tri-state, so "couldn't run"
is never silently equal to "clean" — this is the direct fix for the repo's
recurring false-SUCCESS bug class (SE38 screen-101, FG half-delete, SE01 TZ):

```
check_result.status ∈ CHECKED_CLEAN | CHECKED_FINDINGS | COULD_NOT_CHECK | NOT_APPLICABLE
```

`COULD_NOT_CHECK` (auth denied on `S_TABU_DIS`, RFC failure, object locked
from reading, ATC run errored) is a first-class outcome that surfaces in the
report and the evidence pack — it never collapses into a green check.

### Finding record (`sapdev.finding/1`)

```json
{
  "schema":      "sapdev.finding/1",
  "id":          "F-0007",
  "severity":    "BLOCKER",     // BLOCKER > HIGH > MEDIUM > LOW > INFO  (intrinsic)
  "category":    "INACTIVE_OBJECT",
  "object":      { "pgmid":"LIMU", "object":"CLAS", "obj_name":"ZCL_MM_PRICE_CHECK" },
  "location":    "",            // optional sub-pointer: "line 42" | "method GET_PRICE" | "task DEVK900124"
  "detail":      "Object is inactive in DWINACTIV",
  "remediation": "Activate object before TR release",
  "evidence":    "DWINACTIV OBJECT=CLAS OBJ_NAME=ZCL_MM_PRICE_CHECK",   // raw signal, for audit
  "source":      "DWINACTIV",   // DWINACTIV|WBCROSSGT|RS_EU_CROSSREF|ATC|ABAP_UNIT|STATIC_SCAN|E071K
  "confidence":  "HIGH",
  "coverage":    "CHECKED",     // CHECKED | COULD_NOT_CHECK
  "gate":        "BLOCK"        // BLOCK | WARN | INFO — COMPUTED by gate policy, empty until applied
}
```

**`severity` is intrinsic; `gate` is computed.** Keeping them separate is the
fix for the plan's conflation of "BLOCKER" as both a severity and a gate
decision — the same MEDIUM finding can `BLOCK` under `--strict` and `WARN`
otherwise without changing its severity.

### Severity mapping (so existing producers map in, no rewrites)

| Producer | Source value | → severity |
|---|---|---|
| ATC (`/sap-atc`) | Priority 1 | BLOCKER |
| ATC | Priority 2 | HIGH |
| ATC | Priority 3 | MEDIUM |
| ATC | Priority 4 | LOW |
| `sap-check-abap` | ERROR | HIGH |
| `sap-check-abap` | WARNING | MEDIUM |
| `sap-check-abap` | INFO | INFO |
| `/sap-run-abap-unit` | failed method | BLOCKER |
| readiness | inactive / syntax error / `$TMP` in TR / unreleased child task | BLOCKER |
| readiness | object locked by other user | HIGH |
| readiness | dependency outside TR | MEDIUM |

`sap-check-abap` keeps its current 5-column TSV; `sap_finding_lib.ps1` ships a
thin adapter that lifts those rows into the unified model when evidence-pack
ingests them. **No existing skill is forced to rewrite its output.**

### Gate computation (`sap_gate_policy.ps1`, reads the brief)

Reads `customer_brief.md` §6 Quality bar (resolved via the existing template
language order) — does **not** introduce a second policy store:

- *"ATC must pass? priority 1+2 are gating"* → ATC findings with severity ≥
  HIGH → `gate=BLOCK`.
- *"ABAP Unit tests required? yes (mandatory)"* → unit BLOCKER → `gate=BLOCK`;
  *"nice to have"* → `gate=WARN`.
- Default category→gate table (below) applies when the brief is silent.
- `--strict` promotes the documented WARN subset (locks, dependency-outside-TR)
  to BLOCK.

Default gate map (brief + `--strict` override):

| Category | Default gate |
|---|---|
| INACTIVE_OBJECT, SYNTAX_ERROR, TMP_OBJECT, UNRELEASED_TASK | BLOCK |
| ATC (severity ≥ HIGH) | BLOCK (per brief) |
| UNIT_TEST failure | BLOCK if brief=mandatory else WARN |
| LOCK_OTHER_USER | WARN (BLOCK under `--strict`) |
| MISSING_DEPENDENCY | WARN (BLOCK under `--strict`) |
| CUSTOMIZING_WRONG_CLIENT | BLOCK |
| NO_EVIDENCE_PACK | WARN |

Verdict roll-up: any `BLOCK` → `NO_GO`; else any `WARN` → `GO_WITH_WARNINGS`;
else `GO`. Any `COULD_NOT_CHECK` on a gating category downgrades `GO` →
`GO_WITH_WARNINGS` and is named in the summary.

### On-disk serialization

TSV (keeps reviewer muscle memory from `sap-check-abap`) with a header block
then one row per finding:

```
STATUS: CHECKED_FINDINGS
SCOPE: TR_DEVK900123
VERDICT: NO_GO
TIMESTAMP: 2026-06-03T14:30:45+09:00
TOTAL_FINDINGS: 3   BLOCK: 2   WARN: 1
────────────────────────────────────────
id    severity  gate   category          object                       location        detail                          remediation                source     confidence  coverage
F-0001 BLOCKER  BLOCK  INACTIVE_OBJECT   CLAS:ZCL_MM_PRICE_CHECK                       Inactive in DWINACTIV           Activate before release    DWINACTIV  HIGH        CHECKED
```

JSON sibling (`*.findings.json`) carries the same records for the manifest /
future graph view.

---

## Wiring checklist (per new shared file)

1. Place under `plugins/sap-dev-core/shared/scripts/`.
2. Add a row to **CLAUDE.md → Current Shared Files** with token + purpose.
3. Add the token to the **Token convention** paragraph
   (`%%OBJECT_RESOLVER_PS1%%`, `%%ARTIFACT_LIB_PS1%%`, `%%FINDING_LIB_PS1%%`,
   `%%GATE_POLICY_PS1%%`).
4. Each consuming skill declares it in its `## Shared Resources` section.
5. New settings keys (`artifact_dir`) added as blank defaults to
   `settings.json`; documented in the CLAUDE.md settings tables.
6. Hand-written only — CLAUDE.md Rule 2 forbids script-generated refactors.

## Acceptance tests (Phase 0 done = these pass; report to `temp/testReport/`)

- **Resolver**: `PROGRAM ZMMR001`, bare `ZMMR001`, `TCODE ME21N`,
  `FM <z-fm>` (TFDIR/ENLFDIR bridge), `TR <trkorr> --Expand` (E071 inventory),
  `PACKAGE <pkg> --Expand`, an ambiguous name (exit 2), a missing name (exit
  1), and an auth-denied table (exit 3 / clean error, not a dump).
- **Artifact index**: two skills register artifacts under one scope_key;
  `Find-SapArtifacts -ScopeKey …` returns both newest-first; `-supersedes`
  hides a replaced artifact; `-Since`/`-Ticket` filter correctly.
- **Finding model**: an ATC P1 + a check-abap ERROR + a `COULD_NOT_CHECK`
  all serialize into one TSV; gate policy with brief="priority 1+2 gating"
  yields `NO_GO`; `--strict` flips a LOCK from WARN→BLOCK; the
  `COULD_NOT_CHECK` downgrades a would-be `GO` to `GO_WITH_WARNINGS` and is
  named.

## Build order after Phase 0

`sap_object_resolver` + `sap_artifact_lib` + `sap_finding_lib`/`sap_gate_policy`
→ `/sap-transport-readiness` → `/sap-impact-analysis` (WBCROSSGT/CROSS RFC
reads, **not** GUI where-used and **not** source parsing) → `/sap-evidence-pack`
→ `/sap-enhancement-advisor`.

---

# Appendix P1 — Dependency extraction via the cross-reference index

> **STATUS: PROPOSAL (Phase 1).** The data-source strategy for
> `/sap-impact-analysis`. Not a Phase-0 primitive, but it constrains the
> resolver/finding contracts above, so it lives in the same doc. The single
> most important design decision in the whole roadmap is here: **read SAP's
> system-maintained cross-reference index; do not parse source and do not
> drive the GUI where-used skill in bulk.**

## P1.1 Why not the two "obvious" approaches

| Tempting approach | Why it fails here |
|---|---|
| **Static source scan** (`relationship.source: "static_scan"` in the plan's data model) | Needs source. `RFC_READ_TABLE` on `REPOSRC` is hard-blocked (`sap_rfc_lib.ps1:378-398`, LRAW > 512-byte cap). `RPY_PROGRAM_READ` works but you'd re-implement an ABAP parser, miss dynamic calls anyway, and get **lower** confidence than SAP's own index. |
| **Call `/sap-where-used-list` per object** | It's GUI/VBScript, **reverse-only**, **one object per invocation**. A 200-object package = 200 serial GUI round-trips → timeout. Keep it for single-object drill-down, never as the bulk engine. |

The index tables below are populated by SAP whenever an object is saved /
activated, are `RFC_READ_TABLE`-safe (narrow rows, no LRAW), and give **both
directions** from one source.

## P1.2 The index-table map

All reads go through `New-RfcReadTable` (REPOSRC guard inert — none of these
are forbidden). Project narrow; these rows are well under the 512-byte cap.

| Need | Table | Read by | Notes |
|---|---|---|---|
| Global-symbol usage (classes, interfaces, methods, DDIC types, global data) — **both directions** | `WBCROSSGT` | `OTYPE` (used symbol category), `NAME` (used object), `INCLUDE` (using include) | Forward: `INCLUDE EQ '<using>'`. Reverse: `NAME EQ '<used>'`. `OTYPE` encodes category (e.g. `TY` type, `ME` method, `DA` data) — discover the full code set empirically per release, don't hardcode. |
| Classic references (FORM/PERFORM, FM calls, MESSAGE, classic includes) | `CROSS` | `TYPE`, `NAME`, `INCLUDE` | The pre-OO index. `TYPE` codes vary by release → sample with a small `RFC_READ_TABLE` (or `/sap-gui-probe`) before relying on a specific code. |
| Program ↔ table usage — **both directions** | `D010TAB` | `TABNAME`, `MASTER` | Reverse ("who uses table ZMM_ORDER"): `TABNAME EQ 'ZMM_ORDER'` → `MASTER` programs. Forward: `MASTER EQ 'ZMMR001'`. Fast, narrow, authoritative for DDIC-table usage. |
| Program ↔ include | `D010INC` | `MASTER`, `INCLUDE` | Resolves the `INCLUDE` from `WBCROSSGT`/`CROSS` back to its master program. |

### The include→object nuance (must handle)

`WBCROSSGT.INCLUDE` / `CROSS.INCLUDE` is the **using include**, not the
executable program or owning class. A class method lives in an include like
`<class>CM001`; a function module in `L<area>U01`; a report in its own include.
Two resolution paths:

1. **Cheap**: `D010INC` (`INCLUDE` → `MASTER`) for program/FG includes; class
   includes map to the class via the SEO include-naming convention
   (`SEOCLASS` / `SEOCOMPO`).
2. **Authoritative**: `RS_EU_CROSSREF` already does this resolution (it's the
   FM behind SE84/where-used). It is **not RFC-enabled** → call it through the
   existing **`Z_GENERIC_RFC_WRAPPER_TBL`** (deployed by `/sap-dev-init`) via
   `/sap-rfc-wrapper-fm`. Use this when you need SAP's own include→object
   mapping + scope filtering rather than re-deriving it.

**Decision rule**: direct table reads (`WBCROSSGT`/`CROSS`/`D010TAB`/`D010INC`)
are the fast default for bulk fan-out; the wrapped `RS_EU_CROSSREF` is the
fallback when include→object resolution or FM where-used placement is
release-ambiguous.

## P1.3 DDIC dependency — reuse, don't re-read

For domain/data-element/table structural dependency, **reuse the existing DDIC
helpers** rather than raw-reading the wide `DD03L` (which can approach the
512-byte cap):

| Need | Source | Reuse |
|---|---|---|
| Domain → data elements | `DD04L` (`DOMNAME EQ '<dom>'`) | narrow `RFC_READ_TABLE` |
| Data element → table fields | `DD03L` (`ROLLNAME EQ '<dtel>'`, projected) | `sap_rfc_lookup_ddic.ps1` (DDIF_FIELDINFO_GET) preferred for field detail |
| Structure/table component detail | DDIF APIs | `sap_rfc_lookup_struct.ps1` / `sap_rfc_lookup_ddic.ps1` (already in repo) |
| Foreign keys | `DD08L` | narrow read |

Transitive DDIC impact ("change domain → which data elements → which tables →
which programs") chains `DD04L` → `DD03L`/lookup → `D010TAB`. Cap depth at 1-2
(see P1.5).

## P1.4 Runtime entry points & history (already RFC-safe)

| Entry point | Table | Reuse |
|---|---|---|
| Transaction codes | `TSTC` / `TSTCT` | also in `sap_object_resolver` (§A.3) |
| Background jobs / steps | `TBTCO` / `TBTCP` | new narrow reads |
| Variants | `VARID` / `VARIT` | new narrow reads |
| RFC-enabled FMs | `TFDIR` (`FMODE EQ 'R'`) | already in resolver §A.5 |
| Transport history | `E070` / `E071` / `E071K` | reuse `sap_dev_artefacts.ps1` patterns |
| Enhancements / BAdIs / exits | `SXS_ATTR` / `SXC_*` / `BADI_IMPL` / `MODSAP` / `MODACT` | reuse `sap_se19_classify.ps1` + `sap_cmod_query.ps1` |

## P1.5 Confidence model + the disclosed blind spot

This corrects the plan's data model, where `source:"static_scan"` was tagged
`confidence:"HIGH"` — that is inverted.

| `relationship.source` | confidence | Rationale |
|---|---|---|
| `WBCROSSGT` / `CROSS` / `D010TAB` / `DD04L` / `RS_EU_CROSSREF` | **HIGH** | system-maintained index |
| `STATIC_SCAN` (if ever done via `RPY_PROGRAM_READ`) | **LOW–MEDIUM** | string matching, fragile |
| Dynamic (`CALL FUNCTION lv_name`, dynamic `SELECT (tab)`, `CALL METHOD` via ref, `SUBMIT (rep)`) | **undetectable** | invisible to *both* index and scan |

**Two caveats every impact report must print** (the honesty contract from §C
applies to coverage, not just findings):

1. **Dynamic-call gap** — name it explicitly. An impact report that silently
   omits dynamic dispatch reads as "fully covered" when it is not.
2. **Index staleness** — the cross-reference index is rebuilt on
   save/activate (and en masse by `SGEN`). On a system where it's stale, a
   `COULD_NOT_CHECK`-style note belongs in the report rather than a confident
   "no references found."

## P1.6 How it feeds the Phase-0 contracts

- Every dependency edge is emitted with the resolver's canonical identity on
  both ends (`{pgmid, object, obj_name}` from §A) — one vocabulary end to end.
- Risk findings (`risk_findings.tsv`) use the §C finding model; the
  dependency *count* feeds a **thin, transparent** risk layer — ship the facts
  (the `dependencies.tsv` / `reverse_dependencies.tsv`), keep the score
  configurable and clearly heuristic (don't lead with "80+ programs = High").
- Each output file is registered via `Register-SapArtifact` (§B) under the
  scope_key so `/sap-evidence-pack` collects it for free.

## P1.7 Acceptance tests (Phase 1)

- Reverse: `TABLE ZMM_ORDER` → programs via `D010TAB`; cross-check a known
  user against GUI `/sap-where-used-list` for the *same* object (the two must
  agree — validates the index path before trusting it in bulk).
- Forward: `PROGRAM ZMMR001` → its tables (`D010TAB MASTER=…`) + global
  symbols (`WBCROSSGT INCLUDE=…` resolved to objects via `D010INC`).
- DDIC transitive: a domain → data elements → table fields → programs, depth
  capped at 2, fan-out logged.
- A dynamic `CALL FUNCTION lv_fm` in a test program → confirm it is **absent**
  from results **and** that the report's dynamic-gap caveat fires.
- Bulk: `PACKAGE <pkg> --Expand` impact completes via table reads without a
  single GUI round-trip (proves we did not fall back to `/sap-where-used-list`
  per object).
