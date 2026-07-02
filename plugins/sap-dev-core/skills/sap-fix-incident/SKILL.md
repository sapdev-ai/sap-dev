---
name: sap-fix-incident
description: |
  Closes the loop from a /sap-diagnose root cause to a deployed, test-verified
  fix — conservatively and test-first. Takes a diagnose deliverable (or a dump
  key) whose top hypothesis is a CUSTOM-CODE DEFECT, acquires the failing source
  (via /sap-st22 --deep + the RFC source reader / SE24 download), reasons a
  minimal patch, reproduces the defect in an ABAP Unit test (RED) via
  /sap-gen-abap-unit, applies the patch, re-checks with /sap-check-abap, deploys
  to a modifiable DEV system behind a transport (/sap-se38|37|24 +
  /sap-activate-object), and proves the test GREEN with /sap-run-abap-unit.
  HARD GUARD RAILS: only custom-code-defect hypotheses on Z*/Y* objects; never
  patches SAP standard code (-> Note/enhancement, analysis only); never writes to
  the incident's own system when that is non-modifiable / production — the fix is
  made in DEV and handed to /sap-transport-readiness -> /sap-se01 release ->
  /sap-stms. Deploy is gated (skill_operating_rules Rule 2): default is to
  PROPOSE a diff and wait for confirmation. Findings flow through the reconciled
  finding model and register for /sap-evidence-pack.
  Prerequisites: a /sap-diagnose deliverable or a dump; pinned DEV profile
  (/sap-login) + active SAP GUI session; SAP NCo 3.1 (32-bit) for RFC.
argument-hint: "--incident <diagnose.json> | --dump <KEY> | <type> <name>  [--hypothesis N] [--apply] [--max-rounds 2] [--dev-connection PROFILE] [--no-test] [--report] [--out PATH]"
---

# SAP Fix Incident Skill (diagnose -> fix closed loop)

You turn a root-caused incident into a **deployed, test-verified** source fix —
the last mile `/sap-diagnose` deliberately leaves open (it is read-only). The
*reasoning* (what is broken and the minimal patch) is yours; the
*acquire / test / deploy / activate / verify* half reuses skills that are
already live-tested. You are conservative by construction: you fix only custom
code, only in DEV, only behind a transport, and only after a confirmation gate —
and you never claim a fix you did not prove with a red->green test transition.

Task: $ARGUMENTS

This skill observes `shared/rules/skill_operating_rules.md`. **Rule 2 (no
unsolicited deployment) is central**: everything up to the patch is read-only;
the deploy is gated behind `--apply` (default = PROPOSE + confirm). It is the
write-capable companion to the read-only `/sap-diagnose`.

---

## Shared Resources

| File / token | Path | Purpose |
|---|---|---|
| `skill_operating_rules.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\skill_operating_rules.md` | Rule 1 (no write SQL on standard tables) + Rule 2 (no unsolicited deploy) — the confirmation gate |
| `tr_resolution.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\tr_resolution.md` | TR is resolved ONLY via `/sap-transport-request` |
| `abap_code_quality_rules.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\abap_code_quality_rules.md` | the patch must stay modern-syntax + message-class clean (no literal MESSAGE strings, no obsolete forms) |
| `settings_lookup.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\settings_lookup.md` | per-key settings merge; per-connection pin |
| `sap_settings_lib.ps1` + `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\` | `Get-SapWorkDir`, pinned profile, `Get-SapCurrentSessionPath` |
| `sap_object_resolver.ps1` (`%%OBJECT_RESOLVER_PS1%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1` | `Resolve-SapObject` — Z/Y? package? **which system**? active? |
| `sap_rfc_read_source.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1` | `Read-SapAbapSource` (program / include / FM) for the patch |
| `sap_finding_lib.ps1` / `sap_gate_policy.ps1` / `sap_artifact_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\` | finding model + gate + artifact registration |
| `diagnose_evidence_schema.json` | `<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-diagnose\references\diagnose_evidence_schema.json` | the `dump_detail` input contract this skill consumes |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

**Skills this one orchestrates** (skills-first, per CLAUDE.md Rule 6 — invoke via
the Skill tool, never re-implement): `/sap-st22` (`--deep`),
`/sap-explain-object`, `/sap-gen-abap-unit`, `/sap-run-abap-unit`,
`/sap-check-abap`, `/sap-check-fm`, `/sap-se38`, `/sap-se37`, `/sap-se24`,
`/sap-activate-object`, `/sap-transport-request`, `/sap-transport-readiness`,
`/sap-se01`, `/sap-stms` (when available — until then, hand off to manual STMS).

`<SAP_DEV_CORE_SHARED_DIR>` = `plugins/sap-dev-core/shared` — 3 levels up from
`<SKILL_DIR>`, then into `sap-dev-core\shared`.

---

## Step 0 — Resolve Work Directory and Settings

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`.
Set `{WORK_TEMP}` = `{work_dir}\temp`, `{RUN}` = `{WORK_TEMP}\fix_incident\<run>`:

