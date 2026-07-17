---
name: sap-pfcg
description: |
  PFCG role automation — turns the manual post-diagnosis grind (add a tcode, regenerate,
  user-compare, assign) into one-line commands where every write is confirm-gated with an explicit
  delta preview and PROVEN by an authoritative AGR_* RFC re-read (never "thinks" it changed a role).
  show is a read-only role dossier (AGR_DEFINE/AGR_TEXTS header, AGR_TCODES menu, AGR_USERS
  assignments, AGR_PROF generated profile + AGR_1251 auth-row count, T000 client modifiability).
  assign/unassign add/remove users via the released BAPI_USER_ACTGROUPS_ASSIGN read-modify-write path
  (pure RFC, full-set-replace from a fresh GET_DETAIL + the requested delta ONLY — never over-grants;
  reuses /sap-su01's verified assignment writer, the binding ownership split: pfcg = role->users,
  su01 = user->roles). create / add-tcodes / remove-tcodes / generate drive PFCG (SAPLPRGN_TREE) +
  SUPC (SAPPROFC_NEW) via recorded GUI flows that NEVER enter the authorization tree (Phase 1's
  make-or-break), behind a confirm gate + a Customizing TR (/sap-transport-request --type
  customizing), each verified by an exact AGR_TCODES / AGR_PROF re-read. user-compare delegates
  RHAUTUPD_NEW to /sap-run-report. The auth tree (auth-values/org-levels) is Phase 2; delete is out
  of scope. v1 RFC legs are identical ECC6 + S/4; GUI legs are per-release with PFCG_NEEDS_RECORDING
  degradation. Depends on /sap-suim (before/after grant diff) + the /sap-transport-request
  Customizing-TR extension (both shipped). Prerequisites: pinned /sap-login RFC profile; a live GUI
  session for create/menu/generate; NCo 3.1 (32-bit).
argument-hint: "show <ROLE> | add-tcodes <ROLE> <T1,T2> [--generate] | generate <ROLE> | assign <ROLE> <USER[,..]> | unassign <ROLE> <USER>"
---

# SAP PFCG Role Skill

