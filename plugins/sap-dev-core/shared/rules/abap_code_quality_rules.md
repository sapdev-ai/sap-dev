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

**Block order (report / type 1): ALL global declarations BEFORE any event
block.** ABAP scopes a global `TYPES` / `CLASS … DEFINITION` / `DATA` /
`CONSTANTS` to wherever it is written. If the generator emits one *after* an
event block (`INITIALIZATION`, `AT SELECTION-SCREEN …`, `START-OF-SELECTION`),
the declaration is captured inside that event and is invisible elsewhere —
e.g. a global `TYPES ty_row` placed after `AT SELECTION-SCREEN ON
VALUE-REQUEST` yields `"Type TY_ROW is unknown"` and a failed syntax check on
the first deploy. Emit a report in exactly this order:

```abap
REPORT z...  MESSAGE-ID z....
" 1. global TYPES (ty_row, ty_result, ...)
" 2. CLASS lcl_main DEFINITION ... ENDCLASS.
" 3. global DATA / CONSTANTS
" 4. SELECTION-SCREEN / PARAMETERS / SELECT-OPTIONS
INITIALIZATION.                                   " 5. event blocks come AFTER 1-4
AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.  "    (e.g. F4 file dialog)
  " ...
START-OF-SELECTION.
  NEW lcl_main( )->run( ).
" 6. CLASS lcl_main IMPLEMENTATION ... ENDCLASS.  (at the end)
" 7. CLASS ltcl_main DEFINITION/IMPLEMENTATION FOR TESTING (end, or test include)
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
- `SELECT SINGLE COUNT(*)` / `SELECT COUNT(*)` as an **existence check on a
  buffered table** — the `COUNT(*)` aggregate forces a DB round-trip and
  **bypasses the table buffer**, so ATC raises "SELECT bypassing table buffer"
  (Priority 2). Many config tables are buffered (e.g. `T001`, `T001W`, `T023`,
  `T134`; confirm via SE13 / Technical Settings). For an existence test, read a
  key field and check `sy-subrc` instead — that path uses the buffer:

  ```abap
  " bad  — COUNT(*) bypasses the buffer -> ATC P2
  SELECT SINGLE COUNT(*) FROM t001 WHERE bukrs = @p_bukrs.
  IF sy-dbcnt = 0. " not found

  " good — key-field read uses the buffer
  SELECT SINGLE bukrs FROM t001 WHERE bukrs = @p_bukrs INTO @DATA(lv_d).
  IF sy-subrc <> 0. " company code does not exist
  ```

  `COUNT(*)` is acceptable only on un-buffered tables (e.g. `MARA`).

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

## 24. `CALL FUNCTION` actual-parameter type compatibility

Every `CALL FUNCTION 'X'` actual parameter MUST be type-compatible with
the FM's formal parameter. Type mismatch is the single largest source of
ATC P1 findings produced by `sap-gen-abap` historically (extension-program
check / SLIN raises `CX_SY_DYN_CALL_ILLEGAL_TYPE` at runtime) — it does not
fail syntax check or activation, so it slips past `/sap-se38` and is only
caught by ATC. The 2026-05-27 `ZMMRMAT046R01` build hit this on
`GUI_UPLOAD FILENAME` (formal `STRING`, actual `IV_FILE TYPE rlgrap-filename`).

### Ground truth

Step 1.5 (`sap_rfc_lookup_fm.ps1`) writes `_fm_signatures.txt` with one
row per FM parameter:

```
FM_NAME   SECTION   PARAM_NAME   OPTIONAL   TYPE_REF   TYPE_KIND
```

Row 0 is a header; data rows follow. **`SECTION` is in CALLER perspective** —
the keyword the calling ABAP writes in `CALL FUNCTION`, already flipped from
the FM's own interface direction by `sap_rfc_lookup_fm.ps1`. So an FM IMPORT
parameter is stored under `EXPORTING` and an FM EXPORT parameter under
`IMPORTING` (e.g. `BAPI_MATERIAL_SAVEDATA HEADDATA` → `EXPORTING`, `RETURN` →
`IMPORTING`). The contract lint (`scripts/lint-abap-contract.mjs`) and
`sap_check_fm.vbs` compare this column **directly** against the caller keyword
with no further flip. Consequence for diagnosis: a `CALLFUNC_WRONG_SECTION` on
code that activates and passes ATC is a **flipped signature snapshot** (a
stale/legacy FM cache — purged via the `.cache_format` marker), NOT a linter
that "forgot to flip". Do not make the lint direction-aware; that inverts a
correct contract (`selftestDirection()` locks both halves).

`TYPE_REF` is the actual SAP type the formal parameter expects (e.g.
`STRING`, `RLGRAP-FILENAME`, `BAPI_MARA`, `MATNR`). `TYPE_KIND` is
`TAB` / `TDEF` / `TYP` / "" (none / exception).

**Generator rule**: before emitting any binding `<formal> = <actual>`,
walk `_fm_signatures.txt` and the actual's local declaration. Treat the
following as ACCEPTABLE:

1. Actual is declared `TYPE <same as formal's TYPE_REF>` (exact match).
2. Actual is declared `TYPE <data-element that resolves to the same
   underlying DOMNAME>` (compatible via DDIF).