```bash
cmd /c if not exist "{WORK_TEMP}\fix_incident" mkdir "{WORK_TEMP}\fix_incident"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's `_run.json` log state under `{RUN_TEMP}` (the working files already live in the per-run `{RUN}`).

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_fix_incident_run.json" -Skill sap-fix-incident -ParamsJson "{}"
```

---

## Step 1 — Load the Incident and Pick the Target Hypothesis

Parse `$ARGUMENTS`:

| Arg | Meaning |
|---|---|
| `--incident <path>` | A `/sap-diagnose` deliverable JSON (`incident_run` + `hypotheses` + `evidence`). Preferred entry. |
| `--dump <KEY>` | A synthetic ST22 `dump_key` (`yyyymmdd+hhmmss+program`). No diagnose JSON — this skill runs `/sap-st22 --deep --dump-key <KEY>` itself, then reasons a single-cause hypothesis. |
| `<type> <name>` | Direct object target (e.g. a known failing FM) without a diagnose run — treat as a self-declared custom-code-defect hypothesis on that object. |
| `--hypothesis N` | Pick hypothesis rank N (default = rank 1). |
| `--apply` | Skip the propose-and-confirm gate for the DEV deploy (still NEVER for standard objects / non-DEV targets). |
| `--max-rounds N` | Cap on patch->deploy->test iterations (default 2). |
| `--dev-connection PROFILE` | The modifiable DEV profile to fix on, when the incident system is not it. |
| `--no-test` | Skip the reproduce/verify test loop (downgrades the result to PROPOSE-only; discouraged). |

Select the target hypothesis. **If its category is NOT `custom-code-defect`,
stop and route** (do not attempt a code fix):

| Category | Route (no code fix) |
|---|---|
| `config-missing` | name the IMG / config table; verify read-only via `/sap-se16n` |
| `data-defect` | point at the offending record (read-only `/sap-se16n`) |
| `lock-contention` | **manual** — open **SM12** (`/nSM12`), find the row, confirm with the lock owner, then **Lock Entry → Delete** by hand. `/sap-sm12` is read-only (no automated release). |
| `stuck-update` | **manual** — open **SM13** (`/nSM13`), find the failed record, confirm with the update owner, then **Repeat Update / Delete** by hand. `/sap-sm13` is read-only (no automated reprocess). |

Echo `TARGET: hypothesis=<rank> category=custom-code-defect confidence=<H|M|L>`.

## Step 2 — Acquire the Failing Source Context

1. **Deep dump detail.** If the incident JSON lacks a `dump_detail` block for the
   target (i.e. it predates `/sap-st22 --deep`), run
   `/sap-st22 --deep --dump-key <dump_key>` now and read back
   `failing_include` / `failing_line` / `source_extract` / `exception_class`.
   If `detail_status=partial` (HTML-rendered dump — no line captured), say so and
   rely on the exception + program; do **not** guess a line.
2. **Object identity.** Resolve via `Resolve-SapObject` (32-bit; creds fall back
   to the pinned profile): `{PGMID}`, TADIR object code, **package**, **system**,
   `active`. Capture whether the object is `Z*/Y*`.
3. **Comprehension map.** Run `/sap-explain-object <type> <name>` for the unit /
   data / call map around the failing line.

## Step 3 — Guard Rails (hard stops — never silently downgraded)

