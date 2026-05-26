# ABAP Code Quality Rules (used by `/sap-gen-abap` and `/sap-check-abap`)

These rules turn the customer's *Project Profile* (see
`<SAP_DEV_CORE_SHARED_DIR>/templates/customer_brief.md`) into concrete ABAP
patterns the generator emits and the checker enforces. They override any
conflicting "skeleton" guidance in individual SKILL.md files.

The numbering matches the advice list in the user-facing review.

---

## 9. Modern ABAP first, classic on demand

If the brief says ABAP release ≥ `7.40 SP08`:

- Use `DATA(lv_x) = ...` / `FINAL(lv_x) = ...` for inline declarations
- Use `VALUE #( ... )` / `COND #( ... )` / `REDUCE` / `FOR` constructor expressions
- Use `line_exists( itab[ key = value ] )` and `itab[ key = value OPTIONAL ]`
- Use `@`-prefixed host variables in Open SQL (mandatory ≥ 7.50). **The field list MUST be comma-separated when `@`-host-vars appear anywhere in the statement** — `SELECT a, b, c FROM …` not `SELECT a b c FROM …`. Mixed syntax (one form per statement) is a compile-time error: *"The elements in the 'SELECT LIST' list must be separated using commas."* `sap-check-abap` flags this as `SQL_STRICT_COMMA` (ERROR severity) so generators catch it before deploy.
- Use `CORRESPONDING #( ... MAPPING ... )` instead of MOVE-CORRESPONDING

Otherwise (≤ 7.31): emit classic syntax with explicit `DATA:` blocks.

The generator MUST output a one-line header comment stating which mode it
chose and why, e.g.:
```abap
" Generated with modern ABAP syntax (release 7.52 from project brief).
```

## 10. OOP scaffold over FORM routines (new programs)

For *new* programs, scaffold a local class instead of FORM routines:

```abap
CLASS lcl_main DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS run.
  PRIVATE SECTION.
    METHODS build,
            validate RAISING zcx_proj_error,
            execute  RAISING zcx_proj_error,
            persist  RAISING zcx_proj_error.
ENDCLASS.

START-OF-SELECTION.
  TRY.
      NEW lcl_main( )->run( ).
    CATCH zcx_proj_error INTO DATA(lo_err).
      MESSAGE lo_err->get_text( ) TYPE 'E'.
  ENDTRY.
```

When updating an existing FORM-style program, do NOT rewrite it — extend it
in the same style to keep the diff minimal.

## 11. Exception classes, never `MESSAGE e/a/x` in methods

Inside any `CLASS … IMPLEMENTATION` method, `MESSAGE e/a/x` causes
`UNCAUGHT_EXCEPTION` short dumps. Generator MUST emit:

```abap
RAISE EXCEPTION TYPE zcx_proj_error
  EXPORTING textid = zcx_proj_error=>err_field_invalid
            field  = 'KUNNR'
            value  = lv_kunnr.
```

If the project does not yet have `ZCX_<PROJ>_ERROR`, generator emits the
exception class boilerplate ONCE at the top of the bundle (or as a separate
file under `{source_code_url}/work/<project>/zcx_proj_error.abap`) and
re-uses it everywhere.

## 12. Performance gates — non-negotiable

Forbidden patterns the generator MUST never produce, and the checker MUST flag:

- `SELECT … WHERE …` inside `LOOP AT itab` — pre-select instead.
- `FOR ALL ENTRIES` without `IF lt_keys IS NOT INITIAL` guard — empty driver
  table reads ALL rows.
- `FOR ALL ENTRIES` without `SORT lt_keys BY <key fields>` and
  `DELETE ADJACENT DUPLICATES … COMPARING <key fields>` before the SELECT.
- `SELECT *` when only a few columns are needed. ATC's "Search problematic
  SELECT * statements" check (Priority 1) flags any `SELECT *` whose
  downstream consumer reads less than 80% of the columns.
- `DESCRIBE TABLE … LINES` followed by `IF n > 0` — use `IS NOT INITIAL`.
- `MODIFY itab FROM wa` inside a `LOOP AT itab INTO wa` — use
  `LOOP AT itab ASSIGNING FIELD-SYMBOL(<fs>)` and modify `<fs>` in place.

