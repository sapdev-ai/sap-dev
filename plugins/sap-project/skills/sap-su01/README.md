# sap-su01

**Confirm-gated, DEV-only test-user lifecycle over released BAPI_USER_* RFCs** — turns the
multi-day basis-ticket loop (create a user with exactly this role, assign, lock, reset,
delete) into a 30-second cycle so consultants can validate a role design end-to-end.

```
/sap-su01 create <USER> [--type A] [--group G] [--roles R1,R2] [--desc ...]
/sap-su01 show <USER> | assign|unassign <USER> <ROLES> | lock|unlock <USER>
/sap-su01 reset-password <USER> | delete <USER> | cleanup [--older-than Nd] [--dry-run]
```

## What it does

- **Full lifecycle via released BAPIs** (`references/sap_su01_rfc.ps1`): BAPI_USER_CREATE1,
  BAPI_USER_CHANGE + PASSWORDX, BAPI_USER_LOCK/UNLOCK, BAPI_USER_ACTGROUPS_ASSIGN,
  BAPI_USER_DELETE — all probed remote-enabled on both S/4HANA 1909 and ECC 6.
- **assign/unassign are a read-modify-write:** GET_DETAIL → merge/subtract the requested
  roles → ACTGROUPS_ASSIGN the FULL resulting set (the BAPI replaces the whole list), with an
  AGR_DEFINE role-existence pre-check (`SU01_ROLE_NOT_FOUND`) before any write. This is the
  assignment path `/sap-pfcg` reuses.
- **Password registry** (`references/sap_su01_store.ps1`): generated passwords are
  DPAPI-encrypted (`dpapi:<b64>`) into a per-(SID, client) JSONL registry — plaintext is
  never stored, printed, or logged; the operator gets the store PATH, never the value.
- **`cleanup`** walks the registry, verifies each owned user against USR02, takes ONE summary
  confirm (respecting `--older-than`; `--dry-run` lists only), then deletes + verifies;
  users already gone from USR02 are reported as orphans (INFO) and removed from the registry,
  never counted as a skill deletion.

## Safety gates

Every write **refuses on a production client** (T000 `CCCATEGORY=P`) or a non-modifiable
client (`SU01_NON_DEV_REFUSED`) — no override flag; Test/Customizing clients are allowed
(that is where test users belong). `lock`/`delete`/`reset-password` of the pinned profile's
own user is refused (`SU01_SELF_TARGET_REFUSED`). Every write takes a yes/no confirm stating
SID / client / user / roles; deleting a user that is neither in the registry nor matching
`su01_user_prefix` (default `ZTEST_`) requires the operator to **type the username**.

## Honest by construction

Success is never claimed from the BAPI RETURN alone: every write is verified by an
authoritative USR02 / AGR_USERS re-read, and a green RETURN with a disagreeing re-read is
`VERIFY_MISMATCH`, never success. A missing user-admin authorization surfaces honestly as
`SU01_BAPI_ERROR` with a pointer to `/sap-doctor auth`; on a Central-User-Administration
child client the assign BAPI is blocked and surfaced with a CUA hint (drive assignment on
the CUA hub instead).

Pure RFC — no GUI, no Z objects, no transports (user master data is client-local).
Prerequisites: SAP profile via /sap-login (RFC) with user-admin authorization
(S_USER_GRP/S_USER_AGR); SAP NCo 3.1 (32-bit). Phase 2 (v1.5): `verify <USER> --tcode` —
role-verification-by-execution as the test user, with SU53 evidence via /sap-auth-diagnose.
