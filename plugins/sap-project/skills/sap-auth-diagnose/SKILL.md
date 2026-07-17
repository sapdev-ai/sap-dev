---
name: sap-auth-diagnose
description: |
  Diagnoses "no authorization" failures deterministically over RFC and proposes the
  exact PFCG fix — no more pasting an SU53 screenshot and hand-searching SUIM. Given
  the failed authorization object (+ optional field values, read off SU53 / an ST22
  dump / an application-log message), it evaluates the target user against the
  AUTHORITATIVE runtime user buffer (`SUSR_USER_AUTH_FOR_OBJ_GET`, remote-enabled on
  S/4HANA 1909 + ECC 6) with faithful AUTHORITY-CHECK semantics — one authorization
  instance must satisfy every field, '*' matches anything, VON..BIS ranges honoured —
  so the verdict can never disagree with the real kernel check the way a hand-rolled
  AGR_1251/UST12 join can. It then classifies each failure (`MISSING_OBJECT` /
  `MISSING_VALUE` / `BUFFER_STALE`) plus user-level `USER_LOCKED` / `USER_EXPIRED` /
  `ROLE_EXPIRED`, names the closest role the user already has (with what it currently
  grants), and writes a diagnosis TSV + fix-proposal + ready-to-send security request.
  Read-only toward roles and users — the fix is always a proposal, never a write.
  Prerequisites: SAP profile via /sap-login (RFC); SAP NCo 3.1 (32-bit). su53 (GUI
  auto-scrape of the failed objects) and trace (STAUTHTRACE) modes are the documented
  next phase — until then the operator supplies the failed object (Claude decodes a
  pasted SU53 into the check input).
argument-hint: "check --object <OBJ> [--values F=V,F2=V2] [--user <U>] [--ticket <id>] | check --input <tsv> | (su53 | trace = next phase)"
---

# SAP Authorization Diagnosis Skill

