---
name: sap-su01
description: |
  Confirm-gated, DEV-only test-user lifecycle over released BAPI_USER_* RFCs — turns
  a multi-day basis ticket loop (create a user with exactly this role, assign, lock,
  reset, delete) into a 30-second cycle so consultants can validate a role design
  end-to-end. Modes: create / show / assign / unassign / lock / unlock /
  reset-password / delete / cleanup. Every write refuses on a PRODUCTION client
  (T000 guard) and is verified by an authoritative USR02 / AGR_USERS re-read — success
  is never claimed from the BAPI RETURN alone. Generated passwords are DPAPI-encrypted
  into a per-(SID,client) registry that powers orphan-free cleanup. Pure RFC (all FMs
  probed remote-enabled on S/4HANA 1909 + ECC 6) — no GUI, no Z objects, no transports
  (user master data is client-local). Ships the assignment read-modify-write path that
  /sap-pfcg reuses. Prerequisites: SAP profile via /sap-login (RFC) with user-admin
  authorization (S_USER_GRP/S_USER_AGR); SAP NCo 3.1 (32-bit).
argument-hint: "create <USER> [--type A] [--group G] [--roles R1,R2] [--desc ...] | show <USER> | assign|unassign <USER> <ROLES> | lock|unlock <USER> | reset-password <USER> | delete <USER> | cleanup [--older-than Nd] [--dry-run]"
---

# SAP SU01 Test-User Skill

You run a **DEV-only, confirm-gated** test-user lifecycle over released BAPI_USER_*
RFCs. Every write refuses on production, and every write is **verified by an
authoritative re-read** — never trusted from the BAPI RETURN alone.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_su01_rfc.ps1` | `-Action precheck\|show\|create\|assign\|unassign\|lock\|unlock\|resetpw\|delete` | BAPI_USER_* backend + DEV guard + verify re-reads |
| `<SKILL_DIR>/references/sap_su01_store.ps1` | `-Action upsert\|remove\|isowned\|list` | Per-(SID,client) test-user registry (JSONL, DPAPI passwords) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_dpapi.ps1` | via the backend | Password protect (`dpapi:<b64>`); plaintext never stored/printed |
| `/sap-login` | sub-skill | Pinned RFC profile |
| `/sap-doctor` | sub-skill | `auth` group pre-declares S_USER_* gaps |

---

## Step 0 — Resolve Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging
(`sap_log_helper.ps1`, state `{RUN_TEMP}\sap_su01_run.json`). Resolve settings:
`su01_user_prefix` (default `ZTEST_`), `su01_default_user_type` (`A`), `su01_valid_days` (`30`).

## Step 1 — Parse & Normalize

Mode dispatch (see argument-hint). Uppercase USER, cap at 12 chars. `create` defaults
type to `su01_default_user_type` and (if `--valid-to` absent) valid-to = today +
`su01_valid_days`. Resolve the pinned profile's own user (for the self-target guard).

## Step 1.5 — Preflight (`-Action precheck`, one RFC call)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_su01_rfc.ps1" -Action precheck -User <USER> -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Reads `SU01: precheck client=<C> dev_ok=<bool> reason=<..> user=<U> exists=<bool>`.
- `dev_ok=False` on any **write** mode → refuse (`SU01_NON_DEV_REFUSED`), tell the user
  the client is production/non-modifiable, STOP. (The guard refuses **production only** —
  Test/Customizing clients are legitimate homes for test users.)
- `exists=True` on `create` → `SU01_USER_EXISTS`, no BAPI call. `exists=False` on
  show/assign/lock/etc → `SU01_USER_NOT_FOUND`.
- If the pinned RFC user lacks `S_USER_GRP` the write BAPI returns `01/498 not
  authorized` → surfaced as `SU01_BAPI_ERROR` (honest; point to `/sap-doctor auth`).

## Step 2 — RFC Profile + Self-Target Guard

Pinned RFC profile required (`/sap-login`). **Refuse** `lock`/`delete`/`reset-password`
of the pinned profile's own user → `SU01_SELF_TARGET_REFUSED`.

## Step 2.5 — Confirm Gate (every write)

