---
name: sap-se14
description: |
  SE14 (DB Utility) for stuck DDIC tables — closes the gap /sap-se11 names but never implemented.
  check is a read-only RFC snapshot of DDIC-vs-DB consistency (DD02L active row + pending version,
  DWINACTIV inactive worklist, TBATG open conversion/DB-utility request with its state, DBDIFF
  DDIC/DB diff, QCM<T>/QCM8<T> shadow table, DDPRH log header) -> verdict CONSISTENT /
  ADJUST_NEEDED / CONVERSION_RUNNING / CONVERSION_TERMINATED / NOT_FOUND; it is safe to auto-chain
  after a failed table activation. adjust drives SE14 "Activate and adjust database" on the
  **save-data path only** — the delete-data radio is structurally unreachable (no code path selects
  it; the save-data radio is asserted by component ID before the adjust press), not merely gated.
  unlock recovers a TERMINATED conversion (continue = restart; release-lock only when a QCM-data
  guard proves no data is stranded). Both write modes are confirm-gated, GUI-driven (SAPMSGTB,
  identical on both releases), and post-verified by an authoritative RFC re-read. No TR (SE14 is a
  DB-level op, not a repository change); no new Z object; the DB-existence probes degrade to
  COULD_NOT_CHECK without the optional dev-init wrapper. Prerequisites: pinned /sap-login RFC
  profile for check; a live GUI session for adjust/unlock; NCo 3.1 (32-bit).
argument-hint: "check <TABLE> | adjust <TABLE> | unlock <TABLE> [continue]"
---

# SAP SE14 DB Utility Skill

You diagnose a stuck table (`check`, read-only, auto-chainable) and, on request, fix it via the
**save-data-only** adjust or a terminated-conversion unlock — both confirm-gated, with the
delete-data path structurally refused, verified by an authoritative RFC re-read.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_se14_check_rfc.ps1` | `-Table` | RFC consistency battery + verdict (also the write-mode post-verify) |
| `<SKILL_DIR>/references/sap_se14_adjust.vbs` · `sap_se14_unlock.vbs` | GUI | SAPMSGTB drivers (save-data-only / conversion recovery) — `NEEDS_RECORDING` until captured |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` · `sap_attach_lib.vbs` · `sap_session_lock.vbs` | libs | RFC + Tier-3 attach + session lock |
| `/sap-activate-object` · `/sap-run-report` (RADPROTA) · `/sap-se16n` · `/sap-dev-status` | sub-skills | Plain reactivate / full log (v1.5) / raw dumps / wrapper preflight |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_se14_run.json`). Pinned RFC profile for check; GUI session for write modes.

## Step 1 — Parse & Dispatch

`check` | `adjust` | `unlock` (token `continue` -> unlock/continue). Uppercase `<TABLE>`. **Any
wording asking for the delete-data variant -> immediate refusal `SE14_DELETE_PATH_REFUSED`** (v1
has no override), no further steps. `--background` -> "v1.5".

## Step 2 — check (always runs first)

```bash
... sap_se14_check_rfc.ps1 -Table <T> -OutDir "{RUN_TEMP}\se14"
```

`SE14: CHECK <probe>=<state>` lines + `SE14: VERDICT <v>` + `se14_check_<T>.tsv`. Mode `check` ->
stop here (report verdict + suggested `adjust`/`unlock` command). CONSISTENT + `adjust` -> nothing
to do (if only DWINACTIV set, suggest `/sap-activate-object`). RFC down -> GUI SE14-check fallback.

## Step 3 — write-mode guards (adjust/unlock)

TABCLASS != TRANSP -> `SE14_UNSUPPORTED_TABCLASS`. Verdict CONVERSION_RUNNING -> refuse both write
modes (`SE14_CONVERSION_RUNNING`). `unlock` requires verdict CONVERSION_TERMINATED. `unlock
release-lock` additionally runs the QCM-data guard (wrapper `DD_EXISTS_DATA` on the QCM table; data
found OR COULD_NOT_CHECK -> `SE14_QCM_DATA_AT_RISK`, refused in v1).

## Step 4 — CONFIRM gate + drive (adjust/unlock)

**CONFIRM** (mandatory yes/no): adjust -> "I will ACTIVATE AND ADJUST table `<T>` on
`<SID>/<CLIENT>` via the SAVE-DATA path (data preserved). Proceed?"; unlock/continue -> equivalent.
On no -> `SKIPPED`. Then generate the VBS from the reference (UTF-8 read -> token substitute ->
UTF-16 LE BOM), select variant via `sap_select_vbs_variant.ps1`, run via 32-bit cscript. **Structural
delete-data rail:** the VBS asserts the save-data radio's component ID exists AND `.Selected=True`
before the adjust press, and never `.Select`s the delete-data radio; an unknown layout ->
`SE14: NEEDS_RECORDING` (record via `/sap-gui-probe --record`), never a guessed radio.

## Step 5 — Post-verify + Register

Re-run `sap_se14_check_rfc.ps1` — only a clean re-read (DD02L active + no pending, DWINACTIV empty,
no TBATG, QCM gone) yields SUCCESS; GUI status text alone never does. `Register-SapArtifact`
(kind `ddic-consistency`, verdict) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `SE14_DELETE_PATH_REFUSED`,
`SE14_CONVERSION_RUNNING`, `SE14_QCM_DATA_AT_RISK`, `SE14_UNSUPPORTED_TABCLASS`, `SE14_ADJUST_FAILED`;
reused `RFC_LOGON_FAILED` / `GUI_TIMEOUT` / `GUI_LAYOUT_UNKNOWN`.

---

## Scope & Limitations (v1)

- **check live-verified on S4D (S/4HANA 1909) 2026-07-11:** MARA/T000 -> CONSISTENT (DD02L ACTIVE +
  0 pending, DWINACTIV CLEAN, TBATG NONE, DBDIFF CLEAN, QCM NONE), a nonexistent table -> NOT_FOUND;
  the DB-existence probes report COULD_NOT_CHECK honestly (their FMs are FMODE-blank -> optional
  wrapper path). EC2 (ECC 6) was probed in-plan (all tables + SAPMSGTB identical) but unreachable at
  build time; one RFC code path. **Build-time finding:** DBDIFF keys on OBJNAME (not TABNAME); the
  DDXTT inactive-nametab read is deliberately dropped — the nametab's binary RAW columns make
  RFC_READ_TABLE raise an ASSIGN-CASTING dump, and DWINACTIV + pending-version already cover
  "inactive".
- **adjust/unlock are GUI-only, confirm-gated writes** (no RFC path — `DDIF_TABL_ACTIVATE` is
  FMODE-blank and doesn't drive conversion control). The **delete-data path is structural, not
  gated**: no VBS code path selects that radio, and the save-data radio is asserted by component ID
  before the adjust press. The SAPMSGTB control IDs need a one-time `/sap-gui-probe --record` capture
  per release (`NEEDS_RECORDING` until then) — done at install time, never guessed.
- **No TR** — SE14 adjustment is a DB-level operation, not a repository change (documented to preempt
  reviewers). No new Z object; the wrapper is never auto-deployed.
- `/sap-se11` auto-chains `/sap-se14 check <TABLE>` after a failed table activation (read-only, safe)
  and surfaces the verdict + suggested write command; the user still triggers the write.
- **v1.5:** `adjust --background` (TBATG), full log via RADPROTA, DB-existence via the wrapper.
  **v2:** index-rebuild / storage-parameter verbs; delete-data + forced-unlock (typed-echo confirm).
