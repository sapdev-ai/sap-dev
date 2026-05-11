# DDIC Excel Layout Rules — How to write a spec that creates cleanly in SE11

Based on real bugs found in customer specs (see
[`check_result_ddic.txt`](#) examples). Apply these rules to **any DDIC
spec sheet** (Excel, Word, or otherwise) so `/sap-docs-extract` →
`/sap-docs-check-ddic` → `/sap-se11` runs without manual fixes.

---

## Rule 1 — One canonical naming scheme per spec, decided up front

The single most common bug: **suffix typos on Z-namespace names**. Real
example from a customer spec:

```
Domains:        ZHKDM_KEY131   ZHKDM_VAL131   ZHKDM_AMT13
Data elements:  ZHKDE_KEY131 → DOMNAME = ZHKDM_KEY13   ❌ (no trailing 1)
                ZHKDE_VAL131 → DOMNAME = ZHKDM_VAL13   ❌
```

→ SE11 fails: `Domain ZHKDM_KEY13 does not exist`.

**How to prevent**:
- Write the project naming scheme **once** in the brief:
  `Z<PROJ><CATEGORY>_<NAME><INSTANCE>` and stick to it
  (e.g. `ZHK` + `DM` + `_KEY13` for project HK, instance 13)
- Use Excel **named ranges** for domain names — when you reference a
  domain in the DTEL row, point at the cell instead of re-typing
- Even better: use **data validation** (dropdown) on the DTEL.DOMNAME
  column populated from the Domain sheet column A. Typos become
  impossible — see `spec_template.xlsx` for the data-validation
  setup.

---

## Rule 2 — DATAELEMENT column must contain real data elements only

A primitive DDIC type (e.g. `CHAR`, `NUMC3`, `DATS`) is **not** a data
element. SE11 rejects it. Real example from a customer spec:

```
| No | FIELDNAME | KEY | INITIAL | DATAELEMENT | ...
| 3  | SEQ       | X   | X       | NUMC3       | ...    ❌
```

→ SE11: `Data element NUMC3 does not exist`.

**How to prevent**:
- Treat the DATAELEMENT column as a **strict reference** — only put
  names of actual data elements (yours from the same spec, or standard
  SAP elements like `MANDT`, `MATNR`, `WAERK`)
- For fields that need a primitive type without a data element, the
  proper SAP pattern is still to wrap it in a data element:
  ```
  Domain:        ZHKDM_SEQ        NUMC  3
  Data element:  ZHKDE_SEQ        ZHKDM_SEQ        Seq No
  Table field:   SEQ              ZHKDE_SEQ
  ```
- If your team really wants direct primitive types in tables, use SAP's
  **Built-In Type** (`Predefined Type`) feature in SE11 instead. That
  needs different columns in the spec — request the
  `BUILT_IN_TYPE / LENGTH / DECIMALS` triplet from the customer.

---

## Rule 3 — Reference table for currency / quantity fields

For a CURR field on S/4HANA, **both** `ReferenceTable` and `Ref.Field`
must be populated, including the self-referencing case where the WAERK
column lives in the same table being defined:

1. **WAERK in the same table** — set `ReferenceTable=<this table's name>`
   and `Ref.Field=WAERK`. (Older NetWeaver-era convention permitted
   leaving `ReferenceTable` blank for the same-table case; that is
   deprecated and SE11 on S/4HANA refuses to activate the table with
   "specify reference table AND reference field".)
2. **WAERK in a different table** — set `ReferenceTable=<other table>`
   and `Ref.Field=<the WAERK field name there>`.

Correct example:

```
| 10 | AMT  | ... | ZHKDE_AMT13 | ZHKFIXEDVALS13 | WAERK |
| 11 | WAERK| ... | WAERK       |                |       |
```

The CURR field references `ZHKFIXEDVALS13` (the same table being
defined) — both `ReferenceTable` and `Ref.Field` are populated.

Same pattern for **QUAN** fields (reference to a UNIT field — both
columns required).

Rule inverted on 2026-05-09 after a real deployment surfaced the
contradiction; aligned with `sap-docs-check-ddic` SKILL.md Step 4b-2.

---

## Rule 4 — Mandatory column order on every DDIC sheet

`/sap-docs-extract` parses by column position with header sniffing.
Stick to these exact column orders so extraction is reliable:

### Domain sheet (header row contains `Domain name` + `DATATYPE`)

| Domain name | Short description | DATATYPE | LENGTH | DECIMALS | SIGN | LOWERCASE | OUTPUT_LENGTH | CONV_ROUTINE |

### Data Element sheet (can be a separate sheet OR a section below domains; header row contains `Data element name` + `DOMNAME`)

| Data element name | Short description | DOMNAME | LABEL_SHORT | LABEL_MEDIUM | LABEL_LONG | LABEL_HEADING |

### Table sheet — metadata block first, then fields

```
Table name        ZTHKMATLOG
Short description Material upload log
Delivery class    A
Data class        APPL1
Size category     1

FIELDS
No  FIELDNAME  KEY  INITIAL  DATAELEMENT  ReferenceTable  Ref.Field
1   MANDT      X    X        MANDT
...
```

`/sap-docs-extract` recognises the `FIELDS` keyword to switch from
metadata mode into field-list mode.

---

## Rule 5 — One header style, one font, no merged cells in data rows

Cosmetic, but it wrecks extraction:

- **Don't merge cells in the data rows.** Header rows can be merged for
  visual hierarchy, but each data row must be one cell per column.
  Merged cells cause `openpyxl` to read `None` for all but the
  top-left cell, dropping data silently.
- **One font / one row height per data row.** Mixing tall rows with
  wrapped text and short rows confuses some parsers.
- **No empty rows inside a section.** Use a clearly-marked separator
  (e.g. an entirely blank row, then a new section header) so the
  extractor's "blank-row = section break" heuristic works.

---

## Rule 6 — Use Excel data validation (dropdowns) where possible

Built into Excel, no plugins, customers' BAs already know how. Cuts
typo-class errors to near zero.

| Column | Validation source | Effect |
|---|---|---|
| Domain DATATYPE | List of valid types: `CHAR,NUMC,DATS,TIMS,DEC,CURR,QUAN,UNIT,LANG,CLNT,INT1,INT2,INT4,INT8,FLTP,STRING,SSTRING,RAWSTRING,RAW,ACCP` | Customer can't invent a type |
| DTEL DOMNAME | `=Domains!$A$5:$A$50` (the domain name column) | Customer can't typo a domain reference |
| Field DATAELEMENT | `=DataElements!$A$11:$A$60` plus a small whitelist of standard elements (MANDT, MATNR, WAERK, …) | Customer can't put a primitive type here |
| KEY / INITIAL | `X,(blank)` | Single-character flag |
| Delivery class | `A,C,L,G,E,S,W` | Standard SAP set |
| Data class | `APPL0,APPL1,APPL2,USR,USR1` | Standard SAP set |
| Size category | `0,1,2,3,4` | Standard SAP set |

The shipped [`spec_template.xlsx`](spec_template.xlsx) has these
validations pre-applied. Tell customers: "Open the template, look at
the dropdowns, and use it as your model."

---

## Rule 7 — Add a self-check sheet (optional, high-value)

Add an `(Auto) Self-check` sheet with a few `COUNTIF` / `MATCH`
formulas that turn red when something is wrong. Three formulas catch
80% of bugs:

```
A1: "DTEL DOMNAME refs missing in Domains:"
A2: =SUMPRODUCT(--(ISNA(MATCH(DataElements!C11:C60, Domains!A5:A50, 0))) *
                (DataElements!C11:C60 <> ""))
    (red if > 0 — same bug as Rule 1)

A4: "Primitive types in field DATAELEMENT:"
A5: =SUMPRODUCT(--ISNUMBER(SEARCH({"NUMC","CHAR","DATS","TIMS"},
                                  Tables!E24:E60)))
    (red if > 0 — same bug as Rule 2)

A7: "Self-referencing Reference Table:"
A8: =SUMPRODUCT(--(Tables!F24:F60 = Tables!$B$16))
    (warning if > 0 — same as Rule 3)
```

Customer sees the red number before they hand the spec over. We see
zero typos. Cheap win.

---

## Rule 8 — Standard SAP elements in the Z spec

Some fields legitimately use standard SAP elements (`MANDT`, `MATNR`,
`WAERK`, `PROGNAME`, `BUKRS`). The check skill exempts these by name.
**Do NOT** invent new local "wrappers" for standard elements unless
your project standard requires it — adds maintenance burden for no
benefit.

Ship a small `_standard_elements.tsv` list with the spec template so
the extractor / checker can distinguish "missing Z-element" from
"intentional standard SAP reference".

---

## Rule 9 — Number every row, even when blank

Every DDIC sheet has a `No.` column. Customers sometimes leave gaps
when reordering. The extractor is positional within the FIELDS block,
so a missing `No.` row makes the gap silently skipped (or worse,
shifts the keys of subsequent rows).

**Fix**: number every row sequentially with no gaps. If a row is
deleted, renumber.

---

## Rule 10 — Hand the customer this checklist (1 page) before they start

Print this list on a single A4 page and attach to the
`customer_brief.md`:

> **Before you submit a DDIC sheet, verify**:
> - [ ] Every `DOMNAME` referenced in the Data Element rows is also in
>   the Domain rows (or is a known standard SAP domain).
> - [ ] Every `DATAELEMENT` in the Table FIELDS is a real data element
>   (yours or standard) — never a primitive type like `NUMC3`.
> - [ ] CURR fields: BOTH `ReferenceTable` and `Ref.Field=WAERK`
>   populated — for same-table WAERK, set `ReferenceTable=<this table>`;
>   for cross-table, set the other table name. Same pattern for QUAN/UNIT.
> - [ ] All keys (`KEY=X`) come first in the FIELDS list.
> - [ ] `MANDT` is the first key field for client-dependent tables.
> - [ ] Naming suffix is consistent across Domain / DTEL / Table names
>   in the same spec.
> - [ ] No merged cells in data rows.
> - [ ] No gap in the `No.` column.

---

## Pipeline reminder

After fixing per this checklist:
```
/sap-docs-extract     <work_folder>
/sap-docs-check-ddic  <work_folder>          ← catches the rules above
/sap-se11 STRUCTURE   <name> <def_file>
/sap-se11 TABLE       <name> <def_file>
```

Errors found by `/sap-docs-check-ddic` block deployment by default —
fix in the spec, re-run extract + check, then deploy.
