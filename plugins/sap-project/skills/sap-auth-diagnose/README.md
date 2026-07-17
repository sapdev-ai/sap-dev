# sap-auth-diagnose

**Answer "why can't user U do X" with a machine check, not prose** — evaluate the failed
authorization object against the user's real runtime buffer over RFC and hand back the exact
PFCG fix as a proposal. Read-only toward roles and users; no GUI, no Z-object.

```
/sap-auth-diagnose check --object <OBJ> [--values F=V,F2=V2] [--user <U>] [--ticket <id>]
/sap-auth-diagnose check --input <tsv>      # batch: checkid⇥object⇥field⇥value per row
(su53 | trace — documented next phase, not yet implemented)
```

## What it does

- **Evaluates against the AUTHORITATIVE runtime buffer** (`SUSR_USER_AUTH_FOR_OBJ_GET`,
  remote-enabled on S/4HANA 1909 + ECC 6) with faithful AUTHORITY-CHECK semantics — one
  authorization instance must satisfy every field, `*` matches anything, VON..BIS ranges
  honoured — so the verdict can never disagree with the real kernel check the way a
  hand-rolled AGR_1251/UST12 join can.
- **Classifies each failure**: `MISSING_OBJECT` (no role or profile carries the object),
  `MISSING_VALUE` (object held, requested value not covered), `BUFFER_STALE` (a held role
  DOES grant it — the fix is a user compare / re-logon, not a role change), plus user-level
  `USER_LOCKED` / `USER_EXPIRED` / `ROLE_EXPIRED`, surfaced first because they mask
  everything else.
- **Names the closest role** the user already has, with what it currently grants — so the
  fix reads "extend role R's authorization for field F to include V", not "add SAP_ALL".
- **Decodes a pasted SU53** (text or screenshot) into the check input — until the GUI
  auto-scrape lands, the operator reads the failed object off SU53 / an ST22 dump / an
  application-log message and Claude builds the check from it.
- **Writes three artifacts**: `auth_diagnosis.tsv` (one row per check: object, verdict,
  requested values, closest role, current grant, proposed delta), `auth_fix_proposal.md`
  (the PFCG action per failure), `auth_request.txt` (ready-to-send to the security team).

## Honest by construction

The fix is always a proposal, never a write — the skill never touches PFCG/SU01 data. A
check that cannot run is `COULD_NOT_CHECK`, never rendered as "no failures". Missing input
is refused up front (`AUTH_INPUT_INVALID`); `--user` defaults to the pinned connection's
user. Batch input follows `references/auth_check_input_sample.tsv` (rows sharing a
`checkid` form one AUTHORITY-CHECK group; empty value = presence-only check).

## Reads

`SUSR_USER_AUTH_FOR_OBJ_GET` (the runtime buffer), `AGR_USERS` / `AGR_1251` / `AGR_TEXTS`
(role correlation), `USR02` (lock/validity), `TOBJT` (object texts). Pure RFC off the
pinned `/sap-login` profile (SAP NCo 3.1, 32-bit) — no GUI session, no wrapper FM, no
dev-init.

`check` is live-verified on S/4HANA 1909 (S4D); ECC 6 (EC2/ERP) has full table + FM parity
per the plan's probe — one shared RFC backend. `su53` (GUI auto-scrape of the failed
objects — needs the SU53 screen recording via `/sap-gui-probe`) and `trace` (a confirm-gated
STAUTHTRACE bracket, S/4-only) are the documented next phase; v2 adds cross-user checks
(`S_USER_AUT`-gated) and the SUIM "who has this auth" reverse lookup.