**Concrete pattern for explicit field lists:**

When the only fields read downstream are `key1` and `val1` of a 11-column
key-value table:

```abap
" ❌ ATC P1 — fetches 11 columns, uses 2.
SELECT * FROM zmmfixedvals24c
  INTO TABLE @gt_fixed
  WHERE zpmgid = @sy-repid.

" ✅ Explicit field list. Switch the receiving table type to a slim
"    structure so the column count matches the SELECT.
TYPES BEGIN OF ty_kv,
        key1 TYPE zmmde_key241c,
        val1 TYPE zmmde_val241c,
      END OF ty_kv.
TYPES tt_kv TYPE STANDARD TABLE OF ty_kv WITH EMPTY KEY.
DATA gt_kv TYPE tt_kv.

SELECT key1, val1
  FROM zmmfixedvals24c
  WHERE zpmgid = @sy-repid
  INTO TABLE @gt_kv.
```

Generator MUST scan its own AST for every `gt_<x>-<column>` reference and
narrow the SELECT field list accordingly. Rule of thumb: **never SELECT
columns the rest of the program won't read.** When in doubt, query
`/sap-check-abap` post-generation — it will flag the ratio.

For batch jobs in the brief's "large" volume band:

- Use `SELECT … INTO TABLE @DATA(lt_x) PACKAGE SIZE n` with cursor
  paging (typical n = 1000 – 10000).
- Commit work every N records with `COMMIT WORK AND WAIT`.

## 13. Static SQL safety

- Always use `@` host variables (≥ 7.40 SP05).
- Never concatenate strings into a `SELECT` clause unless the spec explicitly
  asks for a configurable WHERE (then refuse and ask for whitelisted columns).
- For dynamic field/table names, use `SELECT … (lt_fields) FROM (lv_table)`
  with a whitelist check from a Z-config table.

## 14. Authorization + change-document hooks

For every **persistence** path (`UPDATE` / `INSERT` / `MODIFY` / `DELETE` on
Z* / Y* tables, or BAPI write call), generator emits an `AUTHORITY-CHECK`
that **lists every field of the SU21 auth-object definition**, not just the
fields the gate cares about. ATC's Extended Program Check (SLIN) emits
"Wrong number of authorization fields" (Priority 2) when the field count
in the source doesn't match the SU21 metadata.

For unused fields, pass the literal `DUMMY` keyword (NOT `'*'`, NOT a
blank value — those raise different findings).

```abap
" ❌ ATC P2 — M_MATE_MAR has 4 fields in SU21 (ACTVT MATART BUKRS WERKS).
"           Source passes 2.
AUTHORITY-CHECK OBJECT 'M_MATE_MAR'
  ID 'ACTVT'  FIELD '01'
  ID 'MATART' FIELD '*'.

" ✅ All four fields listed. ACTVT + MATART carry the gate intent;
"    BUKRS + WERKS are not gated here, so use DUMMY.
AUTHORITY-CHECK OBJECT 'M_MATE_MAR'
  ID 'ACTVT'  FIELD '01'
  ID 'MATART' FIELD lv_mtart
  ID 'BUKRS'  DUMMY
  ID 'WERKS'  DUMMY.
```

The generator MUST look up the SU21 field list of any auth object it
emits a check for, via the **live SAP system** — not via a hardcoded
table. SU21 field lists are release-specific and customer-specific
(some installations add Z-fields to standard objects via SU24). A
hardcoded list will silently produce wrong AUTHORITY-CHECK shapes that
the SLIN check then flags as Priority 2 ATC findings.

**Live-lookup pattern** (mirrors the FM-signature pattern at Step 1.5):

The shared script `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lookup_authz.ps1`
queries the live SAP `AUTHX` table for a list of auth objects and
returns their fields in `POSITION` order. It caches per-system at
`{work_dir}\cache\authz_signatures\<SYSTEM_ID>\<OBJCT>.tsv` with a
90-day default TTL.

The generator must:

1. **Scan its own AST** (or pre-emit pass) for every literal `OBJCT`
   value in `AUTHORITY-CHECK OBJECT '<X>'`. Collect the unique set.
