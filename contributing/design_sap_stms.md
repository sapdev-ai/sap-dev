# Design Spec — `/sap-stms` (Transport landscape movement)

**Status:** PROPOSAL · **Author:** design pass 2026-06-03 · **Plugin:** sap-dev-core
**Pairs with:** `design_sap_fix_incident.md` · **Upstream:** `/sap-transport-readiness` → `/sap-se01 release`

---

## 1. Problem

The transport story today stops at **release**. `/sap-transport-request` and
`/sap-se01` create and release a TR; `/sap-transport-readiness` gates it. But
there is no way to **move a released TR through the landscape** (DEV → QAS →
PRD) or to read its import status / return code. "Get my change to QA / Prod"
— the single most common ask after a change is done — is unsupported.

STMS is the missing transaction. This adds `/sap-stms`.

## 2. Reality check (scoping honesty)

Two facts shape the design:

1. **Importing to QA/PROD is often Basis-gated.** In many shops a *developer*
   has no import authorization at all — imports are a Basis/release-manager
   action. So the **most-used mode in practice will be read-only status/logs**,
   with `import` reserved for shops where devs control QA. The skill must be
   useful read-only and must report `COULD_NOT_IMPORT` honestly when auth is
   missing — never fake a success.
2. **Import to production is the most outward-facing, least-reversible action
   in the entire toolset.** You can re-transport, but you cannot *un-import*.
   It therefore gets the strongest gate we have — stronger than `/sap-se01`
   release's single confirm.

## 3. Design principles

1. **Read-only default.** A bare `/sap-stms` shows queues + where a TR sits.
   Nothing moves without an explicit `import` verb.
2. **Tiered confirmation by blast radius.** QA = one explicit confirm; PROD =
   typed SID echo + a second "import to production" confirmation. `import-all`
   (whole queue) is off unless `--all` + double confirm.
3. **GUI for the action, RFC for the read.** Mirror `/sap-se01`: drive
   STMS/`STMS_IMPORT` via language-independent GUI scripting; read queue/status
   via RFC where a clean read FM exists (`TMS_MGR_READ_TRANSPORT_QUEUE`),
   falling back to GUI scrape. Keeps the action visible/robust and the status
   cheap.
4. **Truthful return codes.** Parse the import RC (0/4/8/12) and map to a
   verdict; **RC 8/12 = failure even if the queue row looks "done."** Never
   infer success from screen presence.
5. **Never import an unreleased or NO-GO TR** without `--force` (and say so).

## 4. Modes

```
argument-hint:
  "[status] [<TR>] [--system SID] [--route]
   | import <TR> --to SID [--client NNN] [--immediate] [--leave-in-queue] [--force]
   | import-all --to SID --all
   | logs <TR> --system SID
   [--connection PROFILE] [--report] [--out PATH]"
```

| Mode | Write? | Purpose |
|---|---|---|
| **status** (default) | no | Import queue of a target (or `--route` = all systems on the route); where `<TR>` currently sits; already-imported? |
| **logs** | no | Import log + step RC for `<TR>` in `<SID>` (ALOG/ULOG); RC→verdict. |
| **import** | **yes, gated** | Import one TR into one target system's queue + run import. |
| **import-all** | **yes, double-gated** | Import the whole queue into a target. Off without `--all`. |

## 5. `import` flow

Standard skeleton (Step 0 work_dir, Step 0.5 logging, Final log end).

**Step 1 — Parse & resolve the route.** TR (validate `<SID>K<digits>`) + `--to`
target. Read the TMS route/landscape (which systems exist, route position) so
we can classify the target as DEV / QA / PROD (route position, plus an optional
`userConfig.prod_system_ids` override list for certainty).

**Step 2 — Pre-flight gate (reuse the finding model).** Each a hard stop unless
overridden:

| Check | Source | Stop unless |
|---|---|---|
| TR released? | `E070-TRSTATUS = R` (RFC) | release first via `/sap-se01 release` |
| Already imported in target? | target queue / import history | already there → report + stop (no double import) |
| Readiness verdict | optional chained `/sap-transport-readiness <TR>` | NO-GO → stop unless `--force` |
| Target is PROD? | route position / `prod_system_ids` | escalate to the PROD gate (Step 3) |