You answer **"why can't user `<U>` do `<X>`"** with a machine check, not prose: decode
the failed authorization object, evaluate it against the user's real runtime buffer,
name the closest role, and hand back an exact, actionable fix — all read-only.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_auth_diagnose_rfc.ps1` | `-Action check` | Buffer read + faithful AUTHORITY-CHECK eval + AGR_* fix correlation |
| `<SKILL_DIR>/references/auth_check_input_sample.tsv` | template | Commented batch-input sample (`checkid⇥object⇥field⇥value`) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | dot-sourced | NCo 3.1 connect/disconnect (pinned-profile fallback) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | Diagnosis / fix-proposal artifact registration |
| `<SAP_DEV_CORE_SHARED_DIR>/tables/required_authorizations.tsv` | reference | The capability→object→field grammar this reuses |
| `/sap-login` | sub-skill | Pinned RFC profile |
| `/sap-su01` | sub-skill | Pointed to in the fix (role assign) — never auto-invoked |

**Input grammar** — a *check* is one authorization object plus the field/value set that
must ALL be satisfied by a single authorization instance (exactly one AUTHORITY-CHECK):
- `check --object S_TCODE --values TCD=SU01`
- `check --object S_DEVELOP --values "ACTVT=01,OBJTYPE=PROG"` (a multi-field group)
- `check --input <tsv>` — batch, tab-delimited `checkid⇥object⇥field⇥value`; rows sharing
  a `checkid` form one group. Empty value = presence-only check.

`--user` defaults to the pinned connection's user. `--values` empty = "does the user have
this object at all".

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging
(`sap_log_helper.ps1`, state `{RUN_TEMP}\sap_auth_diagnose_run.json`). Pure RFC — no GUI session.

## Step 1 — Parse & Dispatch

Modes: `check` (v1). `su53` / `trace` → **next phase** (Scope below): tell the operator
to read the failed object off SU53 / the dump / the app message and pass it to `check`
(if they paste an SU53 screen or screenshot, YOU decode object + field + value from it and
build the check input — that decoding is the point, and needs no GUI automation). Validate
that at least one object is supplied; else `AUTH_INPUT_INVALID`, STOP.

## Step 2 — RFC Profile

Pinned RFC profile required (`/sap-login`) — missing → `RFC_LOGON_FAILED`, STOP. No GUI
fallback in v1.

## Step 3 — `check` (the diagnosis)

**3a. Assemble the check(s).** From `--object`/`--values`, or `--input <tsv>`. When the
operator pastes SU53 output/screenshot, extract each failed check into a `{RUN_TEMP}`
TSV (`checkid⇥object⇥field⇥value`) — one `checkid` per SU53 record, one row per field.

**3b. Run the engine:**

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_auth_diagnose_rfc.ps1" -Action check -User "<U>" -InputFile "<tsv>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

(or `-Object <O> -Values "F=V;F2=V2"` for a single check). Parse the lines:
- `USER:` — existence, lock (`UFLAG`), validity window (`GLTGV`/`GLTGB`), `invalid=Y|N`.
- `AUTHCHK:` — per check: `verdict` (`PASS` / `MISSING_OBJECT` / `MISSING_VALUE` /
  `BUFFER_STALE` / `COULD_NOT_CHECK`), `fully`, the requested values, `closest_role`, what
  that role currently `grants`, and the object text (`otext`).
- `ROLE:` — only the actionable roles (the fix-target of a failing check + any expired
  assignment), with name/validity/text.
- `AUTHSUMMARY:` / `STATUS:` — `OK` / `USER_NOT_FOUND` / `INPUT_INVALID` / `RFC_ERROR`.

**3c. Classify + render.** For each failing check, the verdict IS the diagnosis:
- `MISSING_OBJECT` — no role or profile the user holds carries the object. Fix: assign a
  role that grants it (the request TXT names the object/field/value); if a specific PFCG
  role is the intended home, point the operator at it. `closest_role=-`.
- `MISSING_VALUE` — the user has the object but no instance covers the requested value.
  Fix: extend `closest_role`'s authorization for `<field>` to include `<value>` (the
  `grants=` field shows what it covers today).
- `BUFFER_STALE` — a role the user holds DOES grant it, yet the runtime buffer denies it →
  the user master was changed without a buffer refresh. Fix: user re-logon / PFCG user
  compare (`SU01 → Compare`), not a role change.
- `USER_LOCKED` / `USER_EXPIRED` (from `USER: invalid=Y`) or `ROLE_EXPIRED` (an expired
  `ROLE:` assignment) — surface these first: they mask everything else.

Write into the artifact dir (`Get-SapArtifactDir -ScopeKey USER_<U> -Skill sap-auth-diagnose`):
- `auth_diagnosis.tsv` — one row per check: object, otext, verdict, requested value(s),
  closest role, current grant, proposed delta.
- `auth_fix_proposal.md` — per failure: closest role, exact missing field/value, the PFCG
  action (extend authorization / assign role / user compare).
- `auth_request.txt` — ready-to-send to the security team: user, system/client,
  `--ticket`, object, field, value, and the business context.

Register each (`Register-SapArtifact -Kind auth_diagnosis`, coverage tri-state,
verdict `DIAGNOSED` / `NO_FAILURES` / `COULD_NOT_CHECK`). Print a verdict block +
per-check lines.

## Step 4 — `su53` mode (NEXT PHASE)

SU53 has no RFC FM and no submittable report on either system (probed: SUSR_SU53_PARSE_DATA
/ SUSR_GET_SU53_DATA / RSUSR_SU53 all absent), so auto-discovery of the failed objects is a
GUI scrape (release-variant VBS — `SAPMS01GNEW` on S/4, `SAPMS01G` on ECC — captured via
`/sap-gui-probe` with a golden-screen baseline + `NEEDS_RECORDING` fallback). Until that
recording lands, run SU53 yourself (or paste it) and use `check` — the correlation, the
verdict, and the fix are identical; only the object-discovery step differs.

## Step 5 — `trace` mode (NEXT PHASE, S/4 only)

A confirm-gated STAUTHTRACE bracket (start → reproduce → **guaranteed stop** → dedupe into an
object/field/value matrix, then the same `check` correlation). Gated on the S/4-only result
store `SUAUTHVALTRC` (absent on ECC 6 → refuse loud); the `S_ADMI_FCD` precheck reuses
`SUSR_USER_AUTH_FOR_OBJ_GET`. No RFC start/stop FM exists, so it is GUI-driven with
mandatory startup stale-trace detection — deferred until the STAUTHTRACE screens are recorded.

## Final — Log End

Log end (`SUCCESS` / `FAILED` / `SKIPPED` + error_class): `AUTH_INPUT_INVALID` /
`AUTH_USER_NOT_FOUND` / `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **v1 (live-verified on S4D, S/4HANA 1909):** `check` mode — single (`--object`/`--values`)
  and batch (`--input`), against the authoritative buffer via `SUSR_USER_AUTH_FOR_OBJ_GET`,
  with AGR_USERS / AGR_1251 / AGR_TEXTS / USR02 / TOBJT correlation. Verified: `PASS`
  (fully-authorized), `MISSING_OBJECT` (S_USER_GRP / S_USER_AGR — the real gap behind
  `/sap-su01` create failures), user lock/validity, object-text resolution, and the
  actionable-role surfacing. The per-instance AUTHORITY-CHECK evaluator (the PASS/FAIL and
  hence `MISSING_VALUE` boundary) is proven by an offline truth-table incl. the classic
  "fields split across two instances must fail" trap; `BUFFER_STALE` is proven by the
  buffer-vs-AGR_1251 comparison. `MISSING_VALUE`/`BUFFER_STALE` were not reproduced live only
  because the pinned test user is near-`SAP_ALL` (no partial grant to provoke) — the logic,
  not the wiring, is what's under test there.
- **ECC 6 (SID ERP) parity:** every correlation table (AGR_*, USR02, UST04, UST12, TOBJ*,
  AUTHX) and the buffer FM are present + FMODE=R on ECC 6 per the plan's probe — one shared
  RFC backend, no divergence in the decode/eval layer.
- **Next phase:** `su53` (GUI auto-scrape of the failed objects — needs the SU53 golden-screen
  recording via `/sap-gui-probe`, and a *low-privilege* provocation user, since a near-SAP_ALL
  user produces no clean SU53 record to capture) and `trace` (STAUTHTRACE, S/4 only). v2:
  cross-user (`--user` other than self needs `S_USER_AUT`; refuse loud without it) and the
  SUIM `SUSR_SUIM_API_RSUSR002` "who has this auth" reverse lookup.
- **Read-only, always.** The skill never writes PFCG/SU01 data — the fix is a proposal
  document. A scrape/read that cannot run is `COULD_NOT_CHECK`, never rendered as "no failures".
- **Faithful semantics, not a guess:** the verdict is the kernel's own buffer, evaluated with
  real AUTHORITY-CHECK rules (single-instance-covers-all-fields, '*' wildcard, VON..BIS ranges).
  Org-level fields are reported as `MISSING_VALUE` with the field named; the dedicated
  `ORG_LEVEL_GAP` refinement (AGR_1252 cross-check) is a v2 nicety.
