# sap-pfcg

**PFCG role automation** — turns the manual post-diagnosis grind (add a tcode,
regenerate, user-compare, assign) into one-line commands where **every write is
confirm-gated with an explicit delta preview and PROVEN by an authoritative AGR_* RFC
re-read** — the skill never "thinks" it changed a role.

```
/sap-pfcg show <ROLE>
/sap-pfcg create <ROLE>
/sap-pfcg add-tcodes <ROLE> <T1,T2> [--generate]     # NEEDS_RECORDING (see below)
/sap-pfcg remove-tcodes <ROLE> <T1,T2>               # NEEDS_RECORDING (see below)
/sap-pfcg generate <ROLE>
/sap-pfcg user-compare <ROLE>
/sap-pfcg assign <ROLE> <USER[,..]> | unassign <ROLE> <USER>
```

## What it does

- **show** is a read-only role dossier: AGR_DEFINE/AGR_TEXTS header, AGR_TCODES menu,
  AGR_USERS assignments, AGR_PROF generated profile + AGR_1251 auth-row count, and T000
  client modifiability.
- **assign / unassign** are pure RFC via the released BAPI_USER_ACTGROUPS_ASSIGN
  read-modify-write path — reusing `/sap-su01`'s verified assignment writer (the binding
  ownership split: pfcg = role→users, su01 = user→roles). Full-set-replace from a fresh
  GET_DETAIL plus the requested delta ONLY — never over-grants; aborts on any RETURN E/A.
- **create / generate** are **gated GUI writes with recorded drivers** (recorded on
  EC2 ERP/800, ECC 6, 2026-07-11; S/4 structurally identical). `create` resolves a
  **Customizing TR** via `/sap-transport-request --type customizing`; `generate` uses
  PFCG's **in-editor Generate** — it enters the auth-data screen but makes NO
  auth-value/org-level edits (Generate + confirm the proposed profile name + save).
- **add-tcodes / remove-tcodes** ship as **`NEEDS_RECORDING`**: the menu-tab
  add-transaction drives a GuiShell-toolbar button whose pressButton fcode is not
  drive-discoverable, so the driver must be captured once with SAP's built-in recorder
  (`/sap-gui-probe --record`, Mode R). Until then the mode aborts cleanly with
  `PFCG_NEEDS_RECORDING`.
- **user-compare** delegates RHAUTUPD_NEW to `/sap-run-report`.

## Safety gates and verification

Every write mode preflights client modifiability (refuse `AUTH_CLIENT_NOT_MODIFIABLE`),
role existence, TSTC-validates each tcode, and existence-checks each user — then shows a
**CONFIRM gate** with the exact delta ("I will <VERB> on role <R> in <SID>/<CLIENT>:
<delta>"), requiring a **typed role name on a production client**. After the write, a
mode-specific RFC re-read is authoritative: the AGR_TCODES diff must equal the requested
delta EXACTLY (`PFCG_VERIFY_MISMATCH` even if the status bar said S); generate must leave
AGR_PROF + auth rows present (`PFCG_GENERATE_FAILED` on 0); assign must show the previous
set ± delta. `/sap-suim` fetch-role provides the human-facing before/after grant diff,
and every change is registered for `/sap-evidence-pack`.

## Key reference files

`sap_pfcg_verify.ps1` (dossier + write-gate re-read), `sap_pfcg_create.vbs` +
`sap_pfcg_generate.vbs` (recorded GUI drivers, with golden-screen baselines),
`sap_pfcg_menu.vbs` (add/remove-tcodes placeholder — to-be-recorded).

`show` live-verified on S/4HANA 1909 (S4D); the RFC legs are one code path on ECC 6 + S/4,
GUI legs are per-release with `PFCG_NEEDS_RECORDING` degradation. Build finding: role
creation needs S_USER_AGR activity 01 (`PFCG_NO_AUTH_CREATE` where missing). The
authorization tree (auth values / org levels) is Phase 2 — v1 never improvises tree
edits; role delete is out of scope; composite-role writes are v1.5. Prerequisites: pinned
`/sap-login` RFC profile; a live GUI session for create/menu/generate; SAP NCo 3.1
(32-bit).
