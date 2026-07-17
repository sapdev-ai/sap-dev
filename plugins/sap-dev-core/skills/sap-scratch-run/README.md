# SAP Scratch-Run Skill

A guarded write-run-inspect REPL for SAP, so the AI can empirically **observe**
what the system does instead of guessing (the ABAP debugger is unreachable via
GUI Scripting). `run` turns a question into a tiny **read-only** `$TMP` probe
report, proves it is read-only, runs it, captures the answer, and cleans up —
never leaving a scratch object behind. `fm` calls a function module with a
supplied parameter set and captures the result plus wall-clock runtime. Both
paths let `/sap-gen-abap`, `/sap-fix-abap`, and `/sap-diagnose` verify SAP
behaviour empirically.

## Skill Overview

`run "<question>"`:

1. Generate `REPORT zzscratch_<runid8>.` answering the question with
   `SELECT … UP TO {--max-rows} ROWS` + `WRITE`/cl_salv — `$TMP`, no transport
2. **Modifiability guard** — RFC-check T000; refuse deploy on a
   non-modifiable / production client (`SCRATCH_ENV_REFUSED`)
3. **Read-only guard (hard)** — `sap_scratch_guard.ps1` statically scans the
   source; any write / `COMMIT` / `CALL TRANSACTION` / `SUBMIT` /
   dynamic-write / file / lock construct is a hard REFUSE
   (`SCRATCH_GUARD_VIOLATION`), never deployed
4. **Syntax gate** — headless `EDITOR_SYNTAX_CHECK` via the shared
   `sap_rfc_syntax_check.ps1`
5. **CONFIRM gate** — the generated ABAP + guard verdict + target SID/client
   are shown; deploy proceeds only on explicit `yes`
6. Deploy via `/sap-se38` (`$TMP`, activate), execute + capture via
   `/sap-run-report --foreground`
7. **Cleanup (always, even on execute failure)** — `/sap-se38 delete`, then an
   authoritative RFC re-read of TRDIR; an orphan is reported loud
   (`SCRATCH_CLEANUP_FAILED`), never a silent success

`fm <FM> [P=v ...]`:

1. **CONFIRM gate first** — an FM may mutate/COMMIT and the skill cannot
   statically prove otherwise (extra warning on a production client)
2. Route by `TFDIR.FMODE`: remote-enabled (`R`) → direct NCo call; classic
   (blank) → inline wrapper for simple scalar FMs, or delegate to
   `/sap-rfc-wrapper` for FMs with tables/structures
3. Capture exporting scalars, table row-counts, and wall-clock timing
4. `--save-as <name>` persists the parameter set under
   `{work_dir}\scratch\fm_datasets\<FM>\`; `--replay <name>` reloads it;
   `--list-datasets` enumerates (read-only, ungated)

## Auto-Trigger Keywords

- "what does the system actually return for ...", "probe SAP for ..."
- `scratch run`, "run a quick read-only probe"
- "call FM BAPI_XXX with ..." / "time function module XXX"

## Usage

```text
/sap-scratch-run run "how many MARA rows have MTART=FERT?" --show-code
/sap-scratch-run run "which company codes use CNY?" --values MAX=50
/sap-scratch-run fm FUNCTION_EXISTS FUNCNAME=RFC_SYSTEM_INFO
/sap-scratch-run fm Z_MY_FM P1=100 --save-as baseline
/sap-scratch-run fm Z_MY_FM --replay baseline
/sap-scratch-run fm --list-datasets
```

## Prerequisites

- SAP profile saved via `/sap-login`; for `run` an active GUI session
  (deploy/execute delegate to `/sap-se38` + `/sap-run-report`)
- The dev-init wrapper FM (`/sap-dev-init`) for the syntax gate and classic
  (blank-FMODE) FM calls
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC

## Key Reference Files

| File | Purpose |
|---|---|
| `references/sap_scratch_guard.ps1` | Read-only static guard (deny-set + Z/Y allow) — the load-bearing gate |
| `references/sap_scratch_fm.ps1` | FMODE-routed FM call + capture + wall-clock timing |

## Limitations / Safety

- `run` deploy sits behind **three independent layers** — confirm gate,
  read-only static guard, and the modifiability refusal — over a `$TMP`-only
  (no transport) footprint
- **Guard honesty:** a static scanner can be evaded by exotic dynamic ABAP;
  the `$TMP`-only + modifiability-refusal + confirm-gate layers are the
  defense-in-depth behind it. The deny-set is a reviewed, extensible table at
  the top of `sap_scratch_guard.ps1`
- `fm` is always confirm-gated — side effects cannot be statically excluded
- The inline wrapper route handles only simple scalar blank-FMODE FMs; a
  complex classic FM should go through `/sap-rfc-wrapper`
- Phase 2 (not yet implemented): `run --code=<file>` (operator ABAP, same
  guard) and `instrument` (probe-inject into Z code with restore-verify)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
