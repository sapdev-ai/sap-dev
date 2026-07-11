# FI posting definition file — grammar & templates

Tab-delimited `SECTION<TAB>FIELD<TAB>VALUE` triples (`#` comments, blank lines
skipped). One `HEADER` section plus ≥2 item sections. The skill **generates the
`CURRENCYAMOUNT` rows itself** from each item's `AMOUNT` (positive = debit,
negative = credit) with `ITEMNO_ACC` = the section's `NN` suffix — you never
hand-maintain the ITEMNO cross-reference. Balance must be 0 per currency.

## Sections

| Section | Maps to BAPI table | Key fields |
|---|---|---|
| `HEADER` | `DOCUMENTHEADER` | `COMP_CODE`, `DOC_DATE`, `PSTNG_DATE`, `DOC_TYPE`, `CURRENCY` (required); `REF_DOC_NO`, `HEADER_TXT`, `BUS_ACT` (default `RFBU`); `USERNAME` auto = RFC user |
| `GL_NN` | `ACCOUNTGL` | `GL_ACCOUNT`, `ITEM_TEXT`, `COSTCENTER`, `PROFIT_CTR`, `AMOUNT`, [`CURRENCY`] |
| `AP_NN` | `ACCOUNTPAYABLE` | `VENDOR_NO`, `ITEM_TEXT`, `AMOUNT` |
| `AR_NN` | `ACCOUNTRECEIVABLE` | `CUSTOMER`, `ITEM_TEXT`, `AMOUNT` |
| `TAX_NN` | `ACCOUNTTAX` | `TAX_CODE`, `GL_ACCOUNT`, `AMOUNT` |

`NN` (the suffix after the underscore) must be unique across all item sections —
it becomes `ITEMNO_ACC`. Amounts are in document currency; a per-item `CURRENCY`
overrides the header currency.

## template gl — balanced G/L document (FB01 / doc type SA)

```
HEADER	COMP_CODE	1000
HEADER	DOC_DATE	20260711
HEADER	PSTNG_DATE	20260711
HEADER	DOC_TYPE	SA
HEADER	CURRENCY	EUR
HEADER	HEADER_TXT	test G/L posting
GL_01	GL_ACCOUNT	400000
GL_01	ITEM_TEXT	debit line
GL_01	COSTCENTER	1000
GL_01	AMOUNT	100.00
GL_02	GL_ACCOUNT	113100
GL_02	ITEM_TEXT	credit line
GL_02	AMOUNT	-100.00
```

## template fb60 — vendor invoice (doc type KR)

```
HEADER	COMP_CODE	1000
HEADER	DOC_DATE	20260711
HEADER	PSTNG_DATE	20260711
HEADER	DOC_TYPE	KR
HEADER	CURRENCY	EUR
HEADER	REF_DOC_NO	INV-0001
AP_01	VENDOR_NO	0000100000
AP_01	ITEM_TEXT	vendor invoice
AP_01	AMOUNT	-100.00
GL_02	GL_ACCOUNT	400000
GL_02	ITEM_TEXT	expense
GL_02	COSTCENTER	1000
GL_02	AMOUNT	100.00
```

## template fb70 — customer invoice (doc type DR)

```
HEADER	COMP_CODE	1000
HEADER	DOC_DATE	20260711
HEADER	PSTNG_DATE	20260711
HEADER	DOC_TYPE	DR
HEADER	CURRENCY	EUR
HEADER	REF_DOC_NO	AR-0001
AR_01	CUSTOMER	0000100000
AR_01	ITEM_TEXT	customer invoice
AR_01	AMOUNT	100.00
GL_02	GL_ACCOUNT	800000
GL_02	ITEM_TEXT	revenue
GL_02	AMOUNT	-100.00
```

> Replace the company code / accounts / vendor / customer with values that exist
> in your target client (run `check` first — it is a real server-side dry-run and
> reports exactly what is missing). Automatic tax calculation is out of scope in
> v1: post tax-free or add explicit `TAX_NN` lines.