State SID / client / user / (roles) and get a yes/no. **delete** of a user NOT in the
registry AND not matching `su01_user_prefix` → require the operator to **type the
username** (foreign-user typed confirmation). `cleanup` → one summary confirm for the batch.

## Step 3 — Execute (verified)

Run the backend action (32-bit PS), passing `-SelfUser <own user>`. Read the `SU01:` +
`STATUS:` lines. The backend already:
- **Guards DEV** (refuses production), calls the released BAPI (`BAPI_USER_CREATE1`,
  `BAPI_USER_CHANGE`+PASSWORDX, `BAPI_USER_LOCK/UNLOCK`, `BAPI_USER_ACTGROUPS_ASSIGN`,
  `BAPI_USER_DELETE`), commits, and **verifies by re-read** (USR02 row / UFLAG /
  AGR_USERS set) — `STATUS: VERIFY_MISMATCH` if the re-read disagrees with the intent.
- `assign`/`unassign` do a **read-modify-write**: GET_DETAIL → merge/subtract the
  requested roles → ACTGROUPS_ASSIGN the FULL resulting set (the BAPI replaces the whole
  list), with an `AGR_DEFINE` role-existence pre-check (`SU01_ROLE_NOT_FOUND`) before any write.
- `create`/`resetpw` generate a strong password and emit it ONLY as `pwd=dpapi:<b64>`.

STATUS handling: `OK` → continue; `REFUSED`/`USER_EXISTS`/`USER_NOT_FOUND`/`ROLE_NOT_FOUND`
→ business refusal (exit 1), report + STOP; `BAPI_ERROR`/`VERIFY_MISMATCH`/`RFC_ERROR`
→ FAILED (exit 2), report the exact message. **Never render a failed/refused write as done.**

## Step 4 — Registry + Report

- `create`/`reset-password` → `sap_su01_store.ps1 -Action upsert` (store the
  `dpapi:` password + roles). **Tell the operator the store PATH, never the password value.**
- `delete` → `-Action remove`. For a delete/cleanup, use `-Action isowned` to pick the
  confirm tier in Step 2.5.
- `show` → write the dossier TSV; register (`Register-SapArtifact -Kind user-dossier`).

## Step 5 — cleanup mode

`sap_su01_store.ps1 -Action list -Sid <S> -Client <C>` → for each registry user, run
`sap_su01_rfc.ps1 -Action show` (verify still in USR02). Present the table; ONE summary
confirm (respect `--older-than`); `--dry-run` lists only. Then delete each + verify;
users in the registry but already gone from USR02 are reported as **orphans (INFO)**,
removed from the registry, never counted as a skill deletion.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). A refusal is `SKIPPED` (no writes).
error_class map: `SU01_NON_DEV_REFUSED` / `SU01_SELF_TARGET_REFUSED` / `SU01_USER_EXISTS`
/ `SU01_USER_NOT_FOUND` / `SU01_ROLE_NOT_FOUND` / `SU01_BAPI_ERROR` / `SU01_VERIFY_MISMATCH`.

---

## Scope & Limitations (v1)

- **v1:** create / show / assign / unassign / lock / unlock / reset-password / delete /
  cleanup — all pure RFC, verified by re-read, DEV-only.
- **Phase 2 (v1.5):** `verify <USER> --tcode` role-verification-by-execution (second
  `/sap-login` profile as the test user → drive sap-tcd → SU53 evidence via
  `/sap-auth-diagnose su53`).
- **DEV-only** hard refusal on a **production** client (T000 `CCCATEGORY=P`) or a
  non-modifiable client (`CCCORACTIV=3`); no override flag. Test/Customizing clients are
  allowed (that is where test users belong).
- **Verified, not assumed:** every write is re-read (USR02/AGR_USERS); a green BAPI RETURN
  with a disagreeing re-read is `VERIFY_MISMATCH`, never success. `assign` REPLACES the
  full role set (read-modify-write). Passwords are DPAPI-only, never printed to chat/logs.
- **No transports** (user master is client-local); **no Z objects**; **no GUI** in v1.
- **CUA caveat:** on a Central-User-Administration child client the assign BAPI is blocked;
  surfaced as `SU01_BAPI_ERROR` with a CUA hint (drive assignment on the CUA hub instead).