3. Actual is declared `LIKE <ddic-field>` whose ROLLNAME = formal's
   TYPE_REF.

Treat as REJECTED — emit an adapter local instead:

1. Formal is `TYPE_REF = STRING` (or `TYPE_KIND = TYP` with TYPE_REF
   = `STRING`) but actual is a fixed-length char type (`c LENGTH n`,
   `CHARN`, `RLGRAP-FILENAME`, any DTEL of underlying type CHAR).
2. Formal is a flat numeric / date / time type and actual is `STRING`
   (the inverse — would require explicit conversion).
3. Formal is a structure type (`BAPI_MARA`) and actual is a different
   structure or a flat field.

### Adapter pattern

When rejected, emit a one-line local cast above the `CALL FUNCTION`:

```abap
" GUI_UPLOAD FILENAME is typed STRING in S/4HANA 7.52+; selection-screen
" PARAMETERS p_file TYPE rlgrap-filename gives a CHAR(128), which is
" type-incompatible. Cast through a local STRING.
DATA(lv_filename) = CONV string( p_file ).

CALL FUNCTION 'GUI_UPLOAD'
  EXPORTING filename = lv_filename
           ...
```

Equivalent classic-ABAP form when `MODE_MODERN_ABAP = FALSE`:

```abap
DATA lv_filename TYPE string.
lv_filename = p_file.
CALL FUNCTION 'GUI_UPLOAD'
  EXPORTING filename = lv_filename ...
```

### Documented common traps

Verified on S/4HANA 1909 (kernel 754, release 7.52). When emitting these
FMs, audit each actual against the formal:

| FM | Parameter | Formal TYPE_REF | Common wrong-typed actual | Adapter |
|---|---|---|---|---|
| `GUI_UPLOAD` | `FILENAME` | `STRING` | `rlgrap-filename` / `c LENGTH 128` | local `TYPE string` |
| `GUI_DOWNLOAD` | `FILENAME` | `STRING` | `rlgrap-filename` | local `TYPE string` |
| `WS_FILENAME_GET` | `DEF_PATH` / `FILENAME` | `RLGRAP-FILENAME` | `string` (modern code default) | local `TYPE rlgrap-filename` |
| `BAPI_MATERIAL_SAVEDATA` | `HEADDATA` | `BAPIMATHEAD` | custom flat structure | use real type |
| `CONVERT_DATE_TO_EXTERNAL` | `DATE_INTERNAL` | `D` (`sy-datum`) | `string` | local `TYPE d` |

When in doubt, the test that always works: copy the TYPE_REF from
`_fm_signatures.txt` verbatim into the actual's declaration.

### Checker enforcement

`/sap-check-fm` already emits `TYPE_INCOMPATIBLE` for this class
(see its README). The generator should never produce a `.abap` that
the FM checker would reject — the customer brief workflow gates this
via `MAX_PRIORITY=2` in `/sap-atc`, but P1 SLIN findings have caught
real mismatches that ATC's parameter resolver flags as type incompatible.
Generator-side avoidance is preferred over post-hoc fix loops.

