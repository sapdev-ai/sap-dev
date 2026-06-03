# Design Spec — `/sap-fix-incident` (Diagnose → Fix closed loop)

**Status:** PROPOSAL · **Author:** design pass 2026-06-03 · **Plugin:** sap-dev-core
**Pairs with:** `design_sap_stms.md` (the two compose into one incident→production pipeline)

---

## 1. Problem

`/sap-diagnose` is excellent at *finding* the root cause of an incident but,
by deliberate design, it is **PURE READ-ONLY** — Step 7 stops at a
`recommended_action` handoff and names the next command. The developer then
has to drive the fix by hand across `/sap-explain-object`, source download,
manual edit, `/sap-check-abap`, `/sap-se38|37|24`, `/sap-activate-object`,
`/sap-run-abap-unit`. That last mile is exactly where the time goes and where
mistakes happen — and it is the part an AI agent is best placed to close.

The catch: today there is **no skill that fixes a *runtime defect*.**
`/sap-fix-abap` is a deterministic, *offline* fixer that only consumes a
`/sap-check-abap` TSV and only handles `NAMING` / `UNUSED` (it explicitly
flags everything semantic as "manual review"). A short dump's fix —
an unchecked `sy-subrc`, an unhandled `CX_SY_*`, a missing bounds check, a
type overflow — is a **reasoned source change**, not a mechanical rename.

So B is a *new* capability, not an extension of `/sap-fix-abap`.

## 2. Design principles

1. **Keep `/sap-diagnose` read-only.** Its identity is "safe to point at
   production." We do **not** add writes to it. Instead `--fix` becomes entry
   sugar that, after presenting hypotheses, *chains* to a new write-capable
   skill. Diagnose's contract is preserved.
2. **Test-first or it isn't fixed.** No fix is reported "fixed" without a
   red→green transition (reproduce the defect in an ABAP Unit test, then prove
   the patch turns it green) — or an explicit `COULD_NOT_VERIFY` label. We
   never claim success we didn't observe (the project's honesty contract).
3. **Conservative by construction.** Only the `custom-code-defect` hypothesis
   category, only `Z*/Y*` objects, only after explicit confirmation
   (`skill_operating_rules` Rule 2). config-missing / data-defect /
   lock-contention route to their existing read-only or gated paths, untouched.
4. **Fix in DEV, never in the incident's own system.** A dump usually comes
   from PROD/QA. We never patch there (and usually can't — non-modifiable
   client). The fix is applied on the **DEV** system, produces a transport, and
   hands off to `/sap-stms` to move. This is the seam that links B → C.
5. **Bounded loop.** patch → check → deploy → test iterates at most
   `--max-rounds` (default 2); then it stops and presents the best diff for
   manual review. Never thrash against a live system.

## 3. Architecture

Three pieces, buildable in order:

| # | Piece | Type | Why |
|---|---|---|---|
| **P1** | `/sap-st22 --deep <dump_key>` | enhance existing reader | **Hard prerequisite.** You cannot fix a dump from a list row. Need the exception class, the failing include+line, the source snippet, and the call stack. ST22 today is "list-level only (v1)" — this is the v2 the SKILL.md already names. |
| **P2** | `/sap-fix-incident` | **new skill** (sap-dev-core) | The write-capable orchestrator. Consumes a diagnose deliverable (or a dump key), reasons the patch, verifies test-first, deploys to DEV behind a TR. |
| **P3** | `/sap-diagnose --fix` | one flag + a chained Skill call | Entry sugar. Diagnose stays read-only; on `--fix` + a custom-code-defect top hypothesis, it asks to proceed, then invokes `/sap-fix-incident --incident <deliverable.json>`. |

### 3.1 P1 — `/sap-st22 --deep`

Opens each in-scope dump (double-click the list row) and scrapes the detail
view into a `dump_detail` block appended to the existing diagnose evidence
event:

```
dump_detail: {
  exception_class,            // e.g. CX_SY_ZERODIVIDE  (or runtime error ID like COMPUTE_INT_ZERODIVIDE)
  short_text,
  failing_include,           // e.g. ZCL_FOO=========CM003 or ZMMR001
  failing_line,              // integer
  source_extract: [ {line, text, is_error_line} ],   // the "Source Code Extract" block, ~10 lines around the error
  call_stack: [ {include, line, event} ],            // "Active Calls/Events"
  chosen_variables: [ {name, value} ]                // best-effort; may be empty
}
```

GUI scraping notes (same recording-debt policy as ATC/ST22-list): detail-view
control IDs vary by release; try candidate IDs, then degrade to
`status=partial` with a `/sap-gui-record` hint — never a false-complete read.
The error line in "Source Code Extract" is marked by an icon/colour; identify
it by the leading marker column, not by text. Language-independent throughout.

### 3.2 P2 — `/sap-fix-incident` skill spec

Standard skeleton (Step 0 work_dir via `Get-SapWorkDir`, Step 0.5 logging,
Final log end) per CLAUDE.md. Substantive steps:

```
argument-hint:
  "--incident <diagnose.json> | --dump <key> | <type> <name>
   [--hypothesis N] [--apply] [--max-rounds 2] [--dev-connection PROFILE]
   [--no-test] [--report] [--out PATH]"
```

**Step 1 — Load the incident & pick the target.**
`--incident` = a `/sap-diagnose` deliverable JSON; pick hypothesis `rank 1`
(or `--hypothesis N`). If `--dump <key>`, run `/sap-st22 --deep` first. Refuse
if the chosen hypothesis category ≠ `custom-code-defect`, pointing at the right
path (config → IMG/read-only `/sap-se16n`; data → record; lock → `/sap-sm12`).

