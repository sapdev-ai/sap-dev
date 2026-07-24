# Design & Implementation Spec — `/sap-run-report` and `/sap-job`

Status: **BUILT / implemented (2026-07-09)** — kept as the design + build record for
the two runtime-execution skills of sap-dev-core (see the per-phase ✅ BUILT notes in
§4). Placement: `docs/architecture/` (promote/split into `contributing/` only once a
contract is CI-enforced).

This spec is the single source of truth for building the two skills. It mirrors the
conventions of the existing sibling skills — `sap-run-abap-unit` (result-parse + verdict
gate), `sap-rfc-wrapper` (asXML wrapper calls), `sap-sp02` (spool → file), and the
`sap_dev_mode` GUI/RFC dispatch of `sap-function-group` / `sap-dev-init`.

---

## 0. Decisions locked (confirm before build)

| # | Decision | Locked value | Note |
|---|---|---|---|
| D1 | Skill count | **1 now** (`/sap-run-report`), **1 planned** (`/sap-job`) | job builds only on real demand |
| D2 | Names | `/sap-run-report`, `/sap-job` (capability names) | matches `/sap-run-abap-unit`, `/sap-activate-object` |
| D3 | Default run engine | **foreground in Phase A** (clean bg capture is the Phase-B `Z_RUN_REPORT` path) → flips to **background + spool capture** once Phase B lands | dump-safe & capturable for AI-mediated use; `--background` available in A but degrades to "submitted, monitor via SM37/`/sap-job`" without RFC |
| D4 | Backend model | **dispatch chain**, not a phase gate: honor `sap_dev_mode`; RFC preferred → **GUI always-available fallback** | GUI ships from day one |
| D5 | `Z_RUN_REPORT` FM | Phase **B** (deployed by `/sap-dev-init`); Phase **A** ships GUI-only | background works GUI-only via SA38-F9 until then |
| D6 | Variant persistence w/o RFC | **degrade loudly**; cover the *use case* with foreground `--values` | GUI variant-save needs the dynamic selection screen |

---

## 1. Shared building blocks (build once; both skills consume)

### 1.1 `Z_RUN_REPORT` — purpose-built RFC FM (deployed by `/sap-dev-init`)
Needed because `SUBMIT … VIA JOB … USING SELECTION-SET` is an ABAP **statement**, not
an FM — the generic `Z_GENERIC_RFC_WRAPPER_TBL` cannot host it. **RFC-enable this FM**
(processing type Remote-Enabled) so NCo calls it directly — no generic wrapper needed.

```abap
FUNCTION z_run_report.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_PROGRAM)  TYPE  SYREPID
*"     VALUE(IV_VARIANT)  TYPE  RALDB_VARI OPTIONAL
*"     VALUE(IV_JOBNAME)  TYPE  BTCJOB      OPTIONAL
*"     VALUE(IV_IMMED)    TYPE  CHAR1       DEFAULT 'X'
*"  EXPORTING
*"     VALUE(EV_JOBNAME)  TYPE  BTCJOB
*"     VALUE(EV_JOBCOUNT) TYPE  BTCJOBCNT
*"     VALUE(EV_STATUS)   TYPE  CHAR20
*"----------------------------------------------------------------------
  DATA lv_jobname  TYPE btcjob.
  DATA lv_jobcount TYPE btcjobcnt.

  lv_jobname = COND #( WHEN iv_jobname IS INITIAL THEN iv_program ELSE iv_jobname ).

  CALL FUNCTION 'JOB_OPEN'
    EXPORTING  jobname  = lv_jobname
    IMPORTING  jobcount = lv_jobcount
    EXCEPTIONS OTHERS   = 1.
  IF sy-subrc <> 0. ev_status = 'OPEN_FAILED'. RETURN. ENDIF.

  IF iv_variant IS NOT INITIAL.
    SUBMIT (iv_program) VIA JOB lv_jobname NUMBER lv_jobcount
           USING SELECTION-SET iv_variant AND RETURN.
  ELSE.
    SUBMIT (iv_program) VIA JOB lv_jobname NUMBER lv_jobcount AND RETURN.
  ENDIF.
  IF sy-subrc <> 0. ev_status = 'SUBMIT_FAILED'. RETURN. ENDIF.

  CALL FUNCTION 'JOB_CLOSE'
    EXPORTING  jobcount  = lv_jobcount
               jobname   = lv_jobname
               strtimmed = iv_immed
    EXCEPTIONS OTHERS    = 1.
  IF sy-subrc <> 0. ev_status = 'CLOSE_FAILED'. RETURN. ENDIF.

  ev_jobname  = lv_jobname.
  ev_jobcount = lv_jobcount.
  ev_status   = 'SUBMITTED'.
ENDFUNCTION.
```