**Step 3 — Confirmation (tiered).**
- **QA/test target:** "Import `<TR>` into `<SID>`/`<client>`? (yes/no)".
- **PROD target:** show the object inventory summary, then require the user to
  **type the target SID back** and confirm "import to production" — two
  signals, because this is outward-facing and irreversible. Refuse anything
  else. Log the confirmation explicitly.

**Step 4 — Run the import (GUI).** `STMS_IMPORT` for the target queue →
select the TR row by `TRKORR` (identify by grid cell value, not position) →
Import Request → fill the import-options dialog (target client, `--immediate`
vs scheduled, leave-in-queue) → confirm. Language-independent IDs; session
attach + session lock per the contracts. (RFC path via
`TMS_MGR_IMPORT_TRANSPORT` is a Phase-2 option behind `--rfc`; GUI is the
default for visibility + universal auth behaviour.)

**Step 5 — Verify.** Poll the import log until the step completes; read the RC.

| RC | Verdict |
|---|---|
| 0 | OK |
| 4 | OK_WITH_WARNINGS |
| 8 | ERROR (import errors — e.g. activation/gen failures) |
| 12 | FATAL (cancelled / system error) |

Fold into the finding model; register an import-evidence artifact for
`/sap-evidence-pack`.

**Step 6 — Report & next hop.** TR, target, RC, verdict, and the next system on
the route (e.g. "imported to QAS RC 4; next hop on the route is PRD — re-run
`/sap-stms import <TR> --to PRD` after QA sign-off").

### Status line

```
STATUS: IMPORTED tr=<TR> target=<SID>/<client> rc=<0|4|8|12> verdict=<OK|OK_WITH_WARNINGS|ERROR|FATAL>
STATUS: QUEUED tr=<TR> target=<SID>   (scheduled, not yet run)
STATUS: ALREADY_IMPORTED tr=<TR> target=<SID>
STATUS: COULD_NOT_IMPORT reason=<no-auth|not-released|no-go|not-in-queue>
STATUS: BLOCKED reason=<prod-not-confirmed|tr-not-released>
```

## 6. References / recording debt

New VBS under `references/` (each language-independent, session-attached):
`sap_stms_queue_read.vbs`, `sap_stms_import.vbs`, `sap_stms_log_read.vbs`,
plus the optional RFC reader `sap_stms_queue_rfc.ps1`
(`TMS_MGR_READ_TRANSPORT_QUEUE`). The STMS queue is an ALV/tree and the
import-options dialog varies by release → **a one-time `/sap-gui-record` pass
is required to capture the grid + dialog IDs** (same documented policy as
`/sap-atc` and `/sap-st22`). SKILL.md ships the recording steps + a
component-ID table.

## 7. Safety summary (the part to get right)

- Read-only default; `import` opt-in; `import-all` double-opt-in.
- PROD import = the single most-guarded action in the toolset (typed SID echo +
  second confirm + logged).
- Honesty contract: missing auth → `COULD_NOT_IMPORT`; RC 8/12 → failure even
  if the row "looks done"; unreleased/NO-GO TR refused without `--force`.
- Never targets a system the AI session isn't explicitly told to (`--to` is
  mandatory for any write; no "default target").

## 8. Test plan

- **Offline:** unit-test the RC→verdict map and the route/PROD classifier
  (incl. `prod_system_ids` override). Assert the PROD gate refuses on a
  mismatched typed SID.
- **Live:** in a sandbox landscape (or a single system with a self-route),
  `/sap-stms status` then `/sap-stms import <released-TR> --to <QAS>`; assert RC
  read + verdict; `/sap-stms logs` round-trips. Report to `temp/testReport/`.

## 9. Open questions

1. **RFC vs GUI for import.** TMS FMs (`TMS_MGR_IMPORT_TRANSPORT`) are
   RFC-enabled but need a TMS RFC destination + admin auth. Ship GUI-first,
   add `--rfc` later? (Lean: yes.)
2. **PROD detection.** Route-position heuristic vs an explicit
   `userConfig.prod_system_ids` allow-list. (Lean: both — list wins when set,
   so PROD is never misclassified as QA.)
3. **Scheduling.** Do we support import scheduling windows (off-hours), or only
   immediate/next-run? (Lean: immediate + next-run in v1; scheduling later.)
```