2. **Run the lookup script** with that set as the request file. The
   result file `_authz_signatures.txt` is a TSV: `OBJCT\tPOSITION\tFIELD`
   (one row per field). Special row `OBJCT\tNOT_FOUND\t` for
   non-existent objects; `OBJCT\tUNAVAILABLE\t` for RFC unreachable.
3. **Emit the AUTHORITY-CHECK** with one `ID '<FIELD>' …` clause per
   row, in `POSITION` order. For every field the gate logic doesn't
   need, use `DUMMY`. For the gating fields, use `FIELD <value>`.

Reference table for the most common material-management auth objects
(verified live on an S/4HANA 1909 build, 2026-05-10).
This is provided ONLY as a fallback when RFC is unavailable — the live
lookup is authoritative:

| Object | Fields (SU21, in POSITION order) |
|---|---|
| `M_MATE_MAR` | (look up live — hardcoded list was wrong on this build) |
| `M_MATE_WRK` | (look up live) |
| `M_MATE_NEU` | (look up live) |
| `M_MATE_STA` | (look up live) |

**Lesson from 2026-05-10**: a hardcoded list `M_MATE_MAR = ACTVT/MATART/
BUKRS/WERKS` produced 10 SLIN P2 findings on an actual S/4HANA 1909
build. SU21 customization on customer systems makes any hardcoded list
brittle. Always prefer the live RFC lookup; surface the
`NOT_FOUND` / `UNAVAILABLE` cases as ATC P1 findings (refusing to emit
an unknown-shape AUTHORITY-CHECK is safer than emitting a wrong one).