## 25. `SPLIT` / text-parse targets must be character-type (file-load flows)

Every receiver of a `SPLIT … INTO` — and of any other statement that writes a
parsed text token, e.g. a manual tab-parse over a `GUI_UPLOAD char2048` line
(rule §22's file-load stage) — MUST be a character-type object: `C`, `N`,
`D`, `T`, or `STRING`. ABAP rejects a packed / numeric receiver at **syntax
check**, so it fails the `/sap-se38` deploy syntax gate before ATC ever runs
(SEVERITY `ACTIVATION`):

```
"NTGEW" must be a character-type object (C, N, D, T or STRING).
```

This bites when the spec maps a numeric file column — a `QUAN` (quantity /
weight), `CURR` (amount), `DEC`, or any packed / `P` DDIC field — and the
generator `SPLIT`s the input line **directly into a typed DDIC record
structure** whose matching component carries that numeric type. `SPLIT`
performs no conversion; it requires every target to be text.

**Generator rule**: when a SPLIT-from-text-file (or equivalent tab-parse)
flow has ANY target component that is not character-type, emit an
**all-CHARACTER staging structure**, `SPLIT` the line into that, then assign
**field-by-field** into the typed target record — the CHAR→numeric conversion
happens on the MOVE, never on the `SPLIT`.

```abap
" ❌ Activation error — ls_rec-ntgew is QUAN (packed); a SPLIT receiver
"    must be character-type.
"      "NTGEW" must be a character-type object (C, N, D, T or STRING).
DATA ls_rec TYPE zmms_material_upload.   " component ntgew TYPE ntgew (QUAN)
SPLIT lv_line AT lc_tab INTO ls_rec-matnr
                              ls_rec-maktx
                              ls_rec-ntgew     " <- packed: rejected
                              ls_rec-gewei.

" ✅ All-character staging struct for the SPLIT, then MOVE field-by-field
"    into the typed record. The packed conversion happens on each
"    assignment (CHAR -> QUAN), which the runtime does with a normal MOVE.
TYPES: BEGIN OF ty_raw,
         matnr TYPE string,
         maktx TYPE string,
         ntgew TYPE string,
         gewei TYPE string,
       END OF ty_raw.
DATA ls_raw TYPE ty_raw.
DATA ls_rec TYPE zmms_material_upload.

SPLIT lv_line AT lc_tab INTO ls_raw-matnr
                              ls_raw-maktx
                              ls_raw-ntgew
                              ls_raw-gewei.

ls_rec-matnr = ls_raw-matnr.
ls_rec-maktx = ls_raw-maktx.
ls_rec-ntgew = ls_raw-ntgew.    " CHAR -> QUAN: numeric conversion here
ls_rec-gewei = ls_raw-gewei.
```

When the staging component names match the target one-to-one, a single
`MOVE-CORRESPONDING ls_raw TO ls_rec.` is the compact equivalent — the
per-field CHAR→numeric conversion still happens on the move.

**Numeric-format caution**: the implicit CHAR→packed conversion reads `.` as
the decimal separator and tolerates a leading sign plus blanks, but it does
NOT strip thousands separators or accept a locale decimal comma. When the
spec's file format uses `1.234,56` (or `1,234.56`), normalise the staged
string first (strip / swap separators, or route through a conversion exit /
`cl_abap_…` helper) BEFORE the MOVE — otherwise activation passes but the
value parses wrong or dumps `CX_SY_CONVERSION_NO_NUMBER` at runtime.

Related: rule §22 (file-load field mapping into BAPI structures — the same
"map a spec file column into a typed target" stage, different statement) and
rule §24 (CALL FUNCTION actual/formal type compatibility — the sibling
type-compatibility codegen trap). Joins the S/4HANA 1909 strict-syntax trap
family in Claude memory `feedback_sap_gen_abap_inline_type_pitfalls`.
Confirmed live 2026-06-07 on the MaterialUpload CN `*56` build
(`ZMMRMAT056*`; NTGEW = 净重 / net weight, a QUAN field). The machine-readable
mirror is the `SPLIT_NONCHAR_TARGET` seed row in `frequently_errors.tsv`
(STMT / `*`, STATUS `CONFIRMED`), auto-injected at Step 1.5f.

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

## 26. Comment language — default to the SAP logon language

Generated ABAP **comments** — inline (`" …`), block / header banners
(`*&---…`, method headers), and the per-block explanation comments derived
from the spec supplement — default to the **SAP logon language** of the
active development session (the language the developer logged on with: `ZH`
→ Chinese, `JA` → Japanese, `EN` → English, …). This is the
`MODE_COMMENT_LANG` flag, resolved in this precedence (first hit wins):

1. An explicit user instruction for this run (e.g. "comment in English").
2. The customer brief's **Comments language** line (§6) when it names a
   language. A per-location value ("JA inline, EN headers") is honoured as
   written. A blank/absent line is NOT a specification → fall through.
3. **Default — the SAP logon language** of the active session, resolved
   from the pinned connection profile's `language` (`connections.json`) /
   `userConfig.sap_language` / `Info.Language`. If none resolves, `EN`.

Rationale: comments are **developer-facing** — the engineer reading and
maintaining the code logged on in their working language, so comments should
match it by default. This is deliberately distinct from §21 (selection texts
/ text symbols), which are **end-user-facing UI text** and MUST follow the
*spec's* natural language — do not conflate the two. Identifiers, keywords,
and literals stay ASCII / code-standard regardless; only the human-readable
comment text is localized. The one-line generation-mode header comment
(§9 / Step 0a) is itself written in `MODE_COMMENT_LANG`.

## 27. Wire every spec-mapped FM / method item end-to-end — even optional ones

When the spec maps a source item (a file-mapping row, an interface
parameter, a DDIC `table.field`, an explicit call parameter) to something
that feeds a **function module, BAPI, or method call**, the generator MUST
carry it all the way through to the call — *read it AND assign it* into the
corresponding formal parameter / structure component (and, for BAPIs, set
the matching `…X` change-structure flag and append to the correct table
parameter). This holds **even when the item is marked optional** (`〇` /
`○` / "optional" / conditional): optional means *guard the assignment*
(`IF is_row-<f> IS NOT INITIAL. … ENDIF.`), NOT *skip the mapping*.

**No "dead reads".** Parsing a field into a staging structure
(`ls_raw-<f> = value_at( … )`) and then never using it is a defect — the
field silently never reaches the FM/method, so the data is lost while the
program looks complete. Every staging-struct field that has a SAP-table /
parameter target in the spec MUST have a corresponding write into a call.

Per FM / BAPI / method the program calls:

1. Build the set of spec items mapped to that call (file-map rows whose
   `SAP_TABLE`/`SAP_FIELD` resolve to one of its parameters; interface
   inputs; explicit parameters).
2. Emit the assignment into the correct parameter — using Step 1.5 (FM
   params) + Step 1.5e (struct fields) to place it correctly (e.g.
   weight/volume → `marmdata`/`marmdatax`, not the flat client structure;
   see §22) and to type it correctly (§24). Set the BAPI `…X` flag.
3. Guard optional items with `IS NOT INITIAL`; never drop them.
4. If a mapped item genuinely cannot be placed (no matching parameter on
   any of the call's structures/tables even after Step 1.5e), emit an
   explicit `" TODO:` comment naming the item — NEVER a silent drop (§22).

This generalises §22 (right *place*) and §24 (right *type*) into a
**completeness** contract: don't forget to wire the item *anywhere at all*.
The 2026-06-07 MaterialUpload `*57` build read `brgew/ntgew/gewei/volum/
voleh` into its staging structure but never assigned them to
`BAPI_MATERIAL_SAVEDATA` (no `marmdata`/`marmdatax` table, no client-data
weight fields), so all five optional file columns were silently lost — the
exact failure mode this rule forbids.

---

## 28. Internal/external conversion at file boundaries (CONVEXIT + CURR/QUAN)

A flat file carries values in **external** representation; the database, BAPIs,
and `SELECT … WHERE` use **internal** representation. Convert at the boundary —
once — whenever the program reads or writes a file (`GUI_UPLOAD` / `GUI_DOWNLOAD`,
`READ DATASET` / `TRANSFER … TO DATASET`). Getting this wrong passes syntax,
activation, and ATC, and only surfaces as wrong data at runtime. Two distinct
mechanisms:

### 28.1 Conversion-exit fields (the `CONVEXIT` family)

A field whose domain carries a conversion routine (`DFIES-CONVEXIT`, resolved
field → data-element → domain) needs the routine applied at the boundary:

| Direction | Statement | Call |
|---|---|---|
| inbound (file → internal) | `GUI_UPLOAD`, `READ DATASET` | `CONVERSION_EXIT_<exit>_INPUT` |
| outbound (internal → file) | `GUI_DOWNLOAD`, `TRANSFER` | `CONVERSION_EXIT_<exit>_OUTPUT` |

- Apply INPUT after parsing, BEFORE any `SELECT` / BAPI / `WHERE`; apply OUTPUT
  immediately before writing. Never convert twice (e.g. ALPHA-padding an
  already-padded key) — that is a silent data bug.
- `CUNIT` (units) and `ISOLA` (language) take `LANGUAGE = sy-langu`; handle the
  `UNIT_NOT_FOUND` / `OTHERS` exceptions through the message class — never let a
  conversion FM dump.
- Resolve `<exit>` from the live DDIC (`DFIES-CONVEXIT`, surfaced in the
  `_struct_signatures.txt` cache); do not hand-roll. Common: `MATN1` (MATNR),
  `ALPHA` (KUNNR / LIFNR / KOSTL …), `CUNIT` (MEINS / units), `ISOLA` (SPRAS).

### 28.2 Amount / quantity fields (`CURR` / `QUAN` — the decimal shift)

`CURR` / `QUAN` fields carry **no** conversion exit. Their trap is the
currency- / unit-dependent **decimal shift**: a CURR amount is stored with the
field's fixed DDIC decimals (2 for classic amounts), but the real decimal count
comes from `TCURX-CURRDEC` (default 2); when they differ the stored value is
shifted by `10^(CURRDEC − 2)`. Invisible for 2-decimal currencies (USD / EUR),
**100× wrong for JPY (0 dec)**, 10× for BHD / KWD (3 dec). `QUAN` is the same,
unit-driven via `T006-DECAN`.

Rules:

- **Always carry the reference field.** A `CURR` field requires its currency
  (`CUKY`) and a `QUAN` its unit (`UNIT`), resolved via `DD03L-REFTABLE/REFFIELD`
  (surfaced as `REFTABLE` / `REFFIELD` in `_struct_signatures.txt`). The file
  must supply it, or the program must default it before the write — an amount
  without its reference is uninterpretable. e.g. `VBAP-NETPR` needs `VBAP-WAERK`.
- **Choose handling by the write target:**
  - **BAPI amount field** (`BAPICURR` / `BAPICUREXT` / `BAPICURR_D`): pass the
    parsed **external** value straight in (plus the currency key); the BAPI
    applies the shift. Do NOT call `CURRENCY_AMOUNT_DISPLAY_TO_SAP` first — that
    double-shifts.
  - **Raw DDIC `CURR` / `QUAN` write** (custom Z-table, classic non-BAPI FM,
    direct DB write): convert with `CURRENCY_AMOUNT_DISPLAY_TO_SAP` (with the
    currency) inbound / `CURRENCY_AMOUNT_SAP_TO_DISPLAY` outbound; for `QUAN` use
    `WRITE … UNIT`.
- This is distinct from §25 (`SPLIT`-into-numeric): §25 gets the *digits* into a
  packed field (char → packed parse); §28 gets the *magnitude / representation*
  right. Parse first, then convert.
- **Test data must exercise it:** a golden test for any in-scope `CURR` field
  should use a 0-decimal currency (JPY); with only USD / EUR the shift is `×10^0`
  and the bug is structurally untestable.

Enforcement: the generator (`sap-gen-abap` §1.5e.d) emits the conversions; the
checker (`sap-check-abap` Step 3.7) flags `CONV_CURR_MISSING_REF` and
`CONV_CURR_DISPLAY_TO_BAPI`; `frequently_errors.tsv` carries the machine-readable
`STMT` seeds (`CONV_EXIT_*` / `CURR_*`).

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