- Deployed by `/sap-dev-init` (add a step after the wrapper), source under
  `sap-rfc-wrapper/references/` or a new `sap-dev-init` artefact. Registered in
  `sap_dev_artefacts.ps1` (dev-status/dev-clean see it) and `sap-dev-status`.
- Reused verbatim by `/sap-job schedule` (with start-condition args added later).

### 1.2 Variant maintenance — IMPLEMENTED (2026-07-09)
**set/create + delete: GUI** via `references/sap_sa38_variant.vbs` (SAPLSVAR 281 attributes /
322 delete-scope + SPOP confirm), probed and verified live on S4D end-to-end
(create → overwrite → delete round-trip, no artifacts left). **list/show: RFC** via
`/sap-rfc-wrapper fm RS_VARIANT_CATALOG / RS_VARIANT_CONTENTS`. The GUI path was chosen over the
originally-planned RFC `sap_variant_rfc.ps1` for *set* because it was live-verifiable immediately
and needs no dev wrapper; a future RFC fast-path (SELNAME-based `RS_CREATE_VARIANT`, avoiding the
dynamic selection screen) can still be added and, on `/sap-job` build, hosted in
`shared/scripts/sap_variant_lib.ps1` as the shared variant lib.

| Action | FM | Notes |
|---|---|---|
| list | `RS_VARIANT_CATALOG` | variants for a report |
| show | `RS_VARIANT_CONTENTS` | returns `RSPARAMS` rows (SELNAME/KIND/SIGN/OPTION/LOW/HIGH) |
| set (create/edit) | `RS_CREATE_VARIANT` / `RS_CHANGE_VARIANT_ALL_TYPES` | needs the field list — read it first (§2.6) |
| delete | `RS_VARIANT_DELETE` | |
| exists | `RS_VARIANT_EXISTS` | pre-check |

> Confirm exact signatures at build time via `/sap-rfc-wrapper fm <FM>` (it reads the
> interface) — do not hardcode from memory.

### 1.3 Reuse map (skills-first — never rebuild)
| Need | Reuse |
|---|---|
| Spool → local text | `/sap-sp02 <LISTIDENT> <path>` |
| Dump detail after an aborted run | `/sap-st22` (deep) |
| Session / login | `/sap-login`, `sap_attach_lib.vbs` (Tier-3 attach) |
| TR (variant transport only — rare) | `/sap-transport-request` |
| Logging / artifact index | `sap_log_helper.ps1`, `sap_artifact_lib.ps1` |
| Release-specific GUI IDs | capture once via `/sap-gui-probe --record`; `.screens.json` baseline |

---

## 2. `/sap-run-report` — full implementation