If the brief lists `change document logging required = yes`, also wrap the
mutation in `CHANGEDOCUMENT_OPEN_RECORD` / `CHANGEDOCUMENT_CLOSE_RECORD` (or
the project's equivalent wrapper).

## 15. Auto-emit ABAP Unit tests

For each generated `lcl_main` (or top-level FORM bundle), emit a sibling
class:

```abap
CLASS ltcl_main DEFINITION FOR TESTING DURATION SHORT RISK LEVEL HARMLESS.
  PRIVATE SECTION.
    DATA: go_cut TYPE REF TO lcl_main.
    METHODS:
      setup,
      test_validation_<rule_no> FOR TESTING.
ENDCLASS.

CLASS ltcl_main IMPLEMENTATION.
  METHOD setup.
    CREATE OBJECT go_cut.
  ENDMETHOD.
  ...
ENDCLASS.
```

For each "Golden I/O" row from the spec, emit one `test_*` method with
`cl_abap_unit_assert=>assert_*` calls.

## 16. `_deps.txt` — dependency manifest

Alongside every generated `.abap` file, write `<NAME>.deps.txt`:

```
STANDARD_TABLES
MARA
MAKT
T001W

BAPIS
BAPI_MATERIAL_SAVEDATA
BAPI_TRANSACTION_COMMIT

CLASSES
CL_ABAP_UNIT_ASSERT

AUTHZ_OBJECTS
M_MATE_WGR

CUSTOM_OBJECTS
ZCL_HK_LOGGER
ZHKFIXEDVALS9
```

Hand this file to the customer's basis / security team for transport scope
review and authorization design — sales differentiator.

## 17. `_traceability.txt` — spec-to-code map

Alongside the `.abap`, write `<NAME>.traceability.txt`:

```
SPEC SECTION → ABAP LOCATION
[Validation #1: 登録区分 must be I or U]            → lcl_main->validate (line 142)
[Validation #2: 品目コード must exist (registration)] → lcl_main->validate (line 156)
[Processing 3.2: BAPI call]                         → lcl_main->execute  (line 198)
[FILE MAPPING row 4: MARA-MATNR]                    → lcl_main->build    (line 84)
```

Audit-friendly. Required for regulated industries (pharma / finance).

## 19. Lookup pattern — `READ TABLE` over `LOOP AT … EXIT`

For "find first match" semantics, generator MUST emit `READ TABLE` (with
`WITH KEY` for sorted/hashed tables, or a key-only structure for standard
tables), NOT `LOOP AT itab WHERE … EXIT`.

ATC's "Search problematic statements for result of SELECT/OPEN CURSOR
without ORDER BY" check (Priority 3) flags any `LOOP AT itab. … EXIT.`
where the underlying source SELECT did not have an `ORDER BY` clause —
the loop's first match is non-deterministic across DB engines and
release upgrades.

```abap
" ❌ ATC P3 — order-dependent first match against a SELECT-INTO-TABLE
"           that had no ORDER BY.
DATA lv_found TYPE abap_bool.
LOOP AT gt_fixed ASSIGNING FIELD-SYMBOL(<f>)
  WHERE key1 = 'WERKS' AND val1 = is_row-werks.
  lv_found = abap_true.
  EXIT.
ENDLOOP.

" ✅ READ TABLE — explicit "find first / find any" with deterministic
"    semantics. TRANSPORTING NO FIELDS makes the intent clear and is
"    faster (no field copy).
READ TABLE gt_fixed TRANSPORTING NO FIELDS
  WITH KEY key1 = 'WERKS'
           val1 = is_row-werks.
DATA(lv_found) = xsdbool( sy-subrc = 0 ).
```

For tables that will be queried this way many times, declare the table
with `WITH NON-UNIQUE SORTED KEY` or `WITH NON-UNIQUE HASHED KEY` and
use `WITH TABLE KEY` in the READ — O(log n) or O(1) lookup vs O(n) scan.

When a true loop over multiple matches IS needed, keep the LOOP but
ensure the source SELECT has `ORDER BY <key fields>` — the ATC check
clears once the source is deterministic.

## 20. Translatable error text — `MESSAGE … INTO` over hardcoded string templates

When emitting user-facing error text inside class methods (where rule 11
forbids `MESSAGE e/a/x` as a runtime statement because of
`UNCAUGHT_EXCEPTION`), use `MESSAGE eNNN(<msgclass>) WITH … INTO lv_var`.
This (a) routes through the project's message class for translation,
and (b) clears ATC's "Text element is missing in a character string in
a string template" check (Priority 3, fires per template).

```abap
" ❌ ATC P3 — hardcoded English literal inside string template.
"           Each | … { … } … | with literal text fires once.
ev_msgtype = 'E'.
ev_msgnr   = '001'.
ev_msgtxt  = |Invalid regtype { is_row-regtype }|.

" ✅ MESSAGE … INTO routes through the project's message class.
"    The literal text lives in T100 and is translatable; ATC is happy.
MESSAGE e001(zmm24c) WITH is_row-regtype INTO ev_msgtxt.
ev_msgtype = 'E'.
ev_msgnr   = '001'.
```

The message class (`MESSAGE-ID …` in the REPORT statement, or the
`(msgclass)` suffix on each MESSAGE) MUST already exist with the
referenced numbers — generator typically creates it via `/sap-se91`
in the same generation pass and writes the messages to a sibling
`<NAME>.messages.txt` for the deploy step.

When the spec defines an error message with parameters, map them to
`&1 &2 &3 &4` placeholders in T100 (max 4) and pass with `WITH`. If
the spec needs more than 4 parameters, the generator MUST collapse
them into a single string literal first (`CONCATENATE … INTO lv_msg`)
and use a single-`&1` message — T100 does not accept &5+.

This rule also covers other locations where translatable text might
otherwise be hardcoded: `WRITE: / 'literal'` (use `TEXT-NNN`), `RAISE
EXCEPTION … MESSAGE` (use `IF_T100_MESSAGE` interface), `ALV column
headers` (use the field's `dataelement.scrtext_l` — automatic when the
column is `dataelement`-typed).

## 21. Selection texts and text symbols — emit sibling file

Whenever the generator emits a `TEXT-NNN` reference (for `WITH FRAME
TITLE TEXT-001`, `COMMENT TEXT-002`, `SELECTION-SCREEN COMMENT … TEXT-…`)
OR a `SELECTION-SCREEN` parameter without a text symbol (which becomes
a Selection Text), it MUST also emit a sibling
`<NAME>.text_elements.txt` file for the deploy skill to populate at
SE38 → Goto → Text Elements:

```
[SELECTION_TEXTS]
P_BUKRS	Company Code
P_WERKS	Plant
P_MATNR	Material
P_FILE	Input file path

[TEXT_SYMBOLS]
001	Selection
002	Result Output
```

ATC's "Text element not defined in TEXT-POOL" check (Priority 3) fires
once per TEXT-NNN reference whose symbol isn't populated in the program's
text pool. Without the sibling file, the deploy step has no source for
the literal text and the program activates with empty title bars.

`/sap-se38` (and `/sap-se38-update`) reads `<NAME>.text_elements.txt`
when present and applies the entries via SE38 → Goto → Text Elements
after the source upload + activation. The fields in the file:

- `[SELECTION_TEXTS]` block: tab-separated `<P_NAME>\t<text>`. Generator
  fills from `_selection_definition.txt`'s `LABEL` column (one line per
  row: `<DTEL_NAME>\t<LABEL>`). `LABEL` is already in the spec's natural
  language — copy verbatim, do NOT translate. If `LABEL` is blank for
  a row, fall back to that parameter's data-element short text.