| Condition | Action |
|---|---|
| Root-cause object is **SAP standard** (not `Z*/Y*`) | **STOP.** Emit analysis only: "Root cause is in standard `<obj>` — this is a SAP Note / enhancement matter, not a code fix." (Rule 1) |
| Incident system is **not** a modifiable DEV system (production / non-modifiable client) | **Re-route to DEV.** Confirm `--dev-connection` (or the pinned DEV profile). The patch + TR are created in DEV; the change reaches the incident system later via transport, never by a direct write. |
| Hypothesis confidence **LOW**, or no `failing_line` and no clear defect from the source | **STOP.** Ask for a tighter `/sap-diagnose` anchor. No guess-patching. |
| Object inactive or **locked by another user** | **STOP.** Surface it; resolve the lock/activation first. |

Echo `GUARD: ok target_system=<DEV-SID> object=<Z..> kind=<PROGRAM|FM|CLASS>`
or the stop reason.

## Step 4 — Reproduce the Defect (RED)

Unless `--no-test`: drive `/sap-gen-abap-unit <name> --type <t> --deploy no` to
generate a focused test that exercises the failing path (feed it the
`dump_detail` + the defect you reason). Deploy that test to DEV (gated, Step 6
applies) and run `/sap-run-abap-unit` — **expect it to FAIL the same way** (the
dump's exception). This proves the hypothesis before you touch the code.

- Reproduced (RED) → proceed; the fix must turn it green.
- `COULD_NOT_REPRODUCE` (no testable seam — `/sap-gen-abap-unit` flags it) →
  force **PROPOSE-only** for the rest of the run; never auto-apply an
  unverifiable fix.

## Step 5 — Patch (offline)

1. Download current source: `Read-SapAbapSource` (program / include / FM) or the
   `/sap-se24` download (class) — as `/sap-explain-object` does — to `{RUN}\src`.
2. Apply the **minimal** edit to a working copy (+ `.bak`). Keep it scoped to the
   defect (e.g. guard the divisor, check `sy-subrc`, bound the index, handle the
   `CX_*`). Do not refactor opportunistically.
3. Re-check offline: `/sap-check-abap {RUN}\src\<file>` (+ `/sap-check-fm` for an
   FM call). Fix anything it flags. Build a unified diff `{RUN}\fix.diff`.

## Step 6 — Confirm (Rule 2 gate)

Present to the user: the hypothesis + evidence ids, the reproduction test
(RED), and the diff. Then:

- Default (no `--apply`) → **ask**: "Apply this fix to `<obj>` on `<DEV-SID>`
  behind a transport? (yes / no)". Proceed only on explicit `yes`.
- `--apply` → proceed **only** for a `Z*/Y*` object on a modifiable DEV system.
  Never auto-apply to a standard object or a non-DEV target (Step 3 already
  blocks those).

## Step 7 — Deploy to DEV

1. Resolve a TR via `/sap-transport-request` (single entry point; honours
   `way_to_get_transport_request`).
2. Deploy by type: `/sap-se38` (program / include), `/sap-se37` (FM), `/sap-se24`
   (class — include the reproduction test as a CCAU local test class via
   `--test-source` so the regression guard ships with the fix).
3. `/sap-activate-object <type> <name>`.

## Step 8 — Verify (GREEN)

1. Re-run `/sap-run-abap-unit <container> --with-coverage` — **expect GREEN**
   (the reproduction test now passes). If still RED and `round < --max-rounds`,
   loop back to Step 5 with the failure feedback.
2. Optionally `/sap-atc <type> <name>` on the changed object as a quality gate.
3. Fold the test verdict + ATC into the reconciled finding model
   (`sap_finding_lib` -> `sap_gate_policy`); register `fix.diff`, the test, and
   the report via `sap_artifact_lib` so `/sap-evidence-pack` collects them.

## Step 9 — Hand Off to Transport (never auto-release, never auto-import)

Print the TR and the exact next chain — the user takes these deliberately:

```
/sap-transport-readiness <TR>      # GO/NO-GO gate
/sap-se01 release <TR>             # irreversible — user's explicit step
/sap-stms import <TR> --to <QAS>   # landscape movement (when /sap-stms exists)
```

This skill releases nothing and imports nothing.

## Step 10 — Bounded Loop / Stop Honestly

If GREEN is not reached within `--max-rounds`, **stop** and report the best
state: the diff, what the test still shows, and a `MANUAL_REVIEW` status. Never
thrash against the live system.

### Status line

```
STATUS: FIXED tr=<TR> object=<type:name> rounds=<n> test=RED->GREEN atc=<GO|-> sys=<DEV-SID>
STATUS: PROPOSED object=<type:name> diff=<path>   (not applied — awaiting confirmation / unverifiable)
STATUS: NOT_CODE category=<config|data|lock|stuck-update> next=<command>
STATUS: BLOCKED reason=<standard-object|low-confidence|non-dev-target|locked|inactive>
STATUS: MANUAL_REVIEW rounds_exhausted diff=<path>
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_fix_incident_run.json" -Status SUCCESS -ExitCode 0
```

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Fixed, test RED->GREEN, deployed to DEV | `-Status SUCCESS -ExitCode 0` |
| Proposed only (no `--apply`, or unverifiable) | `-Status SUCCESS -ExitCode 0` |
| Not a code defect (routed elsewhere) | `-Status SKIPPED -ExitCode 0 -ErrorClass FIX_INCIDENT_NOT_CODE` |
| Blocked by a guard rail | `-Status SKIPPED -ExitCode 1 -ErrorClass FIX_INCIDENT_BLOCKED` |
| Loop exhausted without green | `-Status FAILED -ExitCode 1 -ErrorClass FIX_INCIDENT_NOT_GREEN` |
| Source could not be acquired / RFC failure | `-Status FAILED -ExitCode 2 -ErrorClass FIX_INCIDENT_SOURCE_UNAVAILABLE` |

---

## Known Issues / Failure Modes

| Symptom | Cause | Recovery |
|---|---|---|
| `BLOCKED standard-object` | the dump's root cause is in SAP standard code | this is a Note / enhancement, not a code fix — surface the analysis, do not patch |
| `BLOCKED non-dev-target` | the incident system is production / non-modifiable | pass `--dev-connection <DEV>`; the fix is made in DEV and transported |
| `dump_detail.detail_status=partial` (no failing line) | HTML-rendered dump — `/sap-st22 --deep` could not scrape the body | calibrate the ST22 detail-screen IDs via `/sap-gui-record`; meanwhile reason from the exception + program, and stay PROPOSE-only if the line is essential |
| `COULD_NOT_REPRODUCE` | the object has no unit-test seam (hard-wired statics / monolithic FORMs) | `/sap-gen-abap-unit` flags the needed refactor; the fix stays PROPOSE-only (no auto-apply without a regression guard) |
| loop never reaches green | the hypothesis was wrong, or the fix is incomplete | stop at `--max-rounds`, present the diff, re-run `/sap-diagnose` for a better root cause |

## Limitations

- **The patch is reasoned, not guaranteed correct on the first round** — that is
  why the reproduce-then-verify loop and `--max-rounds` exist. A fix is only
  reported `FIXED` on an observed RED->GREEN transition; otherwise it is
  `PROPOSED` / `MANUAL_REVIEW`.
- **Custom code only.** Standard-object root causes are out of scope by design
  (Rule 1) — analysis is emitted, no write.
- **Fixes land in DEV behind a transport.** This skill never writes to the
  incident's own system and never releases or imports — that is the deliberate
  `/sap-transport-readiness` -> `/sap-se01 release` -> `/sap-stms` chain.
- **Single root cause per invocation.** A multi-object cause is itemised into one
  TR with one confirmation; re-invoke per distinct hypothesis if needed.
- **Depends on `/sap-st22 --deep` calibration** for the failing line on
  HTML-rendered dumps (see the partial-detail row above).

---

## Pipeline Integration

```
incident ─► /sap-diagnose (read-only root cause)
              └─► [ sap-fix-incident ]  reproduce(RED) ─► patch ─► /sap-check-abap
                        └─► /sap-se38|37|24 ─► /sap-activate-object ─► /sap-run-abap-unit (GREEN)
                                  └─► /sap-transport-readiness ─► /sap-se01 release ─► /sap-stms
```

The write-capable companion to `/sap-diagnose`. `/sap-diagnose --fix` is the
intended entry sugar (it presents hypotheses, then chains here on a
custom-code-defect top hypothesis) — diagnose itself stays read-only.