### 2.1 Frontmatter
```yaml
name: sap-run-report
description: |
  Executes an ABAP report/program on a live SAP system — foreground or background,
  with or without a variant — and captures the output. Default engine is a background
  job (dump-safe, spool captured via /sap-sp02); --foreground drives SA38 F8 for an
  interactive list. Also maintains variants (list/show/set/delete). Mode-aware: prefers
  the RFC fast-path (Z_RUN_REPORT + RS_VARIANT_* via the wrapper) and falls through to
  GUI (SA38 F8 / Execute-in-Background F9) when RFC is unavailable. Executing a report
  can change data — the skill ALWAYS confirms before running.
  Prerequisites: active SAP GUI session (/sap-login). RFC path needs NCo 3.1 (32-bit)
  + Z_RUN_REPORT / Z_GENERIC_RFC_WRAPPER_TBL (deploy via /sap-dev-init).
argument-hint: "<PROGRAM> [--variant=V] [--foreground|--background] [--values=\"P_A=1;S_B=BT:10,20\"] [--save-output=PATH]   |   variant <list|show|set|delete> <PROGRAM> [VAR] [--values=\"...\"]"
```

### 2.2 Args & modes (lean: one default action + one sub-command)
| Invocation | Mode |
|---|---|
| `/sap-run-report ZFOO …` | **run** (default; no keyword) |
| `/sap-run-report variant <list\|show\|set\|delete> ZFOO [VAR]` | **variant** maintenance |

`run` switches: `--foreground` / `--background` (default per D3), `--variant=V`,
`--values="…"` (orthogonal input source to `--variant`), `--save-output=PATH`,
`--session=…`, `--timeout=<sec>` (background poll cap, default 300).

### 2.3 Mode-dispatch table (the spine)
Resolved in Step 1 from `sap_dev_mode` + an RFC-availability probe. RFC failure at
runtime **degrades, never blocks** (same as `sap-se38` Step 4.6/4.7).

| Operation | Preferred (RFC) | GUI fallback | Fallback quality |
|---|---|---|---|
| run foreground | — (GUI-native) | `sap_sa38_run.vbs` F8 (+ Get-Variant / fill `--values`) | only path anyway |
| run background | `Z_RUN_REPORT` → poll `TBTCO` → spool `TBTCP` | `sap_sa38_run.vbs` F9 (Execute in Background) → poll via SM37/`/sap-job` | ✅ SA38/SM37 static |
| variant list/show/delete | `RS_VARIANT_*` | SE38/SA38 → Goto·Variants | 🟡 workable |
| variant set/create | `RS_CREATE/CHANGE_VARIANT` | dynamic selection screen | ⚠️ hard → degrade (D6) |

### 2.4 File tree
```
skills/sap-run-report/
  SKILL.md
  README.md
  references/
    sap_sa38_run.vbs            # FG (F8) + BG (F9) driver; %%MODE%% token
    sap_sa38_run.screens.json   # golden-screen baseline
    sap_variant_rfc.ps1         # (planned only — never built; variant set went GUI via sap_sa38_variant.vbs, see §1.2/§3.4)
    sap_run_report_rfc.ps1      # Phase B: calls Z_RUN_REPORT + TBTCO/TBTCP poll
```

### 2.5 SKILL.md step-by-step

**Step 0 — Resolve Work Directory.** Standard env-aware one-liner (`Get-SapWorkDir` +
`Get-SapRunTemp`); `{RUN_TEMP}` for all generated scratch, `{WORK_TEMP}` only for
`Get-SapCurrentSessionPath -WorkTemp`. (Copy from `sap-run-abap-unit` Step 0.)

**Step 0.5 — Start Logging.** `sap_log_helper.ps1 -Action start -StateFile
{RUN_TEMP}\sap_run_report_run.json -Skill sap-run-report -ParamsJson
{"program":"<P>","mode":"<run|variant>","engine":"<fg|bg>"}`.

**Step 1 — Parse args + resolve mode + resolve backend.**
- Parse per §2.2. UPPERCASE program/variant.
- Backend resolution: read `sap_dev_mode`. If `GUI` → GUI branch only. Else probe RFC
  (best-effort `sap-dev-status` or catch first RFC error) → set `BACKEND=RFC|GUI`.