- `[TEXT_SYMBOLS]` block: tab-separated `<NNN>\t<text>`. Source order:
  (1) `{doc_name}_textElements.txt` if it has data rows
  (`TEXT_ID\tTEXT_VALUE`; header-only = no entries); (2) for any
  `TEXT-NNN` reference still uncovered, derive from spec context (e.g.
  TEXT-001 frame title ← `_PGM_summary.txt`'s "功能規格名 / 機能名 /
  Functional Spec Name" line or the program title). Emit in the spec's
  natural language.

**Language rule (hard):** the output language of both blocks MUST match
the spec's natural language as carried in `LABEL` / `_textElements.txt`
/ `_PGM_summary.txt`. The `template_language` setting controls customer-
facing template defaults (briefs, blank spec templates) — it does NOT
override per-spec content that the customer has already authored.
Substituting English defaults onto a CN/JA spec is a defect (it is what
silently bit the V41 `ZMMRMAT041R01` build on 2026-05-26 — the generator
wrote `P_BUKRS\tCompany Code` despite the spec carrying `公司代码` in
`_selection_definition.LABEL`). For multi-language deployments, the
deploy skill loops the file once per language.

## 22. BAPI structure field-list awareness (S/4HANA)

When emitting `CALL FUNCTION 'BAPI_*'` with a structure parameter (e.g.
`headdata`, `clientdata`, `clientdatax`, `plantdata`, `plantdatax`),
generator MUST only assign to fields that EXIST on the BAPI structure
type for the target SAP release. AI training knowledge of BAPI structures
is unreliable — fields are added/removed/renamed between releases, and
some "obvious" fields (especially weight/volume/packaging) are not on
the BAPI structure at all on modern releases.

The reliable verification is via the two-step RFC chain:

1. **Step 1.5** (`sap_rfc_lookup_fm.ps1`) returns FM parameter signatures.
   For each parameter, that tells the generator the STRUCTURE TYPE
   name (e.g. `CLIENTDATA → BAPI_MARA`).
2. **Step 1.5e** (`sap_rfc_lookup_struct.ps1`, added 2026-05-11) returns
   the live field list of each STRUCTURE TYPE via `DDIF_FIELDINFO_GET`.
   This is what tells the generator that `BAPI_MARA` on this S/4HANA
   1909 has `NET_WEIGHT`, `UNIT_OF_WT`, `MATL_GROUP`, ... but NOT
   `GROSS_WT`, `VOLUME`, `VOLUMEUNIT`, `PACK_VO`.

When Step 1.5e is enabled, the generator consults `_struct_signatures.txt`
during BAPI structure-parameter emission. Every `ls_clientdata-<field> =
...` assignment is verified against the cached field list FIRST. Fields
present in the cache → emit assignment. Fields absent → route via the
correct adjacent BAPI parameter (e.g. `marmdata` for MARM-resident
fields) OR emit a TODO comment block (V0 fallback). NEVER silently drop.

When RFC is unavailable (`_struct_signatures.txt` row =
`TABNAME UNAVAILABLE ...`), fall back to AI training knowledge but
emit a `" TODO: verify against live SAP after RFC available"` comment
in the generated assignment block.

**Concrete known traps on S/4HANA 1909 — BAPI_MATERIAL_SAVEDATA**:

| BAPI param | Structure | Fields that DO NOT exist (caused 9 syntax errors on 2026-05-10) |
|---|---|---|
| `clientdata` / `clientdatax` | `BAPI_MARA` / `BAPI_MARAX` | `gross_wt`, `volume`, `volumeunit`, `pack_vo` |

These four fields belong to `MARM` (Units of Measure for Material) and
are written via `BAPI_MATERIAL_SAVEDATA`'s `marmdata` / `marmdatax`
table parameters — NOT via the flat clientdata structure. The flat
`net_weight` and `unit_of_wt` ARE on `BAPI_MARA` (verified 2026-05-10),
so basic-view weight can pass through clientdata.

**Generator rule**: when the spec maps any of these source fields
(`brgew`, `volum`, `voleh`, `behvo` from MARA, or equivalent), emit
either:

1. (Preferred for V1+) — a `marmdata` / `marmdatax` table assignment:
   ```abap
   APPEND VALUE #( material   = is_row-matnr
                   alt_unit   = is_row-meins
                   gross_wt   = is_row-brgew
                   unit_of_wt = is_row-gewei
                   volume     = is_row-volum
                   volumeunit = is_row-voleh ) TO lt_marmdata.
   APPEND VALUE #( material   = is_row-matnr
                   alt_unit   = is_row-meins
                   gross_wt   = abap_true
                   unit_of_wt = abap_true
                   volume     = abap_true
                   volumeunit = abap_true ) TO lt_marmdatax.
   ```
   Then pass `lt_marmdata` / `lt_marmdatax` in the BAPI's TABLES section.

2. (Acceptable for V0 stub) — a clear TODO comment block:
   ```abap
   " S/4HANA BAPI_MARA does not expose gross_wt / volume / volumeunit /
   " pack_vo as flat fields. They live on MARM and are written via the
   " marmdata / marmdatax table parameters of BAPI_MATERIAL_SAVEDATA.
   " V1 of this report ships only basic + plant view; weight (other than
   " net) + volume mappings are TODO and tracked in the spec supplement.
   ```

**Generator rule**: NEVER silently drop a spec-supplied field. Either
emit the marmdata path OR emit a TODO. Silent drop produces a build
that activates but loses data — worse than a syntax error.

The same pattern applies to other BAPIs with documented "wrong place"
field traps. When in doubt, query Step 1.5's `_fm_signatures.txt` for
the structure type then `DDIF_FIELDINFO_GET` for the field list.

## 23. Cyclomatic complexity & method length

Checker emits a WARNING when:
- A method exceeds **50 lines** (configurable via brief)
- A method's branch count (`IF` + `CASE WHEN` + `LOOP` + `TRY-CATCH`) exceeds
  **10**

Suggest extracting helper methods.

## 17. No runtime assignment to TEXT-NNN symbols (S/4HANA strict)

Modern ABAP (S/4HANA, strict syntax mode) rejects any assignment to a text
symbol with the error "The field TEXT-NNN cannot be modified". TEXT-NNN
symbols are read-only at runtime — they are part of the program's text
pool, populated via SE38 → Text Elements → Text Symbols.

**Generator MUST NOT emit:**
```abap
INITIALIZATION.
  TEXT-001 = 'Material Upload Parameters'(s01).   " ❌ rejected by S/4
```

**Generator emits the reference only — populate the text pool separately:**
```abap
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  ...
SELECTION-SCREEN END OF BLOCK b1.
" Frame title text TEXT-001 is set via SE38 → Text Elements after deploy.
```

**Checker (`sap-check-abap`) flags:** any line matching the regex
`^\s*TEXT-\d{3}\s*=` inside or outside an INITIALIZATION block.

**Severity:** ERROR (P2) — blocks deployment because activation will fail.

---

## How a SKILL.md uses this file

Add to the `## Shared Resources` block:

```
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | Mandatory ABAP code-quality rules — generator emits compliant code; checker enforces. |
| `<SAP_DEV_CORE_SHARED_DIR>/templates/customer_brief.md` | One-page customer Project Profile that drives release-aware code generation. |
```

The generator (`sap-gen-abap`) MUST read the customer brief at the start, set
its mode flags (modern vs classic; OOP vs FORM; perf band; authz objects),
and apply this rule file end-to-end. The checker (`sap-check-abap`) MUST
load this rule file as additional findings categories on top of the existing
NAMING / TYPE / SQL / UNUSED checks.
