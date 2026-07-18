---
name: sap-fi-post
description: |
  Posts FI accounting documents (FB01 G/L, FB60 vendor invoice, FB70 customer
  invoice) from a tab-delimited definition file via BAPI_ACC_DOCUMENT_* RFCs — for
  standalone test data or the settlement tail of O2C/P2P scenarios. A mandatory
  server-side dry-run (BAPI_ACC_DOCUMENT_CHECK) surfaces every posting error
  (account blocked, period closed, unbalanced, substitution) as structured BAPIRET2
  BEFORE anything is committed; then a confirm-gated POST + BAPI_TRANSACTION_COMMIT,
  verified by an authoritative BKPF/BSEG re-read (never trusted from the BAPI RETURN
  alone). The skill auto-generates the CURRENCYAMOUNT / ITEMNO cross-references from
  each item's AMOUNT (positive=debit, negative=credit), defusing the top semantic
  trap. Pure RFC (all FMs remote-enabled on S/4HANA 1909 + ECC 6) — no GUI, no Z
  objects, no transports. Appends a created-document manifest for cleanup tooling.
  Prerequisites: SAP profile via /sap-login (RFC) with FI posting authorization
  (F_BKPF_BUK); SAP NCo 3.1 (32-bit). Postings the BAPI can't express are routed to
  /sap-call-bdc by recommendation, never auto-run.
argument-hint: "post <def-file> | check <def-file> | show <BELNR> <BUKRS> <GJAHR> | template <gl|fb60|fb70> [<out-file>]"
---

# SAP FI Posting Skill