- Log `mode`/`engine`/`backend`.

**Step 2 — Ensure session.** GUI branch needs an active GUI session (`/sap-login`).
RFC branch needs NCo + pinned profile; on missing wrapper/`Z_RUN_REPORT` → degrade to GUI.

**Step 2.5 — CONFIRM-TO-RUN gate (MANDATORY, new risk class).**
- Applies to every **run** (not to variant list/show). The skill cannot know whether the
  report writes (UPDATE / COMMITting BAPI / job submit / IDoc / mail).
- Show: program, resolved engine (fg/bg), variant or `--values`, target SID/client.
- Require explicit go-ahead. **No silent execution.** Record the confirmation as a log step.
- Governed by the new rule in `skill_operating_rules.md` (§2.8).

**Step 3 — Execute (dispatch).**

*3A — Foreground GUI* (`--foreground`, or any run in `sap_dev_mode=GUI`): generate
`sap_sa38_run.vbs` with `%%MODE%%=FG`. Fill `ctxtRS38M-PROGRAMM`, F8 to the selection
screen; if `--variant` → load it via the selection screen's **Get Variant** (Shift+F5 →
pick from the variant ALV); else fill `--values` onto the live fields; F8 to execute.
Capture a classic list via **System·List·Save·Local File** → `--save-output`
(ALV/interactive lists = best-effort; note in report). Wrap file-IO with the SAP GUI
Security sidecar (as `/sap-sp02` Step 3 does).

*3B — Background RFC* (default engine, `BACKEND=RFC`): run `sap_run_report_rfc.ps1`
(32-bit PS) → calls `Z_RUN_REPORT` (IV_PROGRAM/IV_VARIANT). Get `EV_JOBNAME`/`EV_JOBCOUNT`.

*3C — Background GUI fallback* (`BACKEND=GUI`, background engine): `sap_sa38_run.vbs`
with `%%MODE%%=BG` — F8 → (load variant) → **Program·Execute in Background (F9)** →
print-params popup (Enter) → start **Immediate** → read scheduled job name from the
status bar (`MessageType=S`). Monitoring then delegates to SM37 / `/sap-job`.

*3V — Variant sub-command:* RFC → `sap_variant_rfc.ps1` (`list`/`show`/`set`/`delete`).
GUI fallback: list/show/delete via Goto·Variants; **set/create degrades per D6** — offer
foreground `--values` instead, or emit
`VARIANT: NEEDS_RFC program=<P> variant=<V> (save needs RFC or manual SE38→Variants)`.

**Step 4 — Poll + capture (background only).**
- Poll `TBTCO` (`RFC_READ_TABLE`, read-only) on `JOBNAME`+`JOBCOUNT` until `STATUS ∈ {F,A}`
  or `--timeout`. `F`=finished, `A`=aborted, `R/Y/P/S`=running/ready/scheduled/released.
- On `F`: read `TBTCP.LISTIDENT` (spool id). If present → `/sap-sp02 <LISTIDENT>
  <save-output>` to capture output.
- On `A`: read `BP_JOBLOG_READ` and/or `/sap-st22` (deep) for the dump → `RUN_REPORT: DUMP`.
- Pure-GUI (no RFC reads): poll via SM37 GUI or degrade to `SUBMITTED` + point to `/sap-job`.

**Step 5 — Parse result + verdict.**
```
RUN_REPORT: SUBMITTED job=<name> count=<n>                          # async, not yet waited
RUN_REPORT: COMPLETED job=<name> status=F spool=<id> out=<path>
RUN_REPORT: DUMP      job=<name> st22=<id> <short>                  # → FAIL
RUN_REPORT: EXECUTED_FG list_saved=<path|NONE>
VARIANT: <SET|SHOWN|DELETED|NEEDS_RFC> program=<P> variant=<V>
ERROR: <...>
```
Verdict: `RUN_VERDICT: OK | DUMP | ERROR`. `DUMP`/`ERROR` → non-zero exit.

