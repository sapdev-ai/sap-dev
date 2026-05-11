# Customer Project Brief — One-Page Form

This is the **minimum information** a customer must provide once per project so
the AI generates high-quality, deploy-ready ABAP. It does NOT replace design
specifications — it gives the generator the *project context* that is shared
across every spec.

Hand this form to the customer's project lead or BA. Most fields take 10 minutes
to fill; the rest can be marked "TBD — confirm with basis/security team" and
filled later. **No need to learn a new template; this brief sits alongside
whatever document format the customer already uses.**

> 💡 **See [`customer_brief_sample.md`](customer_brief_sample.md) for a
> filled-in example.** The canonical spec workbook
> [`spec_template.xlsx`](spec_template.xlsx) is the structural reference.
> Easier than filling a blank form from scratch — copy the sample, swap
> the values.

---

## 1. System

| Field | Example | Your value |
|---|---|---|
| ABAP release | `7.40 SP08` / `7.52` / `7.55` / `S/4HANA 1909` / `ABAP Cloud` | |
| Frontend | `SAP GUI 7.60` / `Fiori` / `SAPUI5` / `WebDynpro` | |
| Unicode | `Yes (codepage 4110)` / `No (Windows codepage <X>)` | |
| Dev system codepage | `JA 4110` / `EN 1100` / ... | |
| Logon language(s) developers use | `JA`, `EN`, `ZH` | |
| Logon language(s) end-users use | `JA`, `EN`, `ZH` | |
| Time zone of dev system | `Asia/Tokyo (UTC+9)` | |

---

## 2. Namespace & objects

| Field | Example | Your value |
|---|---|---|
| Customer namespace | `Z` / `Y` / registered prefix `/MYCO/` | |
| Project sub-prefix | `ZHK` / `ZFI` / `ZSD` (max 3 chars) | |
| Default workbench package | `ZHKA011` | |
| Default customizing package | `ZHKC011` | |
| Default function group | `ZHKFG01` | |
| Default message class | `ZHKMSG01` | |

---

## 3. Reusable utilities (write "none yet" if empty)

List **existing** Z classes / FMs / RFC wrappers / interfaces the AI should
prefer over re-implementing the same logic. Even one line per item is enough.

| Name | Type | Purpose |
|---|---|---|
| `ZCL_HK_LOGGER` | class | application log wrapper |
| `Z_HK_GET_PLANT_DATA` | FM | reads T001W with caching |
| ... | ... | ... |

---

## 4. Volumes & performance hints

For each kind of object (online tx vs report vs batch vs interface), give one
band — that is enough to pick `SELECT SINGLE` vs `INTO TABLE` vs `PACKAGE SIZE`.

| Object kind | Volume band (`small <1k` / `medium 1k–100k` / `large >100k`) | Notes |
|---|---|---|
| Online transactions | small | per single record |
| Reports | medium | typical month-end run |
| Batch jobs | large | overnight |
| Interfaces (in/out) | medium | per file |

---

## 5. Authorization

Even just the AUTHORITY-CHECK objects relevant to this functional area is huge.

| Functional area | Authz object | Activities used |
|---|---|---|
| MM (materials) | `M_MATE_WGR` | 01, 02, 03 |
| FI (postings) | `F_BKPF_BUK` | 02, 03 |
| ... | ... | ... |

---

## 6. Quality bar

| Field | Pick |
|---|---|
| ABAP Unit tests required? | `yes (mandatory)` / `nice to have` / `no` |
| ATC must pass? | `yes (priority 1+2 are gating)` / `priority 1 only` / `no` |
| Modern ABAP syntax (`DATA(...)`, `VALUE #( )`) acceptable? | `yes` / `no — classic only` |
| OOP scaffolds acceptable for new programs? | `yes` / `prefer FORM routines` |
| Change document logging required for persistence? | `yes` / `no` |
| Maximum method length (lines)? | `50` (default) / `100` / no limit |

---

## 7. Per-spec contract (smaller form, repeated per spec)

When a customer hands over a new design spec, ask for **just these 4 boxed
sections inside their existing document** (no template change required):

1. **Interface contract** — Inputs / Outputs / Exceptions (typed if possible)
2. **Validation rules** — numbered, each pointing at `<MSG_CLASS>-<MSGNO>`
3. **Processing flow** — numbered steps, one verb per step
4. **DDIC objects** — table of name / type / length / data element

These four are the bare minimum the AI needs to generate code without
guessing. Sell it as "keep your format, just add 4 boxes."

---

## 8. Test cases per spec (golden I/O)

Per validation rule, 2–3 rows of "given input X, expect Y / error Z". The
business analyst already has these in their head. Format suggestion:

```
Rule 3: registration_type must be I or U
  - input: registration_type=A → ERROR ZHKMSG01-001
  - input: registration_type=I → OK
  - input: registration_type=U → OK
```

---

## How this is consumed by the skills

- `/sap-docs-extract` reads spec + brief; emits `_PGM_summary.txt`,
  `_process.txt`, etc.
- `/sap-gen-abap` uses the brief to pick: modern vs classic syntax, OOP vs
  FORM scaffold, DDIC type vs base type, perf band → SQL pattern.
- `/sap-check-abap` uses the brief's quality bar to decide which findings
  block deployment.
- The brief lives at `{custom_url}\customer_brief.md` (per-project override
  of the default at `<SAP_DEV_CORE_SHARED_DIR>/templates/customer_brief.md`).
