---
name: sap-scratch-run
description: |
  A guarded write-run-inspect REPL for SAP so the AI can empirically OBSERVE what the system
  does instead of guessing (the ABAP debugger is unreachable via GUI Scripting). `run` turns a
  question into a tiny read-only $TMP probe report, statically guards it (a hard REFUSE on any
  write / COMMIT / CALL TRANSACTION / SUBMIT / dynamic-write / file / lock construct), syntax-
  checks it headlessly, deploys it ($TMP, no transport), executes and captures the list, then
  auto-deletes it and verifies the deletion. `fm` calls a function module with a supplied
  parameter set and captures the exporting/tables result + wall-clock runtime, routing by
  TFDIR.FMODE (remote-enabled → direct RFC; classic → the dev-init wrapper). Lets gen-abap /
  fix-abap / diagnose verify SAP behaviour empirically. Every deploy and every FM call is
  confirm-gated (an FM may mutate and the skill cannot statically prove otherwise); `run` also
  refuses on a non-modifiable/production client. Prerequisites: /sap-login; for `run` a GUI
  session (deploy/execute delegate to /sap-se38 + /sap-run-report); the dev-init wrapper for
  the syntax gate + classic FMs; SAP NCo 3.1 (32-bit).
argument-hint: "run \"<question>\" [--values P=v] [--show-code] | fm <FM> [P=v ...] [--save-as N] [--replay N] | fm --list-datasets"
---

# SAP Scratch-Run Skill

You close the write-run-inspect loop: generate a **read-only** probe, prove it's read-only,
run it, capture the answer, and clean up — never leaving a scratch object behind, never
deploying something that could write.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_scratch_guard.ps1` | `-SourceFile` | Read-only static guard (deny-set + Z/Y allow) — the load-bearing gate |
| `<SKILL_DIR>/references/sap_scratch_fm.ps1` | `-Fm -Values` | FMODE-routed FM call + capture + wall-clock timing |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_syntax_check.ps1` | `-Subc 1` | Headless EDITOR_SYNTAX_CHECK (via the wrapper) |
| `/sap-se38` | sub-skill | `$TMP` deploy + delete (symmetric, verified cleanup) |
| `/sap-run-report` | sub-skill | Foreground execute + list→spool capture (owns its Rule-5 gate) |
| `/sap-rfc-wrapper` | sub-skill | `fm` on a classic (blank-FMODE) FM with tables/structures |
| `/sap-login` | sub-skill | Session / pinned profile |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_scratch_run.json`). Generated scratch → `{RUN_TEMP}`.

## Step 1 — Parse & Dispatch

`run` (+ `--values`, `--show-code`, `--max-rows`) | `fm <FM>` (+ `P=v`, `--save-as`, `--replay`,
`--list-datasets`) | `instrument` → **phase 2**, cite the roadmap.

## Step 2 — Session / RFC

`/sap-login` if none. `run` needs a GUI session (deploy/execute). `fm` needs only RFC.

## Step 3 — `run` (generate → GUARD → syntax → confirm → deploy → execute → cleanup)

1. **Generate** `REPORT zzscratch_<runid8>.` into `{RUN_TEMP}\scratch_<runid>.abap` — answer the
   question with `SELECT … UP TO {--max-rows} ROWS` + `WRITE`/cl_salv, `$TMP`, no TR.
2. **Modifiability guard** — RFC-check T000: refuse deploy on a non-modifiable/production client
   (`SCRATCH_ENV_REFUSED`).
3. **Read-only guard (HARD):**
   ```bash
   ... sap_scratch_guard.ps1 -SourceFile "<abap>" -OutTsv "{RUN_TEMP}\scratch_scan.tsv"
   ```
   `STATUS: VIOLATION` → **REFUSE** (`SCRATCH_GUARD_VIOLATION`), print the `GUARD: DENY` lines,
   never deploy.
4. **Syntax gate** — `sap_rfc_syntax_check.ps1 -Subc 1`; errors → `SCRATCH_SYNTAX_ERROR`,
   regenerate-or-abort.
5. **CONFIRM gate** — show the generated ABAP + the guard verdict + target SID/client; proceed
   only on explicit `yes`.
6. **Deploy** → `/sap-se38` (`$TMP`, activate). **Execute + capture** → `/sap-run-report <PGM>
   --foreground --save-output={RUN_TEMP}\scratch_out.txt` (self-degrades RFC→SA38, owns its gate).
7. **Cleanup (ALWAYS, even on execute failure)** → `/sap-se38 delete zzscratch_<runid8>`, then
   RFC re-read `TRDIR` → row gone = authoritative; orphan → `SCRATCH_CLEANUP_FAILED` (loud, names it).

## Step 3F — `fm` (call + capture + time)

```bash
... sap_scratch_fm.ps1 -Fm <FM> -Values "P=v;P2=v2" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

