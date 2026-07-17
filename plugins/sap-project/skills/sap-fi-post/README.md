# sap-fi-post

**Post FI accounting documents (FB01 G/L, FB60 vendor invoice, FB70 customer invoice) from
a tab-delimited definition file** via `BAPI_ACC_DOCUMENT_*` — standalone test data or the
settlement tail of O2C/P2P scenarios. This is a WRITE skill with a mandatory server-side
dry-run and a confirm gate; nothing posts without both.

```
/sap-fi-post post <def-file>                  # dry-run → confirm → post → verify
/sap-fi-post check <def-file>                 # dry-run only, persists nothing
/sap-fi-post show <BELNR> <BUKRS> <GJAHR>     # read-only document display
/sap-fi-post template <gl|fb60|fb70> [<out>]  # pure local, copies a definition shape
```

## What it does

- **Validates locally first** (balance = 0 per currency, unique ITEMNO, required HEADER
  fields), with an optional best-effort preflight that turns opaque CHECK errors into
  "account X not created in BUKRS Y" — a hint, never a blocker.
- **Auto-generates the CURRENCYAMOUNT / ITEMNO cross-references** from each item's AMOUNT
  (positive = debit, negative = credit), defusing the top semantic trap of the ACC BAPIs.
- **Dry-runs server-side** — `BAPI_ACC_DOCUMENT_CHECK` (zero persistence) surfaces every
  posting error (account blocked, period closed, unbalanced, substitution) as structured
  BAPIRET2 BEFORE anything is committed, for both `check` and `post`.
- **Posts and verifies** — `BAPI_ACC_DOCUMENT_POST` → `BAPI_TRANSACTION_COMMIT`, then an
  authoritative BKPF (exactly 1 row) + BSEG re-read; the BAPI RETURN is never trusted alone.
- **Appends a created-document manifest** (`{artifact_dir}\testdata\fi_documents.jsonl` —
  sid, client, belnr, bukrs, gjahr … the reversal keys) for cleanup tooling.
- **`show`** renders the BKPF header + BSEG lines from narrow reads — read-only, no gates.

## Safety gates

- A failing CHECK **stops** the post (`FIPOST_CHECK_FAILED`) — no document the CHECK did
  not first validate is ever created.
- The **confirm gate** states system/client, company code, posting date, item count and
  total, and requires a yes/no; on a **production** client (T000 `CCCATEGORY=P`) it
  escalates to a typed `POST`. Declining means zero SAP writes.
- Any post-stage error triggers `BAPI_TRANSACTION_ROLLBACK`; a green RETURN with a
  disagreeing re-read is `FIPOST_VERIFY_FAILED` — a failed or rolled-back post is never
  rendered as done.
- Postings the BAPI cannot express (one-time accounts, special G/L) are routed to
  `/sap-call-bdc` by recommendation only — never auto-run.

## Calls & prerequisites

`BAPI_ACC_DOCUMENT_CHECK` / `_POST`, `BAPI_TRANSACTION_COMMIT` / `_ROLLBACK`, BKPF/BSEG
re-reads (BSEG with a narrow FIELDS list — it is CLUSTER on ECC). All FMs remote-enabled on
S/4HANA 1909 + ECC 6. Pure RFC off the pinned `/sap-login` profile (SAP NCo 3.1, 32-bit)
with FI posting authorization (F_BKPF_BUK) — no GUI, no Z objects, no transports. The
definition-file grammar + three template shapes live in
`references/fi_post_def_grammar.md`.

Out of scope in v1: automatic tax calculation (post tax-free or explicit `TAX_NN` lines)
and `reverse` (v2 cleanup tooling — the manifest already records the reversal keys); an
ACDOCA cross-check is v1.5. Config gaps (closed period, number range, substitution) surface
as BAPIRET2, faithfully rendered, never silently retried.