**Step 5b — Register artifact** (best-effort, try/catch, never changes verdict). Kind
`run_output`; register `--save-output` + verdict for `/sap-evidence-pack` (pattern from
`sap-run-abap-unit` Step 4b).

**Step 6 — Report.** Program, engine, variant/values, job name/count, spool id + output
path (+ size), verdict; on DUMP lead with the ST22 id + top error line.

**Final — Log End.**
| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Ran clean | `SUCCESS / 0` |
| Runtime dump | `FAILED / 1 / RUN_DUMP` |
| Submit/close failed | `FAILED / 1 / RUN_SUBMIT_FAILED` |
| GUI parse unresolved | `FAILED / 2 / RUN_GUI_PARSE_FAILED` (emit `NEEDS_RECORDING`, never false-green) |
| Variant save needs RFC | `SKIPPED / 0 / RUN_VARIANT_NEEDS_RFC` |

Add the new classes to `shared/rules/error_classes.md` in the same commit.

### 2.6 Reference scripts — contracts
- **`sap_sa38_run.vbs`** — tokens `%%PROGRAM%% %%VARIANT%% %%VALUES%% %%MODE%%(FG|BG)
  %%SAVE_PATH%% %%SESSION_PATH%% %%ATTACH_LIB_VBS%%`. Declares `Const SESSION_PATH`,
  includes `sap_attach_lib.vbs`, calls `AttachSapSession` (Tier-3). Confident ID:
  `wnd[0]/usr/ctxtRS38M-PROGRAMM`. Get-Variant popup + F9 print/start popups + list-save
  menu path: **capture via `/sap-gui-probe --record`** and seed `.screens.json`.
  Language-independent (VKey, `MessageType`, DDIC ids — no `.Text` branching).
- **`sap_variant_rfc.ps1`** — args `-Action list|show|set|delete -Program -Variant
  [-ValuesFile]`. To **set**, first obtain the report's field list (read an existing
  variant via `RS_VARIANT_CONTENTS`, or the selection metadata) then map `--values` →
  `RSPARAMS` rows before `RS_CREATE_VARIANT`/`RS_CHANGE_VARIANT_ALL_TYPES`. asXML shapes
  per `sap-rfc-wrapper` F4. Stdout: `VARIANT: … STATUS: OK|NOT_FOUND|RFC_ERROR`.
- **`sap_run_report_rfc.ps1`** (Phase B) — args `-Program -Variant -Timeout`. Calls
  `Z_RUN_REPORT` (direct RFC), then `TBTCO` poll + `TBTCP` spool read. Stdout: the
  `RUN_REPORT:` lines. 32-bit PS, dot-sources `sap_rfc_lib.ps1`.

### 2.7 Safety rule (append to `shared/rules/skill_operating_rules.md`)
> **Report execution.** A skill that runs an ABAP report (`/sap-run-report`, `/sap-job
> schedule`) MUST obtain explicit user confirmation before execution — the skill cannot
> know whether the report mutates data. Prefer a known-safe variant; prefer
> background+spool so side effects are captured, not guessed. Never auto-run on deploy or
> as an unconfirmed side effect. Job cancel/delete are destructive → confirm.

### 2.8 Release robustness
`.screens.json` baseline for `sap_sa38_run.vbs`; unrecognized layout → `NEEDS_RECORDING`
(never a false "ran"). Auto-record runtime dumps to `frequently_errors` (best-effort),
like the deploy skills.

---

## 3. `/sap-job` — full implementation (✅ BUILT 2026-07-09)