**CONFIRM gate first** (an FM may mutate/COMMIT — cannot be statically proven read-only; extra
warning on a production client). The script reads `TFDIR.FMODE` and routes: `R` → **direct NCo
call** (scalar imports set, exporting scalars + tables row-counts + wall-clock ms captured);
blank → an inline wrapper best-effort for simple scalar FMs. For a classic FM with
tables/structures, **delegate `/sap-rfc-wrapper fm <FM> …`** (full asXML marshalling). Parse
`FM:route` / `FM:export` / `FM:table` / `FM:timing`. `--save-as <name>` persists the parameter
set as JSON under `{work_dir}\scratch\fm_datasets\<FM>\`; `--replay <name>` loads it;
`--list-datasets` enumerates (read-only, ungated).

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class): `SCRATCH_GUARD_VIOLATION` /
`SCRATCH_SYNTAX_ERROR` / `SCRATCH_CLEANUP_FAILED` / `SCRATCH_ENV_REFUSED` /
`FM_PROBE_WRAPPER_FAILED` / `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **Live-verified on S4D (S/4HANA 1909):** the **read-only guard** — a 10-case offline truth-table
  passes incl. the critical no-false-deny on comment- and string-embedded keywords, Z/Y-table
  writes and internal-table ops allowed, DB writes / `COMMIT` / `CALL TRANSACTION` / `SUBMIT` /
  dynamic `(lv)` targets / datasets / locks denied. The **`fm` direct route** (FMODE=R) is
  verified end-to-end (e.g. `FUNCTION_EXISTS FUNCNAME=RFC_SYSTEM_INFO` → `GROUP=SRFC …` + timing);
  FMODE routing + not-found are verified.
- **Delegated (not re-implemented):** `run`'s deploy/execute/delete go through `/sap-se38` +
  `/sap-run-report` (they own the GUI release-variant baselines + capture + their Rule-5 gate);
  the syntax gate reuses `sap_rfc_syntax_check.ps1`. `fm`'s classic-FM path with tables/structures
  delegates to `/sap-rfc-wrapper`; the inline wrapper route handles only simple scalar blank FMs
  (a complex one surfaces the wrapper's opaque `DYNAMIC_CALL_FAILED` → use `/sap-rfc-wrapper`).
- **ECC 6 parity:** every load-bearing object (wrapper, RPY_FUNCTIONMODULE_READ_NEW, TFDIR/TRDIR,
  SE38/SE37) is present on both per the plan's probe; release variance is carried by the delegated
  `/sap-se38` + `/sap-run-report`. No new GUI layout recorded here.
- **Safety:** `run` deploy is confirm-gated AND read-only-guarded AND modifiability-refused —
  three independent layers behind a `$TMP`-only (no transport) footprint; `fm` is confirm-gated
  (side effects cannot be statically excluded). Cleanup is fail-loud (a surviving `$TMP` program
  is named, never a silent success). **Phase 2:** `run --code=<file>` (operator ABAP, same guard),
  `instrument` (probe-inject into Z code with mandatory restore-verify).
- **Guard honesty:** a static scanner can be evaded by exotic dynamic ABAP; the `$TMP`-only +
  modifiability-refusal + confirm-gate layers are the defense-in-depth behind it. The deny-set is
  a reviewed, extensible table at the top of `sap_scratch_guard.ps1`.