**Step 2 — Acquire failing source context.**
Ensure `dump_detail` is present (run P1 if the deliverable predates it).
Resolve object identity via `Resolve-SapObject` (Z/Y? package? **which
system?**). Build a comprehension map via `/sap-explain-object`.

**Step 3 — Guard rails (the safety gate).** Hard stops, each with a clear
message — never silently downgraded:

| Condition | Action |
|---|---|
| Root-cause object is **SAP standard** (not `Z*/Y*`) | STOP — "this is a Note / enhancement matter, not a code fix." Emit analysis only (Rule 1). |
| Incident system ≠ a modifiable DEV system | **Re-route** the fix to the DEV profile; the patch + TR are created in DEV, then moved via `/sap-stms`. Confirm the DEV target with the user. |
| Hypothesis confidence LOW **or** no failing line resolved | STOP — ask for a tighter `/sap-diagnose` anchor. We do not guess-patch. |
| Object locked by another user / inactive | STOP — surface it (reuse readiness checks). |

**Step 4 — Reproduce (RED).** Reason the defect from `dump_detail` + source.
Unless `--no-test`, generate a focused reproduction test via
`/sap-gen-abap-unit` (seam analysis → test double strategy) and run
`/sap-run-abap-unit`. Expect the test to **fail the same way**. If the code
has no testable seam → record `COULD_NOT_REPRODUCE` and force propose-only
(never auto-apply an unverifiable fix).

**Step 5 — Patch (offline).** Download current source (RFC reader / SE38·37·24
download). Apply the minimal edit to a working copy + `.bak`. Run
`/sap-check-abap` (+ `/sap-check-fm` for FMs) — no naming/type/SQL regression.
Build a unified diff.

**Step 6 — Confirm (Rule 2 gate).** Present: hypothesis + evidence ids, the
repro test, the diff. Default = **ask**. `--apply` skips the prompt *only* for
Z/Y-in-DEV; never for standard objects or a non-DEV target.

**Step 7 — Deploy to DEV.** TR via `/sap-transport-request`; deploy by type —
`/sap-se38` (program/include), `/sap-se37` (FM), `/sap-se24` (class, with the
repro test as a CCAU local test class via `--test-source`);
`/sap-activate-object`.

**Step 8 — Verify (GREEN).** Re-run `/sap-run-abap-unit --with-coverage` →
expect green. Optionally `/sap-atc` the changed object. Fold every result into
the reconciled finding model (`sap_finding_lib` → `sap_gate_policy`); register
artifacts for `/sap-evidence-pack`.

**Step 9 — Hand off to transport.** Print the TR and the exact next chain:
`/sap-transport-readiness <TR>` → `/sap-se01 release <TR>` →
`/sap-stms import <TR> --to <QAS>`.

**Step 10 — Bounded loop.** If not green, iterate Steps 5–8 up to
`--max-rounds`; then stop with the best diff + a `MANUAL_REVIEW` status.

### 3.3 Status line

```
STATUS: FIXED tr=<TR> object=<type:name> rounds=<n> test=RED→GREEN atc=<GO|—>
STATUS: PROPOSED object=<type:name> diff=<path>   (not applied — awaiting confirmation / unverifiable)
STATUS: NOT_CODE category=<config|data|lock> next=<command>
STATUS: BLOCKED reason=<standard-object|low-confidence|non-dev-target|locked>
STATUS: MANUAL_REVIEW rounds_exhausted diff=<path>
```

## 4. Reused skills (no rebuild)

`/sap-st22` (P1), `/sap-explain-object`, `Resolve-SapObject`,
`/sap-gen-abap-unit`, `/sap-run-abap-unit`, `/sap-check-abap`, `/sap-check-fm`,
`/sap-se38·37·24`, `/sap-activate-object`, `/sap-transport-request`,
`sap_finding_lib` + `sap_gate_policy` + `sap_artifact_lib`. New code is small:
the orchestrator SKILL.md + the ST22 deep-scrape VBS extension.

## 5. Test plan

- **Offline (no SAP):** feed a canned diagnose JSON with a `dump_detail` for a
  contrived `CX_SY_ZERODIVIDE` in a fixture `ZCL_*`; assert the skill produces
  a correct minimal diff + a reproduction test, and stops at PROPOSED without
  `--apply`. Assert standard-object and non-DEV-target guard rails fire.
- **Live (S4D):** plant a known defect in a sandbox `Z` report (e.g. divide by
  a selection-screen value), trigger the dump, run
  `/sap-diagnose --dump <k> --fix`; assert RED→GREEN, a TR, and a clean
  hand-off line. Write the report to `temp/testReport/`.

## 6. Open questions

1. **Repro without a unit seam.** For report-style code with no class seam, is
   re-executing the original tcode/program with the captured input an
   acceptable (sandbox-only) reproduction, or do we stay propose-only? Lean:
   propose-only unless the user opts in with `--repro-run` on a DEV system.
2. **Multi-object root cause.** If the fix spans >1 object, do we batch into one
   TR and one confirmation, or one pass per object? Lean: one TR, itemised diff,
   single confirmation.
3. **`--fix` default.** Should `/sap-diagnose --fix` ever auto-proceed, or
   always pause at the diff? Lean: always pause (Rule 2), `--apply` to opt out.
```