### 3.1 Modes
```
/sap-job schedule <PROGRAM> --variant=V [--start=immediate|"YYYYMMDDHHMMSS"|event:<EVT>] [--period=daily|weekly|monthly]
/sap-job list   [--user=U] [--from=DATE] [--to=DATE] [--status=R|Y|P|S|F|A]
/sap-job status <JOBNAME> <JOBCOUNT>
/sap-job log    <JOBNAME> <JOBCOUNT>
/sap-job spool  <JOBNAME> <JOBCOUNT>          # → /sap-sp02
/sap-job cancel <JOBNAME> <JOBCOUNT>          # BP_JOB_ABORT  (destructive → confirm)
/sap-job delete <JOBNAME> <JOBCOUNT>          # BP_JOB_DELETE (destructive → confirm)
```

### 3.2 Dispatch (RFC preferred → GUI SM36/SM37; both static → clean fallback)
| Operation | RFC | GUI fallback |
|---|---|---|
| schedule | `Z_RUN_REPORT` (+ start-cond args) | **SM36**: job name → Step (program+variant) → Start condition → Save |
| list | `RFC_READ_TABLE` `TBTCO` (or `BP_JOB_SELECT`) | **SM37** list scan |
| status | `TBTCO` read | SM37 |
| log | `BP_JOBLOG_READ` | SM37 → Job log |
| spool | `TBTCP.LISTIDENT` → `/sap-sp02` | SM37 → Spool |
| cancel/delete | `BP_JOB_ABORT` / `BP_JOB_DELETE` | SM37 (confirm) |

> SM36/SM37 are static transactions → pre-recordable control IDs (unlike variant editing).
> So `/sap-job` degrades to GUI cleanly with zero RFC. Capture IDs via `/sap-gui-probe --record`.

### 3.3 SKILL.md skeleton
Same shape as §2.5. Reads (list/status/log/spool) are safe, no confirm. `schedule`
(writes a recurring job on a shared system) and `cancel/delete` require the confirm gate.
Result lines: `JOB: SCHEDULED|LISTED n=<k>|STATUS <s>|LOG lines=<k>|CANCELLED|DELETED`;
verdict `JOB_VERDICT: OK|ERROR`. Error classes `JOB_SCHEDULE_FAILED`, `JOB_NOT_FOUND`,
`JOB_CANCEL_FAILED`.

### 3.4 Files & shared-code promotion
```
skills/sap-job/{SKILL.md,README.md,references/{sap_sm36_schedule.vbs,sap_sm37_ops.vbs,*.screens.json,sap_job_rfc.ps1}}
```
**As built (2026-07-09):** all six files created; `./skills/sap-job` registered in
`marketplace.json` (total_skills 68→69 at build time; 70 as of the 2026-07-09 build with `/sap-file-transfer`).

Two planned promotions were **re-scoped** against how Phase A/B actually shipped:
- **`sap_variant_rfc.ps1` → `shared/scripts/sap_variant_lib.ps1`: N/A.** That dedicated
  RFC variant script was never built — variant *set* went the GUI route
  (`sap_sa38_variant.vbs`) and *list/show/delete* route through `/sap-rfc-wrapper`
  (design §1.2). There is no single-file variant lib to promote, and `/sap-job` needs no
  variant maintenance of its own, so nothing was moved. If an RFC `RS_CREATE_VARIANT`
  fast-path is built later, `shared/scripts/sap_variant_lib.ps1` remains its intended home.
- **`Z_RUN_REPORT` sharing: by reference, not by file move.** The FM is deployed once by
  `/sap-dev-init` and lives in the SAP system; `/sap-job schedule` calls it *by name* over
  RFC (`sap_job_rfc.ps1`), exactly as `/sap-run-report` does (`sap_run_report_rfc.ps1`).
  The `.abap` source stays in `sap-run-report/references/` and is already registered in
  `sap_dev_artefacts.ps1` §7c + dev-init Step 8c — no second copy, no CLAUDE.md shared-file
  row needed (`sap_job_rfc.ps1` is a single-consumer skill-private script, so it lives in
  `sap-job/references/`, not `shared/`).

---

## 4. Build phasing & registration checklist