You post FI documents from a definition file — **dry-run first, confirm, post,
verify by re-read**. You never trust the BAPI RETURN alone, and you never create a
document the CHECK did not first validate.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` + `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_safety_gate.ps1` | Rule 0 | Environment guard — Step 5 runs `-Action assert` before the write |
| `<SKILL_DIR>/references/sap_fi_post_rfc.ps1` | `-Action check\|post\|show\|preflight -DefFile <f>` | BAPI backend (check/post/verify) |
| `<SKILL_DIR>/references/fi_post_def_grammar.md` | read by `template` | Definition-file grammar + 3 template shapes |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | Manifest + evidence-pack registration |
| `/sap-login` | sub-skill | Pinned RFC profile |
| `/sap-call-bdc` | sub-skill | Recommended fallback for BAPI-inexpressible postings (never auto-run) |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging
(`sap_log_helper.ps1`, state `{RUN_TEMP}\sap_fi_post_run.json`). **No GUI session
needed** — pure RFC off the pinned profile.

## Step 1 — Parse & Dispatch

Modes: `post` / `check` / `show` / `template` (`reverse` → v2, refuse with the
roadmap note). `template <gl|fb60|fb70> [<out>]` copies the matching shape from
`fi_post_def_grammar.md` into the target file and STOPs (pure local, no SAP).

## Step 2 — RFC Profile

Pinned RFC profile required (`/sap-login`). Say explicitly that no GUI session is used.

## Step 3 — Preflight (optional, best-effort)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_fi_post_rfc.ps1" -Action preflight -DefFile "<def>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Renders `FIPOST: preflight comp_code=.. exists=YES|NO`, `gl_account/vendor/customer
in_bukrs=YES|NO` — turns opaque CHECK errors into "account X not created in BUKRS Y".
A failed preflight is a hint, never a blocker.

## Step 4 — Dry-run (CHECK) — always, for both `check` and `post`

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_fi_post_rfc.ps1" -Action check -DefFile "<def>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

The backend does the local validation (balance=0 per currency, unique ITEMNO,
required HEADER fields) THEN `BAPI_ACC_DOCUMENT_CHECK` (zero persistence). Read the
`BAPIRET:` lines + `FIPOST: check ... verdict=CLEAN|ERRORS` + STATUS.

- `INPUT_INVALID` / `UNBALANCED` → show the offending lines, STOP.
- `check` mode → report the verdict + BAPIRET2 table, log end, STOP (no confirm needed
  — CHECK persists nothing).
- `post` mode with `verdict=ERRORS` → STOP (`FIPOST_CHECK_FAILED`), explain the
  messages and propose fixes; if the failure is BAPI-inexpressible (one-time account,
  special G/L), recommend `/sap-call-bdc` with an FB01 recording — **do not auto-run it**.

## Step 5 — Confirm Gate (`post` only, mandatory)

**Rule 0 first** (`safety_policy.md`; `post` only — `check`/`show`/`template` skip it):
`powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-fi-post` —
`SAFETY: ALLOW` (0) proceed; `TYPED_CONFIRM_REQUIRED` (3) -> the operator types the shown
`PROD <SID>/<CLIENT>` token, re-run with `-ConfirmationText '<their verbatim answer>'`, proceed only
on `ALLOW_CONFIRMED`; `REFUSED class=<C>` (1) / `ERROR` (2) -> **STOP**, end `FAILED` with
`-ErrorClass <C>`, relay the remediation lines — never bypass or work around it manually. The typed `POST` escalation and yes/no gate below still apply after ALLOW/ALLOW_CONFIRMED.

State it plainly and get a yes/no:

> I will POST a `<DOC_TYPE>` document in `<SID>/<CLIENT>`, company code `<BUKRS>`,
> posting date `<PSTNG_DATE>`, `<n>` line items, total debit `<amount> <CURRENCY>`.
> This writes a real FI document. Proceed? (yes/no)

On a **production** client (T000 `CCCATEGORY=P`) escalate to a typed `POST`. Decline
→ log `SKIPPED`, STOP (zero SAP writes).

## Step 6 — POST (verified)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_fi_post_rfc.ps1" -Action post -DefFile "<def>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

The backend re-runs CHECK (state may have moved), then `BAPI_ACC_DOCUMENT_POST` →
parses `OBJ_KEY` (BELNR+BUKRS+GJAHR) → `BAPI_TRANSACTION_COMMIT WAIT='X'` → **re-reads
BKPF (exactly 1 row) + BSEG** to verify. Any post-stage error → `BAPI_TRANSACTION_ROLLBACK`.

Read `FIPOST: POSTED belnr=.. bukrs=.. gjahr=..` + STATUS:
- `OK` → the document is verified in BKPF/BSEG. Report BELNR/BUKRS/GJAHR; mention FB03
  for manual display. (`bseg_rows < items` prints a WARN — S/4 document splitting can
  add lines; that is not a failure.)
- `POST_FAILED` (rolled back) / `VERIFY_FAILED` (BKPF/BSEG re-read disagreed) → FAILED,
  show the exact BAPIRET2 message. **Never render a failed/rolled-back post as done.**

## Step 7 — Manifest + Register

Append one JSONL record per posted document to
`{artifact_dir}\testdata\fi_documents.jsonl` (schema `sapdev.testdata_fi/1`: sid,
client, belnr, bukrs, gjahr, blart, budat, run_id — carries the reversal keys). Register
the check + verify TSVs (`Register-SapArtifact -Kind fi_post_check` / `testdata_fi_document`,
verdict GO on a verified post).

## show mode

`-Action show -Belnr <B> -Bukrs <C> -Gjahr <Y>` → renders the BKPF header + BSEG lines
(KOART/SHKZG/WRBTR/HKONT/LIFNR/KUNNR) from narrow reads. Read-only, no gates.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Map: `FIPOST_INPUT_INVALID` /
`FIPOST_UNBALANCED` / `FIPOST_CHECK_FAILED` / `FIPOST_POST_FAILED` / `FIPOST_VERIFY_FAILED`.

---

## Scope & Limitations (v1)

- **v1:** `post` (dry-run → confirm → post → verify), `check`, `show`, `template` (gl/fb60/fb70).
- **Phase 2:** ACDOCA universal-journal cross-check (v1.5, S/4-only, DD02L-gated);
  `reverse` via BAPI_ACC_DOCUMENT_REV_POST (v2 cleanup tooling — the manifest already
  records the reversal keys).
- **The dry-run is real:** `BAPI_ACC_DOCUMENT_CHECK` is a genuine server-side simulate with
  zero persistence — a CLEAN check means the document would post. The skill generates the
  `CURRENCYAMOUNT`/`ITEMNO_ACC` cross-references automatically (positive AMOUNT=debit,
  negative=credit); balance must be 0 per currency (`FIPOST_UNBALANCED` before any RFC).
- **Verified, not assumed:** every post is re-read from BKPF (1 row) + BSEG (≥ item count);
  a green BAPI RETURN with a disagreeing re-read is `FIPOST_VERIFY_FAILED`. BSEG is read with
  a narrow FIELDS list (it is CLUSTER on ECC, wider than RFC_READ_TABLE's 512-byte limit).
- **Out of scope v1:** automatic tax calculation (post tax-free or explicit `TAX_NN` lines),
  one-time accounts / special G/L (→ `/sap-call-bdc` recommendation). **No transports, no Z
  objects, no GUI.** Config gaps (closed period, number range, substitution) surface as
  BAPIRET2 — faithfully rendered, never silently retried.