You make the five safe Phase-1 role changes as one-liners: show (read-only dossier), add/remove
menu tcodes, generate the profile (via SUPC, never the auth tree), user-compare, and assign/unassign
users — every write confirm-gated on an explicit delta and verified by an authoritative RFC re-read.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_pfcg_verify.ps1` | `-Mode snapshot\|list` | Role dossier (show) + write-gate re-read |
| `<SKILL_DIR>/references/sap_pfcg_create.vbs` | GUI (`%%ROLE_NAME%%`·`%%ROLE_DESC%%`·`%%TRANSPORT%%`·`%%SESSION_PATH%%`·`%%ATTACH_LIB_VBS%%`·`%%SESSION_LOCK_VBS%%`) | PFCG create-single-role — **recorded on EC2 2026-07-11** (Role>Create>Role → desc → Save; step-verified, assembled-driver smoke-test pending) |
| `<SKILL_DIR>/references/sap_pfcg_generate.vbs` | GUI (`%%ROLE_NAME%%`·`%%SESSION_PATH%%`·`%%ATTACH_LIB_VBS%%`·`%%SESSION_LOCK_VBS%%`) | Profile generate — **recorded on EC2 2026-07-11**. Uses PFCG's **in-editor Generate** (auth-data screen 120 → Generate → confirm name; makes NO auth-tree edits) — supersedes the original SUPC plan per the "record GUI pfcg" instruction; `PFCG_NEEDS_RECORDING` (exit 3) if `btnPROFIL1` isn't locatable on a release |
| `<SKILL_DIR>/references/sap_pfcg_menu.vbs` | GUI | add/remove-tcodes menu flow — **`NEEDS_RECORDING`**: the menu-tab add-transaction goes through a GuiShell-toolbar `pressButton` whose fcode isn't drive-discoverable → needs SAP's built-in recorder (`/sap-gui-probe --record`, Mode R) |
| `/sap-su01` (assign/unassign) · `/sap-suim` (fetch-role diff) · `/sap-transport-request` (`--type customizing`) · `/sap-run-report` (RHAUTUPD_NEW) | sub-skills | Reused assignment writer / before-after diff / Customizing TR / user comparison |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_attach_lib.vbs` (`%%ATTACH_LIB_VBS%%`) · `sap_session_lock.vbs` (`%%SESSION_LOCK_VBS%%`) | libs | RFC + Tier-3 attach + write lock |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_pfcg_run.json`). Pinned RFC profile; GUI session for create/menu/generate.

## Step 1 — Parse & Dispatch

`show` | `create` | `add-tcodes` | `remove-tcodes` | `generate` | `user-compare` | `assign` |
`unassign`. Uppercase ROLE/TCODES/USERS. Chained flags (`--generate --compare`) run under ONE
combined confirm gate.

## Step 2 — Preflight (write modes)

`sap_pfcg_verify.ps1 -Mode snapshot` gives client modifiability (T000) + role existence: refuse
`AUTH_CLIENT_NOT_MODIFIABLE`; create on an existing role -> `PFCG_ROLE_EXISTS`; the others on a
missing role -> `AUTH_ROLE_NOT_FOUND`. TSTC-validate each add-tcode; BAPI_USER_EXISTENCE_CHECK each
user.

## Step 3 — show / BEFORE snapshot

```bash
... sap_pfcg_verify.ps1 -Mode snapshot -Role <R> -OutDir "{RUN_TEMP}\pfcg"
```

`PFCG:` dossier lines (desc / menu_tcodes / assigned_users / generated_profile / auth_rows /
client modifiability) + `role_snapshot_<R>.tsv`. `show` renders this and ENDS. For write modes, also
capture the `/sap-suim fetch-role` grant-set TSV as the human-facing before-state.

## Step 4 — CONFIRM gate + write

**CONFIRM** (yes/no; typed role-name when T000 category=P): "I will <VERB> on role `<R>` in
`<SID>/<CLIENT>`: <exact delta>. Proceed?". On no -> `SKIPPED`. Then:
- **assign/unassign** -> delegate to `/sap-su01 assign|unassign <R> <USER>` (the reused
  BAPI_USER_ACTGROUPS_ASSIGN full-set-replace path: fresh GET_DETAIL + the requested delta ONLY,
  abort on RETURN E/A incl. CUA-child, verify AGR_USERS re-read).
- **create / generate (recorded GUI writes)** -> for create, resolve a **Customizing TR** via
  `/sap-transport-request --type customizing` (single roles are usually client-local, so the driver
  tolerates no TR popup; generate needs no TR). Substitute the attach + lock + arg tokens, set
  `SAPDEV_SESSION_PATH`, and run the driver via **32-bit cscript**:

  ```powershell
  $shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
  . "$shared\sap_connection_lib.ps1"
  $env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
  $drv = 'sap_pfcg_create.vbs'   # or 'sap_pfcg_generate.vbs'
  $vbs = [IO.File]::ReadAllText("<SKILL_DIR>\references\$drv", [Text.Encoding]::UTF8)
  $vbs = $vbs.Replace('%%ATTACH_LIB_VBS%%',   "$shared\sap_attach_lib.vbs")
  $vbs = $vbs.Replace('%%SESSION_LOCK_VBS%%', "$shared\sap_session_lock.vbs")
  $vbs = $vbs.Replace('%%SESSION_PATH%%',     '')            # or the --session value
  $vbs = $vbs.Replace('%%ROLE_NAME%%',        '<ROLE>')
  $vbs = $vbs.Replace('%%ROLE_DESC%%',        '<short description>')  # create only
  $vbs = $vbs.Replace('%%TRANSPORT%%',        '<customizing-TR>')     # create only; empty -> ABORT if PFCG prompts
  [IO.File]::WriteAllText('{RUN_TEMP}\pfcg_run.vbs', $vbs, [System.Text.UnicodeEncoding]::new($false, $true))
  ```

  ```bash
  C:\Windows\SysWOW64\cscript.exe //NoLogo "{RUN_TEMP}\pfcg_run.vbs"
  ```

  Parse `SUCCESS:` / `ERROR:` plus the machine markers — `PFCG_NO_AUTH_CREATE:` (create; missing
  S_USER_AGR activity 01 — verified on S4D/MICHAELLI + S4G/KM717; EC2/DEV102 has it), `ABORT_EMPTY_TR:`
  (create; a TR popup appeared with no `%%TRANSPORT%%`), `PFCG_NEEDS_RECORDING:` **exit 3** (generate;
  `btnPROFIL1` not locatable on this release → recapture). **generate uses PFCG's in-editor Generate**
  — it enters the auth-data screen (120) but makes NO auth-value/org-level edits (only Generate +
  confirm the proposed profile name + save); this supersedes the original SUPC design per the
  "record GUI pfcg" decision.
- **add-tcodes / remove-tcodes** -> `sap_pfcg_menu.vbs` ships **`NEEDS_RECORDING`**: the menu-tab
  add-transaction drives a GuiShell-toolbar button (`cntlTOOL_CONTROL`) whose `pressButton` function
  code is not discoverable by dumping the property tree, so drive-mode cannot capture it. Emit
  `PFCG_NEEDS_RECORDING` and point to `/sap-gui-probe --record` (SAP's built-in recorder, Mode R) —
  a clean abort until the flow is captured with a human operator's click as ground truth.
- **user-compare** -> `/sap-run-report RHAUTUPD_NEW` role-scoped (or PFCG_TIME_DEPENDENCY for
  `--all-roles`).

## Step 5 — AFTER verify (authoritative)

Mode-specific RFC re-read via `sap_pfcg_verify.ps1`: AGR_TCODES before/after diff == the requested
delta EXACTLY (else `PFCG_VERIFY_MISMATCH`, FAILED, show actual — even if the status bar said S);
generate -> AGR_PROF + auth_rows present (0 -> `PFCG_GENERATE_FAILED`; org-level warnings ->
`GENERATED_WITH_WARNINGS`, stated not hidden); assign -> AGR_USERS set == previous ± delta. Render
the `/sap-suim` before/after diff.

## Step 6 — Register

`Register-SapArtifact` (kinds `auth-role-snapshot` / `auth-role-change` / `auth-assignment`; scope
`ROLE_<NAME>`; verdict) for `/sap-evidence-pack`.

## Final — Log End

Log end. Error classes: `AUTH_CLIENT_NOT_MODIFIABLE`, `PFCG_ROLE_EXISTS`, `PFCG_VERIFY_MISMATCH`,
`PFCG_GENERATE_FAILED`, `PFCG_NEEDS_RECORDING`; reused `RFC_LOGON_FAILED` / `GUI_TIMEOUT` /
`TR_NOT_MODIFIABLE` / `AUTH_ROLE_NOT_FOUND` / `AUTH_USER_NOT_FOUND` / `AUTH_TCODE_NOT_FOUND`.

---

## Scope & Limitations (v1)

- **show live-verified on S4D (S/4HANA 1909) 2026-07-11:** `show SAP_BC_BASIS_ADMIN` returned the
  full dossier — desc "System Administrator", 38 menu tcodes, 0 assigned users, generated profile
  T-SD020189, 146 auth rows, client category=T / modifiable=YES; a nonexistent role ->
  `AUTH_ROLE_NOT_FOUND`. EC2 (ECC 6) was probed in-plan (all AGR_* + BAPI_USER_ACTGROUPS_ASSIGN
  FMODE=R + PFCG/SUPC programs identical) but unreachable at build time; the RFC legs are one code
  path. **Build finding:** AGR_TIMESTMP does not exist -> generation is verified via AGR_PROF +
  AGR_1251 auth-row count, not a timestamp.
- **assign/unassign is pure RFC** (BAPI_USER_ACTGROUPS_ASSIGN, FMODE=R both releases) and REUSES
  /sap-su01's verified writer (the binding ownership split — one implementation, two views). It
  full-set-replaces from a fresh GET_DETAIL + the requested delta ONLY (never over-grants) and aborts
  on any RETURN E/A.
- **create/add-tcodes/remove-tcodes/generate are confirm-gated GUI writes**, each verified by an EXACT
  AGR_* re-read (a status-'S' with the wrong delta is still a mismatch failure) and (create) a
  Customizing TR via the shipped `/sap-transport-request --type customizing` extension.
  **Recorded 2026-07-11 (EC2 ERP/800, ECC6 rel 731; S/4 structurally identical — same SAPLPRGN_TREE
  control IDs, only the on-screen text differs):** `create` (Role>Create>Role → description → Save;
  single roles are client-local so no TR popup fired) and `generate` (Authorizations tab → in-editor
  Generate → confirm the proposed profile name → save). **Build finding:** role creation needs
  S_USER_AGR activity 01 — S4D/MICHAELLI and S4G/KM717 both LACK it (`PFCG_NO_AUTH_CREATE`), only
  EC2/DEV102 has it, so the create/generate legs were recorded there. **Design shift:** `generate` now
  uses PFCG's **in-editor** Generate (it enters the auth-data screen but makes NO auth-value/org-level
  edits — only Generate + confirm the name + save), superseding the plan's SUPC list flow per the
  "record GUI pfcg" instruction. **`add-tcodes`/`remove-tcodes` stays `NEEDS_RECORDING`** — the
  menu-tab add-transaction drives a GuiShell-toolbar button whose `pressButton` fcode is not
  drive-discoverable, so it needs SAP's built-in recorder (`/sap-gui-probe --record`, Mode R).
- **The auth tree is Phase 2.** v1 does NOT patch S_TABU_DIS values / org levels — it answers with
  the /sap-auth-diagnose proposal file + a manual PFCG pointer (never improvises tree edits). Role
  delete is out of scope. Composite-role writes (AGR_AGRS) are v1.5.