**Phase A — `/sap-run-report`, GUI-only. ✅ BUILT 2026-07-09.** SA38 foreground (F8 +
Get-Variant/`--values` + best-effort `%PC` list capture) + GUI background schedule +
variant list/show/delete via `/sap-rfc-wrapper` (dedicated `sap_variant_rfc.ps1` deferred
to Phase B with variant *set*); confirm gate (Step 2.5); safety rule (Rule 5); error
classes; `sap_sa38_run.vbs` + `.screens.json` (seed, `pending_live`); marketplace registered
(68 skills at that build checkpoint; 70 as of the 2026-07-09 build). Consistency gate: **clean** (Tier-3 attach OK, baseline counted). Ships the
daily dev-loop value as **+1 skill**. Remaining: `/sap-gui-probe --record` the Get-Variant /
background-exec / `%PC` popups on the target release to flip the baseline to `captured`.

**Phase B — `/sap-run-report`, RFC background. ✅ BUILT 2026-07-09.** `Z_RUN_REPORT`
(RFC-enabled FM — JOB_OPEN → SUBMIT VIA JOB → JOB_CLOSE, with a TRDIR program-exists guard +
default `GET_PRINT_PARAMETERS` spool params; `references/Z_RUN_REPORT.abap`) deployed via
`/sap-dev-init` **Step 8c** (best-effort RFC insert, Remote-Enabled) and registered in
`sap_dev_artefacts.ps1` **§7c** + the dev-init orphan-lock hygiene list (dev-status/dev-clean
see it). `sap_run_report_rfc.ps1` (submit → `TBTCO` poll → `TBTCP` spool id) wired into
SKILL.md **Step 3B** (preferred) with GUI Execute-in-Background as **Step 3C** fallback; Step 4
delegates spool capture to `/sap-sp02` and abort-detail to `/sap-st22`. Verified live on S4G
(S/4HANA) 2026-07-09: a WRITE report submitted → polled to `status=F` → spool `351933`
(TSP01-confirmed, owner KM717). Variant **set** stays GUI (Phase A, decision #4). Still one
skill. Deferred: flip the *default* engine foreground→background per D3 (a behavior change —
kept opt-in via `--background` for now); optional RFC `RS_CREATE_VARIANT` fast-path.

**Phase C — `/sap-job`. ✅ BUILT 2026-07-09.** Seven modes (`schedule` / `list` / `status`
/ `log` / `spool` / `cancel` / `delete`) on the same RFC-preferred → GUI-fallback spine as
`/sap-run-report`. RFC backend `sap_job_rfc.ps1` (32-bit PS) reuses the Phase-B mechanism:
`schedule`(immediate) → `Z_RUN_REPORT`; `list`/`status` → `TBTCO`; `spool` → `TBTCP.LISTIDENT`
→ `/sap-sp02`; `delete` → `BP_JOB_DELETE` (best-effort over direct RFC → SM37 degrade).
`log`/`cancel` are GUI-primary (job-log TemSe read / running-job abort need SM37), and
start-time/periodic scheduling routes to the SM36 wizard. GUI drivers `sap_sm36_schedule.vbs`
+ `sap_sm37_ops.vbs` carry **live-captured** SM36/SM37 control IDs (S4G S/4HANA EN + EC2 ECC
7.31 JA, 2026-07-09 — identical across both; core `SAPLBTCH`/`SAPMSSY0` kernel dialogs). SM37
`list`/`log` (classic list `SAPMSSY0/120`; row = a `GuiLabel` selected via `setFocus`, ops
`tbar[1]/btn[47]`=Job log / `btn[44]`=Spool / Job-menu `menu[0]/menu[1]`=cancel `menu[0]/menu[9]`=delete)
and the full SM36 immediate wizard (`1140` initial → `1120` step → step-list Back → `1010`
start-cond → save) were verified live end-to-end; `.screens.json` baselines flipped to
`captured`. Two seed bugs fixed on capture: SM37 job/user fields are `txt` not `ctxt`, and
DefineStep must Back out of the step-list overview to the initial screen. Confirm gate (Rule 5)
covers `schedule` + `cancel` + `delete`; the `JOB_*` error classes were pre-seeded in Phase B.
Variant-lib promotion re-scoped (see §3.4); `Z_RUN_REPORT` shared by reference, not copied.
Consistency gate: clean. **All GUI write paths verified 2026-07-09** on BOTH S4G (S/4HANA EN,
RFC-verified) and EC2 (ECC 7.31 JA, SM37-GUI-verified):
- `schedule` — immediate, date-time, and periodic (daily/weekly), S4G `TBTCS`-confirmed
  (`PERIODIC=X` + `PRDDAYS`/`PRDWEEKS`); `--period` w/o `--start` anchors at now (VBScript `Date`/`Time`).
- `delete` — SM37 **Shift+F2 (sendVKey 14)**, NOT the Job-menu index (Delete = menu[0]/menu[9] on
  S/4HANA but menu[0]/menu[2] on ECC 7.31 — the live round-trip caught this); self-verifies the
  job left the list before reporting.
- `cancel` — a running WAIT job (throwaway `ZZJOBWAIT`) aborted → RFC-confirmed status `A` on S4G;
  resolved by **localized-text menu match** ('Cancel active job' / `有効ジョブ中止`, `ChrW`) not the
  release-dependent index, live-confirmed on both; self-verifies via an Active-only re-query.

The live testing caught **five** real bugs total: the two from the delete round-trip (RFC
`-User "*"` → `SDLUNAME EQ '*'` no-match, now treated as no-filter; classic-list ops targeting
the header selection-echo not the data row, now column-filtered) plus the SM37 default-date-window
gap (row-ops now widen the window so future/past-dated jobs are found), the SM36 `--period`-without-
`--start` anchor, and the release-dependent Delete-menu index. **Only step not run literally on
EC2:** aborting a live job there (needs a flaky ECC clipboard-paste fixture deploy) — the mechanism
is identical and every component is EC2-verified.

**Registration checklist (per new skill):**
- [ ] `skills/<skill>/SKILL.md`
- [ ] entry in `sap-dev/.claude-plugin/marketplace.json`
- [ ] `references/*.screens.json` baseline for every driving VBS (CI coverage gate)
- [ ] Tier-3 attach tokens in every VBS (CI `check-consistency.mjs`)
- [ ] `{RUN_TEMP}` for all generated scratch (run-temp hook)
- [ ] new `error_class` values in `shared/rules/error_classes.md`
- [ ] Step 0.5 / Final logging blocks
- [ ] naming pre-check row if it writes objects (n/a here)
- [ ] `Z_RUN_REPORT` registered in `sap_dev_artefacts.ps1` + `sap-dev-status` (Phase B)
- [ ] test report → `sap-dev/temp/testReport/<name>_<YYYYMMDD>.md`

---

## 5. Open decisions to confirm
1. **D3** — background default vs foreground default. STILL OPEN / DEFERRED (see §4 Phase B):
   shipped with foreground default, background opt-in via `--background`; the flip to
   background-default is a deliberate deferred behavior change.
2. **D5** — ✅ RESOLVED (2026-07-09): `Z_RUN_REPORT` built and deployed in Phase B
   (see §4 Phase B; `references/Z_RUN_REPORT.abap`, dev-init Step 8c).
3. **D2** — ✅ RESOLVED (2026-07-09): shipped as `/sap-run-report` (see §4 Phase A).
4. Variant **set** — ✅ RESOLVED (2026-07-09): implemented via GUI Save-as-Variant with
   heuristic `--values` fill (`sap_sa38_variant.vbs`, verified S4D create/overwrite/delete).
   An RFC SELNAME-based `RS_CREATE_VARIANT` fast-path remains a future option.
