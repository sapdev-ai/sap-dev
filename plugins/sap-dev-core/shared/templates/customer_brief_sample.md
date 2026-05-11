# Customer Project Brief — SAMPLE (Project: HK / S4D-100)

> This is a **filled-in example** for project `HK` / program
> `ZHKMM001R01` (Mass Creation Program for Material Master). The canonical
> spec workbook is [`spec_template.xlsx`](spec_template.xlsx). Use this
> file as a reference for what a completed brief looks like; the blank
> fillable form is in [`customer_brief.md`](customer_brief.md). Customers
> copy this file to `{custom_url}\customer_brief.md` and edit the values.

---

## 1. System

| Field | Value |
|---|---|
| ABAP release | `S/4HANA 1909` (NetWeaver 7.52) |
| Frontend | `SAP GUI 7.60` (rich client; Fiori not in scope for this project) |
| Unicode | `Yes (codepage 4110)` |
| Dev system codepage | `JA 4110` |
| Logon language(s) developers use | `JA`, `EN` (mixed team) |
| Logon language(s) end-users use | `JA` |
| Time zone of dev system | `Asia/Tokyo (UTC+9)` |

---

## 2. Namespace & objects

| Field | Value |
|---|---|
| Customer namespace | `Z` |
| Project sub-prefix | `ZHK` |
| Default workbench package | `ZHKA011` |
| Default customizing package | `ZHKC011` |
| Default function group | `ZHKFG01` |
| Default message class | `ZHKMSG01` |

---

## 3. Reusable utilities

| Name | Type | Purpose |
|---|---|---|
| `ZCL_HK_LOGGER` | class | Project-wide application log wrapper. **Always reuse — do not re-implement.** Method: `log( iv_pgm iv_msgtyp iv_text )` |
| `ZCL_HK_FILE_READER` | class | CSV / fixed-width / TSV reader with codepage-aware UTF-8 fallback. Use this instead of raw `GUI_UPLOAD`. |
| `ZCL_HK_BAPI_RESULT` | class | Wraps `BAPIRET2` tables; provides `is_error()` / `to_alv()` / `commit_or_rollback()`. |
| `Z_HK_GET_PLANT_DATA` | FM | Reads `T001W` with session-level caching. Use instead of repeated `SELECT * FROM T001W`. |
| `ZCX_HK_FILE_NOT_FOUND` | exception class | File I/O errors |
| `ZCX_HK_VALIDATION_ERROR` | exception class | Per-row validation failures (carries the BAPIRET2 table) |
| `ZCX_HK_BAPI_ERROR` | exception class | BAPI invocation errors |

---

## 4. Volumes & performance hints

| Object kind | Volume band | Notes |
|---|---|---|
| Online transactions | `small` (<1k) | Single-record screens (ZHKMM002/003) |
| Reports | `medium` (1k–100k) | Daily inventory queries (ZHKMM010R01) |
| **Batch jobs** | `large` (>100k) | **Material upload (ZHKMM001R01) — typical month-end run = 50k–200k rows. Use `PACKAGE SIZE 5000` + COMMIT every package.** |
| Interfaces (in/out) | `medium` | Daily IDoc inbound from MES |

---

## 5. Authorization

| Functional area | Authz object | Activities used | Notes |
|---|---|---|---|
| MM (materials) | `M_MATE_MAR` | 01 (Create), 02 (Change), 03 (Display) | Material-type-level |
| MM (plants) | `M_MATE_WRK` | 01, 02, 03 | Plant-level filter |
| MM (industry sector) | `M_MATE_MAT` | 01, 02 | Used by `BAPI_MATERIAL_SAVEDATA` internally — no explicit check needed in our code |
| FI (postings) | `F_BKPF_BUK` | 02, 03 | Out of scope for ZHKMM001 but applies to ZHKFI* |
| Custom | `Z_HK_BATCH` | 16 (Execute) | Project-specific gate for batch jobs run outside SM37 |

**For ZHKMM001R01 specifically:** check `M_MATE_MAR` ACTVT 01 + 02, and
`M_MATE_WRK` ACTVT 01 + 02 with the plant from each input row.

---

## 6. Quality bar

| Field | Value |
|---|---|
| ABAP Unit tests required? | `yes (mandatory)` — every public method needs at least one test, golden I/O drives the assertions |
| ATC must pass? | `priority 1+2 are gating` (i.e. `MAX_PRIORITY = 2` in `/sap-atc`) |
| Modern ABAP syntax (`DATA(...)`, `VALUE #( )`)? | `yes` — release 7.52 supports it |
| OOP scaffolds for new programs? | `yes` (lcl_main + run/build/validate/execute/persist) |
| Change document logging required for persistence? | `yes` for all FI/CO objects; `no` for MM in this project (the BAPI handles it) |
| Maximum method length (lines)? | `50` (default) — checker emits `METHOD_TOO_LONG` warning beyond this |
| Naming prefix override? | `none` — use the default `abap_naming_rules.tsv` |
| File encoding for ABAP source uploads? | `UTF-8 without BOM` (Unicode SAP — codepage 4110) |
| Comments language | `JA OK` for in-line; **English required for method headers and exception class doc** so off-shore reviewers can read them |

---

## 7. Per-spec contract reminder

For every new design spec, ensure it contains the **4 boxed sections** (in
any document format — Word, Excel, PDF):

1. **Interface contract** — Inputs / Outputs / Exceptions (typed)
2. **Validation rules** — numbered, each → `MSG_CLASS-MSGNO`
3. **Processing flow** — numbered steps, one verb per step
4. **DDIC objects** — table of name / type / length / data element

See [`spec_template.xlsx`](spec_template.xlsx) for the canonical workbook
structure.

---

## 8. Test cases per spec — example

For ZHKMM001R01, the spec's Golden I/O Test sheet provides 7 golden I/O rows
(see the Excel template). The generator emits `ZHKMM001R01_TEST.abap` with
one `test_*` method per row. The checker fails the build if ABAP Unit
returns any `assert_*` failure.

---

## 9. Project-specific overrides (rare)

| Field | Value |
|---|---|
| `ZCX_<PROJ>_ERROR` class name | `ZCX_HK_ERROR` |
| Project ALV variant for output | `/HK_DEFAULT` |
| Standard cursor for batch programs | `WITH HOLD` (allows COMMIT inside loop) |
| Logging table | `ZTHKLOG` (project-wide; per-program tables like `ZTHKMATLOG` are also OK and write into `ZTHKLOG` via `ZCL_HK_LOGGER`) |

---

## How this is consumed by the skills

- `/sap-docs-extract` reads spec + this brief → emits `_PGM_summary.txt`,
  `_process.txt`, etc.
- `/sap-gen-abap` reads MODE flags from this brief and emits release-aware
  modern ABAP, OOP scaffolds, ABAP Unit tests, dependency + traceability
  files.
- `/sap-check-abap` uses the quality bar to decide which findings block
  deployment.
- `/sap-atc` reads `MAX_PRIORITY = 2` and gates accordingly.

---

## How to use this sample

1. Copy this file to `{custom_url}\customer_brief.md` for your project.
2. Replace HK-specific values with your project's values.
3. Drop fields that don't apply (or keep them blank — generator falls back
   to safe defaults).
4. Commit it alongside your repository so every developer + skill picks it
   up automatically.
