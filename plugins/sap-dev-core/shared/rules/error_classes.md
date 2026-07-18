# error_class taxonomy — the machine-readable failure vocabulary

Every `end` log record with `status=FAILED` SHOULD carry an `error_class` from
this file. The class is what log consumers key on — `/sap-log-analyze`'s
"Top error_class" section, customer alerting/dashboards parsing the JSONL
stream, and the frequently_errors auto-record attribution. Free-text
`error_msg` is for humans; `error_class` is the stable enum.

Contract:

- **Format**: `UPPER_SNAKE_CASE`, ASCII, no spaces. Prefix with the owning
  family where one exists (`ATC_`, `AUNIT_`, `CC_`, `STMS_`, `FIX_INCIDENT_`,
  `REVIEW_`) so dashboards can group by prefix.
- **Stability**: once shipped, a class is never renamed (dashboards break);
  add a new class and stop emitting the old one instead.
- **Extending**: pick from this file first. If no class fits, add the new row
  HERE in the same commit that starts emitting it — this file is the single
  source of truth (`plugins/sap-dev-core/shared/rules/error_classes.md`).
- **Emission**: PowerShell — `Stop-SapLog … -ErrorClass <CLASS>` /
  `sap_log_helper.ps1 -Action end … -ErrorClass <CLASS>`. VBS — pass the
  class token at the start of the `errorMsg` argument to `LogEnd` when no
  dedicated parameter exists.

## Generic infrastructure classes (any skill)

| Class | Emitted by | Meaning |
|---|---|---|
| `RFC_LOGON_FAILED` | any RFC-using skill (today: sap-enhancement-advisor, sap-impact-analysis, sap-transport-readiness, RFC preflights) | NCo connect/logon to the pinned profile failed (bad creds, unreachable endpoint, NCo missing). |
| `RFC_ERROR` | any RFC-using skill (today: sap-api-advisor, sap-auth-requirements, sap-config-compare, sap-gateway-service, sap-release-notes, sap-sm12, sap-sost, sap-version-history, sap-workflow) | An RFC read / FM call failed AFTER a successful connect (call-level raise, mid-run network drop, unreadable table) — the post-logon sibling of `RFC_LOGON_FAILED`. |
| `TR_RESOLUTION_FAILED` | deploy skills' Step 1b (`/sap-transport-request` delegation) | No modifiable transport request could be resolved under the active `way_to_get_transport_request` policy. |
| `TR_NOT_MODIFIABLE` | reserved (canonical name; use for a supplied TR that exists but is released/foreign) | The named TR cannot take new objects. |
| `TR_UNVERIFIED` | /sap-transport-request (Steps 1b/4) + deploy skills' Step 1b delegation | Candidate TR status could not be verified (`Z_GENERIC_RFC_WRAPPER_TBL` missing or a transient RFC error) — status UNKNOWN, nothing created; the caller re-prompts per the policy loop, never treats it as not-found. |
| `TR_NOT_FOUND` | sap-transport-readiness | The named transport request does not exist at all (E070 probe empty) — distinct from `TR_NOT_MODIFIABLE` (exists but cannot take objects). |
| `GUI_TIMEOUT` | reserved (canonical name for GUI-scripting stalls) | A GUI-scripting wait loop exhausted its budget (screen never arrived, modal never closed). |
| `GUI_LAYOUT_UNKNOWN` | sap-se14 (canonical name for future reuse) | A driven screen/popup matched no known layout variant mid-flow — the run stops rather than guess-click. Distinct from `GUI_TIMEOUT` (a stall) and from `NEEDS_RECORDING` (a whole leg that ships unrecorded). |
| `NO_SESSION` | sap-file-transfer, sap-gui-probe, sap-gui-skill-scaffold, sap-user-guide | No active authenticated SAP GUI session (login-status probe returned non-`LOGGED_IN`) — run `/sap-login` first. |
| `NO_PIN` | sap-gui-probe, sap-gui-skill-scaffold | Multiple SAP GUI connections are attached and no AI-session pin selects one — refused loud rather than guessing a connection; run `/sap-login` to pin. |
| `SAFETY_PROD_REFUSED` | every write-capable skill's Rule 0 gate (`sap_safety_gate.ps1 -Action assert`) | The pinned connection is `PRD` and `prod_write_policy=BLOCK` (default) or `prod_access=NONE` — the run stops before any SAP-mutating step; **no override flag exists** (safety_policy.md 0.2/0.3). |
| `SAFETY_UNCLASSIFIED_REFUSED` | every write-capable skill's Rule 0 gate | No connection profile resolves, the profile has no `system_name`, or its `environment` is blank/unknown — fail closed, treated as `PRD` (safety_policy.md 0.1). Remediation: `/sap-login` (re-)classification. |
| `SAFETY_CONFIRM_MISMATCH` | every write-capable skill's Rule 0 gate (`prod_write_policy=TYPED_CONFIRM` only) | The operator's typed confirmation did not match the expected `PROD <SID>/<CLIENT>` token verbatim — refused, nothing ran. |
| `USER_ABORTED` | sap-gui-probe, sap-user-guide | The operator aborted the interactive run mid-flight — recorded as the end cause, never dressed up as a skill defect. |
| `OBJECT_NOT_FOUND` | sap-explain-object, sap-impact-analysis, sap-review-abap | The named repository object does not resolve on the target system (TADIR/TFDIR probe empty). |
| `OBJECT_NAMING_VIOLATION` | deploy skills' naming gate (sap-se11, sap-se24, sap-se37, sap-se38) + sap-gen-cds, sap-gen-rap | The object name fails the `sap_object_naming_rules.tsv` validator (`sap_check_object_name.ps1` exit 1) and the user chose Abort — run ends `SKIPPED`, nothing deployed. |
| `SCREEN_DRIFT` | sap-doctor (`--screens`) | A golden-screen baseline checkpoint no longer matches the live screen (release/locale moved a control). |
| `BLOCKED` | sap-workflow | A backend preflight found the required access layer unavailable (RFC down → `STATUS: BLOCKED`) — the whole mode stops before any read, no silent GUI degrade. |
| `SE38_CHECK_FAILED` | sap-se38 | Program existence/syntax pre-check failed before deploy. |

## Scratch run & FM probe (`/sap-scratch-run`)

| Class | Meaning |
|---|---|
| `SCRATCH_GUARD_VIOLATION` | The generated `$TMP` report hit the read-only static guard (a write / COMMIT / CALL TRANSACTION / SUBMIT / dynamic-write / dataset / lock construct) — a hard REFUSE; nothing was deployed. |
| `SCRATCH_SYNTAX_ERROR` | The headless `EDITOR_SYNTAX_CHECK` (`sap_rfc_syntax_check.ps1`) found errors in the generated source — regenerate-or-abort, never deployed broken. |
| `SCRATCH_CLEANUP_FAILED` | The `$TMP` scratch program survived the post-run delete (TRDIR re-read still finds it) — reported loud with its exact name, never a silent success. |
| `SCRATCH_ENV_REFUSED` | `run`/`instrument` deploy was requested on a non-modifiable or production client — refused before any deploy. |
| `FM_PROBE_WRAPPER_FAILED` | `fm` on a classic (blank-FMODE) FM needs `Z_GENERIC_RFC_WRAPPER_TBL`, which is absent/not remote — routes to `/sap-dev-init` (or delegate `/sap-rfc-wrapper`). |

## SQL query (`/sap-sql-query`)

| Class | Meaning |
|---|---|
| `SQLQ_PARSE_REJECTED` | The whitelist parser rejected the SELECT — the exact rule + token are reported (subquery / UNION / INTO / write / MANDT / `;` / comment / host-var / caller UP TO / …). Nothing ran. |
| `SQLQ_NAME_UNKNOWN` | A referenced table/field did not resolve against live DDIC (DD02L/DD03L) — no guessed names. |
| `SQLQ_AUTH_REFUSED` | Engine A's in-FM `VIEW_AUTHORITY_CHECK` denied a referenced table (`E_STATUS='A'`) — zero rows, closes the "Open SQL bypasses S_TABU_DIS" hole. |
| `SQLQ_HELPER_MISSING` | `Z_SQL_QUERY_RO` is absent / not remote-enabled — offer `install` (consent-gated) or `--low-fidelity` (Engine B). |
| `SQLQ_EXEC_FAILED` | Engine A raised a dynamic-OSQL / DB error (`E_STATUS='E'`) — the verbatim message is surfaced, no partial result claimed. |
| `SQLQ_LOWFI_UNSUPPORTED` | Engine B (LOW-FIDELITY) was asked for a join / aggregate / grouping it does not do — refused loud with a pointer to `install` Engine A, never a silent wrong answer. |

## ATC quality gate (`/sap-atc`)

| Class | Meaning |
|---|---|
| `ATC_EMPTY_SCOPE` | Object set resolved to zero objects (typo'd name / wrong type) — run refused rather than PASSing on nothing. |
| `ATC_OBJ_SET_FAILED` | SCI object-set creation failed. |
| `ATC_RUN_SCHEDULE_FAILED` | Run series creation/schedule failed. |
| `ATC_POLL_TIMEOUT` | Run monitor never reached COMPLETED within the poll budget. |
| `ATC_PLAN_ERRORS` | Run completed with plan/tool errors (`COUNT_PLNERR` > 0) — findings unreliable. |
| `ATC_RESULT_PARSE_FAILED` | Priority columns unreadable on this release — gate refuses (never falls back to 0/0/0). |
| `ATC_GATE_FAIL` | Findings at/below `MAX_PRIORITY` threshold — deploy blocked (the gate working as intended). |
| `ATC_BASELINE_NOT_SUPPORTED` | `baseline record` / `exemptions` / `--use-baseline` requested on a system with SAP_BASIS < 7.51 (the SATC baseline infrastructure is absent) — the baseline mode refuses and the normal gate runs unchanged. Release-gated live: S/4HANA 1909 = SAP_BASIS 754 (supported, `SATC_CI_EXEMPT` present); ECC 6 = 731 (not supported). |

## ABAP Unit (`/sap-run-abap-unit`, `/sap-gen-abap-unit`)

| Class | Meaning |
|---|---|
| `AUNIT_OBJECT_MISSING` | Target program/class not found. |
| `AUNIT_TESTS_FAILED` | Suite ran; at least one method red. |
| `AUNIT_GUI_PARSE_FAILED` | Result display could not be parsed on this release (see NEEDS_RECORDING flow). |
| `AUNIT_COVERAGE_UNVERIFIED` | Tests green but the coverage pass could not be read. |
| `AUNIT_GEN_SOURCE_UNAVAILABLE` | Test generation: object source unreadable over RFC. |
| `AUNIT_GEN_NO_SEAM` | Test generation: no testable seam found (object needs refactoring for testability). |
| `AUNIT_GEN_NOT_GREEN` | Generated tests do not pass yet at hand-off. |

## Report execution (`/sap-run-report`, `/sap-job`)

| Class | Meaning |
|---|---|
| `RUN_DUMP` | The executed report short-dumped (background job ended ABORTED, or a foreground run raised a runtime error) — drill via the linked ST22 id. |
| `RUN_SUBMIT_FAILED` | Job submit/schedule failed (`Z_RUN_REPORT` JOB_OPEN/SUBMIT/CLOSE non-zero, or SA38 Execute-in-Background created no job). |
| `RUN_GUI_PARSE_FAILED` | The SA38 run / selection / save screen could not be driven on this release (NEEDS_RECORDING) — never reported as a successful run. |
| `RUN_VARIANT_NEEDS_RFC` | A variant create/edit was requested but RFC is unavailable; GUI variant persistence needs the report's dynamic selection screen — degraded, not run. |
| `RUN_TIMEOUT` | Background poll exceeded `--timeout` before the job reached a final state. |
| `JOB_SCHEDULE_FAILED` | `/sap-job schedule` could not create the scheduled job. |
| `JOB_NOT_FOUND` | `/sap-job status\|log\|spool\|cancel\|delete` — the named (jobname, jobcount) is not in `TBTCO`. |
| `JOB_CANCEL_FAILED` | `BP_JOB_ABORT` / `BP_JOB_DELETE` (or the SM37 GUI fallback) failed. |

## Custom-code migration (`sap-migrate`, `CC_*`)

| Class | Meaning |
|---|---|
| `CC_CAMPAIGN_BAD_INPUT` / `CC_ANALYZE_BAD_INPUT` / `CC_TRIAGE_BAD_INPUT` / `CC_REMEDIATE_BAD_INPUT` / `CC_USAGE_BAD_INPUT` / `CC_LEARN_BAD_INPUT` / `CC_DECOMMISSION_BAD_INPUT` | Phase helper rejected its inputs (missing workspace / malformed file). |
| `CC_CAMPAIGN_GAP` | Campaign ledger empty or inconsistent (exit-1 gap from the aggregator). |
| `CC_INVENTORY_RFC` | Inventory RFC read failed. |
| `CC_INVENTORY_PARTIAL` | Inventory completed only partially — fail-loud instead of a silently short object list. |
| `CC_INVENTORY_EMPTY` / `CC_ANALYZE_EMPTY` / `CC_REMEDIATE_EMPTY` / `CC_TRIAGE_NO_FINDINGS` / `CC_LEARN_NO_FINDINGS` / `CC_USAGE_NO_INVENTORY` / `CC_DECOMMISSION_EMPTY` | Phase ran but had nothing to do — surfaced as a distinct class so "empty" is never mistaken for "done". |
| `CC_DECOMMISSION_GATE_BLOCKED` | `/sap-cc-decommission plan` refused because `decommission_signoff` is not APPROVED (exit 3) — a physical retirement can never run unsigned. |
| `CC_REMEDIATE_GATE_BLOCKED` | `/sap-cc-remediate record` held progress at a gate (exit 3): `dryrun_review` not APPROVED, or the ABAP-Unit gate held ≥1 object back from VERIFIED under `unit_gate=BLOCK`. |
| `CC_NOT_S4` | `/sap-cc-cloud-readiness` refused a non-S/4 pinned profile (cloud distance applies only to S/4; ECC/EC2 is pointed to `/sap-cc-analyze`). Never probes or scans. |
| `CC_SCOPE_EMPTY` | `/sap-cc-cloud-readiness scan` resolved an empty scope (no `decision=REMEDIATE` rows / empty `--objects`) — surfaced so "nothing to scan" is never rendered a clean result. |
| `CC_KP_MISSING` | The cloud knowledge pack (`forbidden_statements.tsv` / `cloudification_repository.json`) could not be resolved under `{custom_url}\knowledge\cloud\` or the shipped pack. |
| `CC_SOURCE_READ_FAILED` | Every **scannable** object in the scope was unreadable over RFC (infra error) — a partial failure instead stays per-object `COULD_NOT_CHECK` and the run continues. |
| `CC_SCAN_BAD_INPUT` | The cloud download/scan helper rejected its inputs (missing scope/source dir, malformed coverage file). |

## SPAU/SPDD triage (`/sap-spau-triage`)

| Class | Meaning |
|---|---|
| `SPAU_WORKLIST_READ_FAILED` | The SMODILOG modification-log page failed mid-scan — no partial worklist TSV is registered (never a truncated list presented as complete). |
| `SPAU_VERSION_READ_FAILED` | An `SVRS_*` version-directory / source call raised on a requested `--deep`/`inspect` entry — that entry degrades to `coverage=COULD_NOT_CHECK`, the scan still completes. |

## Function-exit modernization (`/sap-exit-modernize`)

| Class | Meaning |
|---|---|
| `EXIT_RESOLVE_FAILED` | The input does not resolve to a function exit — not an `EXIT_*` FM, or MODSAP has no `TYP='E'` row for it. |
| `EXIT_NO_SAFE_TARGET` | /sap-enhancement-advisor found no released enhancement interface / new BAdI / classic BAdI — only implicit points or standard modification remain; translate/deploy refuse. |
| `EXIT_TRANSLATE_BLOCKED` | translate was invoked after an `EXIT_NO_SAFE_TARGET` analyze verdict — nothing is generated. |
| `EXIT_SCOPE_UNSUPPORTED` | The component is a screen (`S`) / table (`C_*`) / menu exit — out of the function-exit v1 scope, refused loud (v2). |

## Delivery assurance & quality skills

| Class | Emitted by | Meaning |
|---|---|---|
| `REVIEW_SOURCE_UNAVAILABLE` | sap-review-abap | Object source unreadable over RFC. |
| `REVIEW_GATE_BLOCKED` | sap-review-abap | Review findings breach the customer-brief gate. |
| `CONTEXT_NOT_FOUND` | sap-enhancement-advisor | Requested enhancement context (spot/BAdI/exit) does not exist on the system. |
| `DEV_STATUS_GAPS` | sap-dev-status | One or more dev-init artefacts missing (exit-1 gap report). |
| `DIAGNOSE_NO_EVIDENCE` | sap-diagnose | No reader produced evidence for the incident window. |
| `DOCTOR_BLOCKED` | sap-doctor | A blocking environment check failed (GUI scripting / NCo / work_dir). |
| `ERROR_KB_FAILED` | sap-error-kb | Curation store unreadable/unwritable. |
| `FIX_INCIDENT_BLOCKED` | sap-fix-incident | Fix loop blocked (lock, authorization, gate). |
| `FIX_INCIDENT_NOT_CODE` | sap-fix-incident | Root cause is not a code defect (config/data/authorization) — routed to manual. |
| `FIX_INCIDENT_NOT_GREEN` | sap-fix-incident | Fix deployed but verification (unit/ATC) still red. |
| `FIX_INCIDENT_SOURCE_UNAVAILABLE` | sap-fix-incident | Object source unreadable over RFC. |

## Transport operations (`/sap-stms`)

| Class | Meaning |
|---|---|
| `STMS_NOT_CALIBRATED` | Import control IDs still PLACEHOLDER on this release — record once with `/sap-gui-probe --record`. |
| `STMS_NO_AUTH` | Missing STMS authorization (S_TRANSPRT / S_CTS_ADMI). |
| `STMS_BLOCKED` | Queue/import blocked (predecessor, target lock). |
| `STMS_IMPORT_RC_ERROR` | Import finished with RC >= 8. |
| `STMS_TMS_RFC_DOWN` | TMS communication layer down — STMS_IMPORT opened the TMS Alert Viewer (`SAPLTMSU_ALT`) instead of the queue, typically `RFC_COMMUNICATION_FAILURE` on the `TMSADM@<SID>.DOMAIN_<SID>` destination (gateway unreachable, or its secure-storage logon data missing). Basis fix (repair/regenerate the TMSADM destination); control-ID recording is NOT the remedy. |

## CDS generation (`/sap-gen-cds`)

| Class | Meaning |
|---|---|
| `CDS_RELEASE_UNSUPPORTED` | Target SAP_BASIS < 7.50 — the CDS DDL handler infrastructure is absent; the skill stops with an honest NOT_SUPPORTED (use `/sap-gen-abap` for classic ABAP). |
| `CDS_INSTALLER_MISSING` | Installer FM `Z_CDS_DDL_INSTALL` absent or not Remote-Enabled (FMODE != R) — run the Step 3 bootstrap. |
| `CDS_ACTIVATE_FAILED` | DDL source saved but activation raised (syntax / DDIC error) — the generated SQL view was not produced. |

## RAP generation (`/sap-gen-rap`)

| Class | Meaning |
|---|---|
| `RAP_RELEASE_UNSUPPORTED` | Target SAP_BASIS < 7.54 or no RAP infrastructure (zero `R3TR BDEF` rows) — RAP does not exist here; the skill stops (use `/sap-gen-abap` + `/sap-gen-cds`). S/4-only by design. |
| `RAP_MANUAL_STEP_PENDING` | `deploy` (v1.5) paused for an ADT-only step (BDEF paste / SRVD+SRVB create+publish) that was not confirmed done — the run ends verdict PARTIAL, never a false COMPLETE. *(Reserved: `deploy` is not yet implemented; `generate`/`package`/`verify` emit only `RAP_RELEASE_UNSUPPORTED`, `OBJECT_NAMING_VIOLATION`, `RFC_LOGON_FAILED`.)* |

## Test plan generation (`/sap-gen-test-plan`)

| Class | Meaning |
|---|---|
| `TESTPLAN_INPUT_INCOMPLETE` | Input parsed but a mandatory section is missing (`_process.txt` absent/empty, or a banner-less degraded file) — the plan cannot be derived faithfully. |
| `TESTPLAN_RENDER_FAILED` | Template fill or xlsx emission failed (anthropic-skills:xlsx unavailable falls back to md with a WARN, not this class). |

## IDoc handler generation (`/sap-gen-idoc-handler`)

| Class | Meaning |
|---|---|
| `IDOC_TYPE_NOT_FOUND` | `IDOCTYPE_READ_COMPLETE` raised OBJECT_UNKNOWN / returned no segments for the basic type — cannot generate a decode loop. |
| `IDOC_MAPPING_INVALID` | The mapping spec has an unknown `rule` token, a missing `target`, or references a segment not in the IDoc type's tree — fail loud, nothing generated. |
| `IDOC_WIRING_INCOMPLETE` | `verify-wiring` verdict is UNWIRED/PARTIAL — the WE57/BD51/WE42 rows the handler needs are missing (the operator TODO list, not a hard failure). |

## Docs pipeline & generation (sap-gen-code)

| Class | Emitted by | Meaning |
|---|---|---|
| `INPUT_NOT_FOUND` | sap-docs-check, sap-docs-extract, sap-gen-test-plan | The input document / work folder / `_*.txt` spec file the skill was pointed at does not exist — nothing processed. |
| `RAW_DUMP_FAILED` | sap-docs-extract | The `{doc_name}_raw.txt` dump of the source document could not be produced (unreadable/corrupt document). |
| `EXTRACT_FAILED` | sap-docs-extract | Structuring the raw dump into the per-type `_*.txt` files failed. |
| `CONVERT_FAILED` | sap-docs-convert | A normalisation rule from `spec_conversion_rules.tsv` could not be applied to the extracted spec files. |
| `DDIC_CHECK_FAILED` | sap-docs-check | The DDIC-definition validation dimension could not run to completion. |
| `PROCESS_CHECK_FAILED` | sap-docs-check | The process-logic validation dimension could not run to completion. |
| `GEN_ABAP_FAILED` | sap-gen-abap | Generation was blocked (missing `_process.txt`, unsupported program type, identifier too long after retry, …) — no source emitted. |
| `META_NOT_FOUND` | sap-docs-layout | The workbook has no `(Meta) Layout` sheet — the layout contract cannot be read. |
| `META_ALREADY_EXISTS` | sap-docs-layout | `bootstrap` on a workbook that already carries a `(Meta) Layout` sheet — refused rather than overwritten. |
| `SECTION_UNKNOWN` | sap-docs-layout | A layout row references a section key that is not in the canonical section catalogue. |
| `SHEET_NOT_FOUND` | sap-docs-layout | A layout row points at a worksheet that does not exist in the workbook. |
| `INVALID_ARGUMENT` | sap-docs-layout | Bad invocation arguments (unknown mode / missing workbook path). |
| `XLSX_WRITE_FAILED` | sap-docs-layout | The workbook write-back failed (file locked / xlsx emission error). |

## Git backend (`/sap-git`)

| Class | Meaning |
|---|---|
| `GIT_NOT_INSTALLED` | `git` is not in PATH — the whole skill is unusable (fix: winget install Git.Git). |
| `GIT_REPO_DIRTY` | The target repo worktree has uncommitted changes — snapshot/diff refuse rather than risk the user's edits (and to keep diff's `reset --hard` provably safe). |
| `GIT_COMMIT_FAILED` | `git commit` returned non-zero (identity/hook/permission) — nothing was recorded. |
| `SNAPSHOT_EMPTY_SCOPE` | The PACKAGE/TR/object-list resolved to zero serializable objects. |
| `SNAPSHOT_SERIALIZE_FAILED` | The serializer aborted before writing the manifest (RFC drop mid-scan) — no partial snapshot is committed. |

## Forms (`/sap-forms`)

| Class | Meaning |
|---|---|
| `FORMS_NOT_FOUND` | The named SmartForm/SAPscript/Adobe form does not exist (STXFADM/TADIR probe empty) — exit 1, no artifact. |
| `FORMS_EXPORT_INVALID` | A downloaded export could not be parsed (SmartForm XML not well-formed / not `<SMARTFORM>`-rooted, or an RSTXSCRP file with no ITF structures) — never a silent success. |
| `FORMS_NAST_CHANNEL_REFUSED` | `test-print nast` on a non-print channel (NACHA!=1: EDI/mail/fax) without the typed `REPROCESS` confirmation, or a wildcard/missing OBJKY — refused (re-emitting real output is gated). |

## File transfer (`/sap-file-transfer`)

| Class | Meaning |
|---|---|
| `FILE_TCODE_UNAVAILABLE` | CG3Y/CG3Z parameter dialog never appeared — transaction locked (SM01) or `S_TCODE` missing. |
| `FILE_TRANSFER_FAILED` | Transfer executed but the status bar reported `E`/`A`, or no `S` success message arrived (silence is not success). |
| `FILE_TARGET_EXISTS` | Target file exists and `--overwrite` was not requested (SPOP Query declined; driver exit 4). |
| `FILE_SOURCE_MISSING` | Source file unreadable — "Cannot open file" Information popup (`SAPMSDYP/10`); OS errno text in `error_msg` (driver exit 5). |
| `FILE_LIST_RFC_UNAVAILABLE` | `list`/`exists` could not reach RFC (NCo missing, logon failed) — transfer modes remain usable; run `/sap-doctor` rfc group. |
| `FILE_VERIFY_MISMATCH` | Post-transfer verification failed (BIN size/hash mismatch, or `exists` probe cannot find the just-uploaded target). |

## Enqueue locks (`/sap-sm12`)

| Class | Meaning |
|---|---|
| `LOCK_OWNER_LIVE` | Release refused: the lock owner still has a session on an application server (liveness gate returned LIVE). A live owner's lock is never released. |
| `LOCK_LIVENESS_UNVERIFIED` | Release refused: owner death could not be proven (RFC error, the multi-instance `TH_SYSTEMWIDE_USER_LIST` leg failed, or an unparseable server/user list). COULD_NOT_CHECK is treated as unsafe — never released. |
| `LOCK_NOT_FOUND` | The selected lock matched no current enqueue entry (it may have cleared itself) — nothing to release. |
| `LOCK_DELETE_FAILED` | `ENQUE_DELETE` ran but the authoritative re-read still sees the lock (typically a missing `S_ENQUE` delete authorization). |
| `LOCK_WRAPPER_MISSING` | `release` needs `Z_GENERIC_RFC_WRAPPER_TBL` (for `ENQUE_DELETE` + the multi-instance liveness leg) and it is not deployed — run `/sap-dev-init`. `list` is unaffected. |

## Version history (`/sap-version-history`)

| Class | Meaning |
|---|---|
| `VH_NO_VERSIONS` | The object's version store is empty (versions are written only on release/generation, so a freshly built object legitimately has none) — reported honestly, never rendered as "no differences". |
| `VH_VERSION_NOT_FOUND` | A requested `VERSNO` is not in the version store (out of range) — `SVRS_GET_REPS_FROM_OBJECT` returned no source for it. |
| `VH_TYPE_UNSUPPORTED` | The resolved object is a class / interface — per-include class versioning is v2; v1 supports programs / includes / function modules only. |

## VOFM routines (`/sap-vofm`)

| Class | Meaning |
|---|---|
| `VOFM_RANGE_VIOLATION` | `create`/`update` requested for a routine number outside the customer range (600–999) — editing an SAP-numbered routine is a modification, refused (no `--force`). |
| `VOFM_SSCR_KEY_REQUIRED` | The VOFM object-key (SSCR) popup fired and the user declined to supply the key — the skill never sources/caches SSCR keys; the create aborts with the include name to register. |
| `VOFM_REGEN_STALE` | Post-write authoritative verify found the routine registered (TFRM) + include active but **not** wired into the frame include — RV80HGEN did not take; fails loud, never a false green. |
| `VOFM_TYPE_UNVERIFIED` | The requested `<type>` resolved to a `verified=NO` VOFM group (copy-requirements / data-transfer / output / …) whose frame + customer prefix are not yet confirmed — refused with the valid list, never guessed. |

*(The read modes `list`/`check`/`explain` emit only the generic `RFC_LOGON_FAILED`. The
first three classes above are emitted by the `create`/`update`/`regen` write modes — NEEDS_RECORDING, deferred to a `/sap-gui-probe` session — and are reserved here per the same-commit rule so the write phase adds no new taxonomy.)*

## Performance trace (`/sap-trace`)

| Class | Meaning |
|---|---|
| `TRACE_QUERY_FAILED` | The ST05/SAT GUI display or ALV-export leg failed — the trace list could not be driven/exported on this release. |
| `TRACE_PARSE_FAILED` | The offline analyzer (`sap_trace.ps1`) could not parse the exported/imported trace file. |
| `TRACE_EMPTY` | The trace ran but produced no usable rows (nothing recorded, or every row below `--threshold-ms`) — a distinct class so "empty" is never mistaken for a parse failure. |

## Spool download (`/sap-sp02`)

| Class | Meaning |
|---|---|
| `SP02_NOT_FOUND` | The target spool number matched no row in the SP02 own-spool list (wrong number, another user's spool, or already deleted). |
| `SP02_DOWNLOAD_FAILED` | The display/save leg ran but the local file never materialized (or verification failed) — never reported as a successful download. |

## Where-used list (`/sap-where-used-list`)

| Class | Meaning |
|---|---|
| `WHERE_USED_FAILED` | The scope popup / where-used result list could not be driven or read. |
| `WHERE_USED_PRINT_FAILED` | The List > Print / spool leg failed after a successful list build. |

## Number range objects (`/sap-snro`)

| Class | Meaning |
|---|---|
| `SNRO_FAILED` | An SNRO create/update/interval-maintenance leg failed (GUI drive or post-write verify) — the number-range failures not covered by `TR_RESOLUTION_FAILED` / `GUI_TIMEOUT`. |

## Add-on table update (`/sap-update-addon`)

| Class | Meaning |
|---|---|
| `UPDATE_ADDON_FAILED` | The SM30 / SE16 / ZCMRUPDATE_ADDON_TABLE insert-or-update leg failed after method detection (per-row errors are additionally captured in the result file). |

## Workbench transaction skills (sap-dev-core GUI legs)

| Class | Emitted by | Meaning |
|---|---|---|
| `LOGIN_FAILED` | sap-login | The GUI login leg failed (connection opened but no authenticated session — bad credentials, locked user, unexpected login screen). Distinct from `RFC_LOGON_FAILED` (the NCo connectivity probe). |
| `TR_CREATE_FAILED` | sap-se01 | CREATE mode could not produce a new transport request (or the new TRKORR could not be resolved locale-independently — never guessed). |
| `SE21_FAILED` | sap-se21 | A package create/delete leg failed (GUI drive, popup chain, or post-action verify). |
| `SE11_FAILED` / `SE11_INACTIVE` / `SE11_LOCKED` | sap-se11 | A DDIC create/update/delete leg failed / the object stayed inactive after Activate (post-activate verify non-'A') / the object is edit-locked by another user or session. |
| `SE37_FAILED` / `SE37_INACTIVE` / `SE37_LOCKED` | sap-se37 (`SE37_FAILED` also reused by sap-rfc-wrapper's FM leg) | An FM create/update/delete leg failed / the FM or its function group stayed inactive after Activate / the FM is edit-locked. |
| `SE24_FAILED` / `SE24_INACTIVE` / `SE24_LOCKED` | sap-se24 | A class/interface deploy leg failed / the class stayed inactive after Activate / the class is edit-locked. |
| `SE91_FAILED` | sap-se91 | A message-class create/update or change-properties leg failed. |
| `SE41_FAILED` | sap-se41 | A GUI status / menu painter leg failed. |
| `SE51_FAILED` | sap-se51 | A screen painter leg failed. |
| `SE54_FAILED` | sap-se54 | A table-maintenance-generator leg failed. |
| `SE19_FAILED` / `BADI_NOT_FOUND` / `BADI_AMBIGUOUS_UNRESOLVED` / `DELETE_REFUSED_SAFETY` | sap-se19 | An implementation create/update/delete leg failed / the named BAdI (definition or implementation) does not exist / a name matching both classic and new-BAdI worlds was not disambiguated / delete refused by the created-by-us safety ledger (no ledger hit ⇒ refuse by default). |
| `CMOD_FAILED` / `RFC_FAILED` | sap-cmod | A CMOD project create/assign/activate GUI leg failed / a read-only RFC lookup leg (`RFC_READ_TABLE` on MODATTR/MODACT/MODSAP…) failed after connect. |
| `SE16N_FAILED` / `TABLE_NOT_FOUND` | sap-se16n | The SE16N query/download leg failed / the named table does not exist on the target system. |
| `CHANGE_PACKAGE_FAILED` / `OBJECT_LOCKED_IN_TR` | sap-change-package | The Object Directory Entry dialog leg failed / the object sits in a modifiable TR (E071/E070 pre-check), which blocks the package move. |
| `ACTIVATE_FAILED` | sap-activate-object | The routed activation (SE38/SE37/SE24/SE11 + worklist popup) did not leave the object active (PROGDIR/DWINACTIV verify). |
| `FUNCTION_GROUP_FAILED` / `FUNCTION_GROUP_DELETE_FAILED` | sap-function-group | A function-group create/re-activate leg failed / the delete leg failed (including the SE38 `SAPL<FG>` fallback path). |
| `BDC_FAILED` / `BDC_FILE_NOT_FOUND` | sap-call-bdc | `ABAP4_CALL_TRANSACTION` reported errors in BDCMSGCOLL / the SHDB recording file is absent from the bdc/ folder. |
| `RFC_WRAPPER_FAILED` | sap-rfc-wrapper | The wrapper FM / DDIC parameter infrastructure deploy failed (delegated SE11/SE37 legs report their own classes; this is the orchestrator-level failure). |
| `CHECK_ABAP_FAILED` | sap-check-abap | A check dimension could not run to completion (not a findings verdict — findings are the result file). |
| `FIX_ABAP_FAILED` / `BACKUP_FAILED` | sap-fix-abap | The fix loop could not produce a clean re-checked source / the pre-fix backup of the original source could not be written (fix refused — never edit without a backup). |
| `CHECK_FIX_FAILED` / `DISPATCH_FAILED` | sap-check-fix | The check-and-fix loop ended without reaching green / the input could not be dispatched to the owning check/fix skill (unrecognized object type). |

## Program deploy (`/sap-se38`)

The pre-deploy existence/syntax gate emits the generic `SE38_CHECK_FAILED`
(see the Generic infrastructure table); the failure matrix maps the deploy
legs to these classes:

| Class | Meaning |
|---|---|
| `SE38_SYNTAX` | The in-editor Ctrl+F2 syntax check found errors — deploy stopped before Save/Activate. |
| `SE38_UPLOAD` | The source upload/paste leg failed (upload menu/dialog broke, source file unreadable, paste guard aborted). |
| `SE38_LOCKED` | The program could not be opened in change mode (edit lock or missing authorization on open). |
| `SE38_AUTH` | An SE38 leg was refused for missing authorization (S_DEVELOP / S_TCODE). |
| `SE38_INACTIVE` | The program is still INACTIVE after Activate (activation silently failed — missing DDIC types, message class, or local-class syntax errors). |
| `SE38_CONTENT_MISMATCH` | Post-deploy content gate: the program is ACTIVE but its active source ≠ the uploaded file (the paste did not take — usually clipboard contention; the OLD source was re-activated). Not a success. |
| `SE38_GENERIC` | An SE38 failure not matched by any specific row of the failure matrix. |
| `SE38_TEXTELM_CHANGE_FAIL` | Step 5c: the text-elements editor did not open in Change mode (source is active; only text elements are missing). |
| `SE38_TEXTELM_REENTRY_FAIL` | Step 5c: text elements saved but re-entry for Activate failed — TEXTPOOL is saved-but-inactive. |
| `SE38_TEXTELM_TBL_UNKNOWN` | Step 5c: the text-elements sub-screen / Text Symbols tab / table ids are unknown on this SAP build — record once with `/sap-gui-probe --record`. |
| `SE38_TEXTELM_TR_MISSING` | Step 5c: SAP prompted for a TR but none was resolved — resolve via `/sap-transport-request` and re-run. |
| `SE38_TEXTELM_SAVE_FAIL` | Step 5c: the text-elements Save ended with sbar `E`/`A` — TEXTPOOL not written. |
| `SE38_TEXTELM_ACTIVATE_FAIL` | Step 5c: TEXTPOOL saved but its activation ended with sbar `E`/`A` — saved-but-inactive. |
| `SE38_TEXTELM_NO_STATUS` | Step 5c: the text-elements VBS died before emitting its final `TEXT_ELEMENTS:` status line. |

## Dev environment lifecycle (`/sap-dev-init`, `/sap-dev-clean`)

| Class | Emitted by | Meaning |
|---|---|---|
| `DEV_INIT_FAILED` | sap-dev-init | The init orchestration failed outside the three artefact steps below. |
| `PACKAGE_FAILED` | sap-dev-init | The development-package step (delegated `/sap-se21`) failed. |
| `FUGR_FAILED` | sap-dev-init | The function-group step (delegated `/sap-function-group`) failed. |
| `DEPLOY_FAILED` | sap-dev-init | The utility-program deploy step (delegated `/sap-se38`, ZCMRUPDATE_ADDON_TABLE) failed. |
| `DEV_CLEAN_FM_FAILED` | sap-dev-clean | Deleting the wrapper FM / a function-group member failed. |
| `DEV_CLEAN_DDIC_FAILED` | sap-dev-clean | Deleting a dev-init DDIC artefact (parameter structure / table type) failed. |
| `DEV_CLEAN_FG_HAS_EXTRAS` | sap-dev-clean | The function group contains FMs beyond the dev-init set — skipped rather than deleting operator content (override: `--force`). |
| `DEV_CLEAN_PKG_NON_EMPTY` | sap-dev-clean | The package still contains objects after artefact cleanup — package delete skipped, never cascaded. |
| `DEV_CLEAN_TR_RISK` | sap-dev-clean | The dev TR drop was refused because the request carries risk content (e.g. foreign/unexpected entries). |
| `DEV_CLEAN_CONFIG_MISMATCH` | sap-dev-clean | The Step-2 anchor gate found the configured dev defaults pointing at different artefacts than the ones on the system — ABORT, nothing deleted (`--force`/`--reset` do NOT override). |

## GUI authoring utilities (`/sap-gui-probe`, `/sap-gui-inspect`, `/sap-gui-skill-scaffold`)

| Class | Emitted by | Meaning |
|---|---|---|
| `ACTION_FAILED` | sap-gui-probe | A driven step's action could not be executed on the live screen (findById miss, action VBS error). |
| `MAX_STEPS` | sap-gui-probe | The step budget was exhausted before the scenario completed. |
| `INSPECT_FAILED` | sap-gui-inspect | The property-tree dump leg failed. |
| `INSPECT_NO_SESSION` | sap-gui-inspect | No attachable SAP GUI session for the inspection (skill-local variant of `NO_SESSION`). |
| `INSPECT_HARDCOPY_FAILED` | sap-gui-inspect | The window Hardcopy (screenshot BMP) capture failed. |
| `INSPECT_COMPOSE_FAILED` | sap-gui-inspect | Composing the captured BMPs into the annotated PNG (`sap_gui_diagnose_compose.ps1`) failed. |
| `PROBE_FAILED` | sap-gui-skill-scaffold | A delegated `/sap-gui-probe` scenario failed — merge is refused (a partial scaffold is worse than none). |
| `MERGE_FAILED` | sap-gui-skill-scaffold | Merging the probe run folders into one skill draft failed (cross-probe diff / popup-guard synthesis broke). |
| `EMIT_FAILED` | sap-gui-skill-scaffold | Writing the merged skill folder (SKILL.md + references VBS) failed. |
| `BAD_SKILL_NAME` | sap-gui-skill-scaffold | The requested skill name violates the repo naming convention (`sap-` prefix, kebab-case). |
| `INSUFFICIENT_SCENARIOS` | sap-gui-skill-scaffold | Fewer usable scenarios than the scaffold needs — run ends `SKIPPED` with the missing-scenario prompt. |
| `PIN_SYSTEM_MISMATCH` | sap-gui-skill-scaffold | The pinned connection's system identity does not match the system the scaffold was asked to target — refused before probing. |

## Release management & delivery (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `RELNOTES_EMPTY_SCOPE` | sap-release-notes | The TR list / date range resolved to no content objects (unknown TR, empty request) — no CAB pack is written. |
| `RELNOTES_SCOPE_TOO_LARGE` | sap-release-notes | A `--from/--to` range matched more than the 50-TR cap — refused; narrow the range or add `--user` / `--prefix`. |
| `DR_SCOPE_EMPTY` | sap-delivery-report | The scope token resolved to no object (unknown name / empty package) — no report is written. |
| `DR_NO_ARTIFACT_INDEX` | sap-delivery-report | No `index.jsonl` exists yet — the report still renders with an all-AMBER "no evidence" posture (WARN, exit 0), never a fabricated green. |
| `DR_SNAPSHOT_CORRUPT` | sap-delivery-report | The snapshot named by `--since` is unparseable — the diff section is skipped (WARN), never silently diffed against a different snapshot. |

## Integration & interfaces (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `IFACE_SOURCE_UNAVAILABLE` | sap-interface-inventory | Every requested `--sources` member has no backing table on this release (e.g. `--sources odata` alone on ECC where Gateway is not installed) — the scan refuses rather than returning an empty "success". A single unavailable source among several is a COULD_NOT_CHECK / NOT_APPLICABLE Gaps row, not this error. |
| `RFCQ_ACTION_REFUSED` | sap-rfc-monitor | A tRFC/qRFC LUW or queue **delete** / **unlock** was requested — refused (not gated); manual SM58 / SMQ1 / SMQ2 only. RSARFCSE's delete flag is never set on any path. |
| `RFCQ_RETRY_NOT_CLEARED` | sap-rfc-monitor | After a confirm-gated RSARFCEX retry, the authoritative queue re-read still shows failed tRFC LUWs for the destination (UNCHANGED, or only REDUCED) — reported honestly, never as success. Usually a `TARGET_DOWN` / `AUTH` / `DATA` cause that must be fixed before a retry can drain the queue. |
| `IDOC_SELECTION_UNBOUNDED` | sap-idoc | `find` / `triage` was invoked with no bound (status / message type / partner / date / docnum) — refused rather than scanning all of EDIDC. |
| `IDOC_NOT_FOUND` | sap-idoc | `explain <DOCNUM>` named an IDoc that does not exist (EDIDC probe empty). |
| `IDOC_REPROCESS_FAILED` | sap-idoc | After a confirm-gated reprocess (RBDMANI2/RBDAPP01/RSEOUT00), the authoritative EDIDS re-read shows one or more IDocs did NOT reach a success status — reported per-IDoc, never summarized as done. A DATA-class cause (e.g. posting period not open) must be fixed before a reprocess can succeed. |

## Output determination (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `OUTPUT_DOC_NOT_FOUND` | sap-output-diagnose | The `billing <VBELN>` / `po <EBELN>` document does not exist (VBRK/EKKO probe empty) — no diagnosis is produced. |
| `OUTPUT_REISSUE_FAILED` | sap-output-diagnose | After a confirm-gated RSNAST00 re-issue, the authoritative NAST re-read still shows VSTAT=2 (processing failed) — reported with the fresh CMFP log excerpt, never as success. (An unmapped access key field or unreadable B-table is a COULD_NOT_CHECK finding, and a BRF+-managed document caps the verdict at GO_WITH_WARNINGS — neither is a FAILED class.) |

## Testing & regression (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `GM_BASELINE_NOT_FOUND` | sap-golden-master | `verify`/`rebase`/`show`/`delete` named an `<ID>` with no stored baseline. |
| `GM_SYSTEM_MISMATCH` | sap-golden-master | `verify` ran against a different (SID, CLIENT) than the baseline was captured on — refused (an S4D golden never verifies against another system). |
| `GM_VARIANT_DRIFT` | sap-golden-master | The report variant changed since capture (VARID version / change stamp differs) — `verify` refuses unless `--accept-variant-drift`. |
| `GM_CAPTURE_INCOMPLETE` | sap-golden-master | A capture leg failed (job aborted, spool missing/deleted, SE16N returned no rows where the golden had them) — verdict `COULD_NOT_VERIFY`, never GO. |

## Authorizations & users (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `SU01_NON_DEV_REFUSED` | sap-su01 | A write mode was requested on a production client (T000 `CCCATEGORY=P`) or a non-modifiable one (`CCCORACTIV=3`) — refused; no override flag. |
| `SU01_SELF_TARGET_REFUSED` | sap-su01 | `lock`/`delete`/`reset-password` targeted the pinned profile's own user — refused (self-lockout guard). |
| `SU01_USER_EXISTS` | sap-su01 | `create` on a username already in USR02 — no BAPI call made. |
| `SU01_USER_NOT_FOUND` | sap-su01 | `show`/`assign`/`lock`/`delete`/… on a username not in USR02. |
| `SU01_ROLE_NOT_FOUND` | sap-su01 | `assign`/`unassign` named a role absent from AGR_DEFINE — refused before any write. |
| `SU01_BAPI_ERROR` | sap-su01 | A BAPI_USER_* write returned type E/A (e.g. `01/498` missing S_USER_GRP, or a CUA-child block) — surfaced verbatim, never a silent partial. |
| `SU01_VERIFY_MISMATCH` | sap-su01 | The BAPI RETURN was green but the authoritative USR02 / AGR_USERS re-read disagreed with the intent — reported as FAILED, never success. |
| `AUTH_INPUT_INVALID` | sap-auth-diagnose | `check` was called with no authorization object (neither `--object` nor a parseable `--input` file) — no RFC made. |
| `AUTH_USER_NOT_FOUND` | sap-auth-diagnose | The target user is absent from USR02 — nothing to diagnose. |
| `AUTH_SU53_SCRAPE_FAILED` | sap-auth-diagnose | (next phase) The SU53 GUI scrape could not read a record on an unrecorded screen layout — `NEEDS_RECORDING`, never a fabricated "no failures". |
| `AUTH_TRACE_NOT_PERMITTED` | sap-auth-diagnose | (next phase) `S_ADMI_FCD` missing — the STAUTHTRACE bracket refuses before touching the GUI. |
| `AUTH_TRACE_UNSUPPORTED_RELEASE` | sap-auth-diagnose | (next phase) The trace result store `SUAUTHVALTRC` is absent (ECC 6) — trace mode refused loud with the ST01 disclosure. |
| `AUTH_TRACE_STOP_FAILED` | sap-auth-diagnose | (next phase) The STAUTHTRACE stop did not verify off — the loudest failure; manual stop instructions emitted, never a silently-left-running trace. |
| `ROLE_NOT_FOUND` | sap-explain-role | The named PFCG role is absent from AGR_DEFINE — near-miss `LIKE` candidates are listed; no dossier is written. |
| `ROLE_READ_DENIED` | sap-explain-role | A **core** area (AGR_DEFINE / AGR_1251) returned an authorization error under the pinned user — the dossier cannot be built. A denied *holders* area alone stays SUCCESS + coverage=PARTIAL. |
| `ROLE_DATA_TRUNCATED` | sap-explain-role | The AGR_1251 read hit `--max-rows` — the dossier renders with coverage=PARTIAL (`>N` auth rows), never as complete. |
| `MODE_NOT_IMPLEMENTED` | sap-explain-role (+ future sap-project phase-2 modes) | A not-yet-built mode/phase was requested (e.g. `concept`) — refused loud, never a half-result. |
| `AUTH_ROLE_NOT_FOUND` | sap-suim | `users --role=<R>` named a role absent from AGR_DEFINE — near-miss `LIKE` candidates listed; not an empty "nobody has it". |
| `AUTH_TCODE_NOT_FOUND` | sap-suim | `users --tcode=<T>` named a transaction absent from TSTC (typo) — refused before an empty "nobody can run it". |
| `AUTH_MATRIX_INVALID` | sap-suim | `critical` — the critical_auths.tsv matrix is missing or has a bad header (`NO_MATRIX`) — the scan cannot run; never a false "0 critical grants". |
| `AUTH_VOLUME_CAPPED` | sap-suim | A user-list read hit the `--max` volume cap (`capped=Y`) and the caller required a complete list — narrow the selection or raise `--max`; never presented as the full population. |

## Change history & audit (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `CDH_CLASS_UNKNOWN` | sap-change-history | The business token did not resolve to a change-document class (not in the curated map, no `OBJECTCLAS:` bypass) — the curated tokens are listed, no RFC made. |
| `CDH_NO_CHANGES` | sap-change-history | No change documents for the object/user/window (`headers` empty), OR the object class is not decodable (`decode` — the wrapper's `NO_POSITION_FOUND`/`DYNAMIC_CALL_FAILED`, handled fail-soft) — reported as "no changes / not change-doc-enabled", never "nothing changed". |
| `CDH_WRAPPER_MISSING` | sap-change-history | `Z_GENERIC_RFC_WRAPPER_TBL` absent or not remote-enabled (FMODE≠R) — decode cannot run; points to `/sap-dev-init` (which owns the deploy consent). This skill never deploys. |
| `CDH_DECODE_CAPPED` | sap-change-history | `user`/`window` decode fan-out hit `--decode-max`; the undecoded `(class,id)` remainder is registered `COVERAGE=COULD_NOT_CHECK`, never silently dropped. |

## Transport of copies (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `TOC_CREATE_FAILED` | sap-transport-copies | `TR_INSERT_REQUEST_WITH_TASKS` (type-T) via the wrapper returned no TRKORR, or the E070 re-read did not show `TRFUNCTION='T'` — no ToC created. |
| `TOC_INCLUDE_FAILED` | sap-transport-copies | A `TR_COPY_COMM` source→ToC copy raised (e.g. source objects locked in another modifiable request) — reported per failing source, ToC left as-is. |
| `TOC_UNION_MISMATCH` | sap-transport-copies | The ToC's E071 object list does not cover the union of the sources (+ their tasks) — every missing `(PGMID,OBJECT,OBJ_NAME)` is listed; release is refused. |
| `TOC_RELEASE_BLOCKED` | sap-transport-copies | `--release` requested but the union was not verified clean (or the post-release E070 `TRSTATUS` is not R/O) — refused; `--force` + explicit yes overrides. |
| `TOC_TARGET_INVALID` | sap-transport-copies | No `--target` and no `toc_default_target` — a ToC target is never guessed. |
| `TOC_NOT_FOUND` | sap-transport-copies | `verify`/`include`/`release` named a TRKORR that is not a modifiable type-T request in E070. |

## Test data & FI posting (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `FIPOST_INPUT_INVALID` | sap-fi-post | The definition file failed local validation (missing HEADER field, duplicate ITEMNO, no AMOUNT, < 2 lines) — no RFC made. |
| `FIPOST_UNBALANCED` | sap-fi-post | Debits ≠ credits for a currency (sum ≠ 0) — refused before the network round-trip. |
| `FIPOST_CHECK_FAILED` | sap-fi-post | `BAPI_ACC_DOCUMENT_CHECK` returned type E/A (closed period, blocked/missing account, substitution, …) — the dry-run's structured messages are rendered; `post` never proceeds to POST. |
| `FIPOST_POST_FAILED` | sap-fi-post | `BAPI_ACC_DOCUMENT_POST` returned E/A (or no OBJ_KEY) — the transaction was rolled back (`BAPI_TRANSACTION_ROLLBACK`), no document persisted. |
| `FIPOST_VERIFY_FAILED` | sap-fi-post | POST + COMMIT reported success but the authoritative BKPF re-read found no document — reported as FAILED, never trusted from the BAPI echo. |
| `TCD_SCENARIO_INVALID` | sap-tcd-chain | The O2C scenario file failed local validation (missing ORDER_HEADER org field, no sold-to AG partner, no items) — no RFC made. |
| `TCD_CHAIN_STEP_FAILED` | sap-tcd-chain | A chain BAPI (order/delivery/GI/billing) returned type E/A — the transaction was rolled back; the verbatim BAPIRET2 (usually a customizing gap: shipping point, copy control, picking relevance) is the deliverable. The manifest is finalized PARTIAL. |
| `TCD_CHAIN_VERIFY_FAILED` | sap-tcd-chain | A step's BAPI + COMMIT reported success but the authoritative VBFA re-read found no successor document after the backoff — a false success; the chain stops, never rendered as complete. |
| `BP_FAILED` | sap-bp | A business-partner create/change GUI leg failed (screen drive or post-write verify). |
| `MM01_FAILED` | sap-mm01 | A material-master create GUI leg failed (screen drive or post-write verify). |
| `VA01_FAILED` | sap-va01 | A sales-order create GUI leg failed (screen drive or post-write verify). |

## Configuration compare (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `CFG_SAME_IDENTITY` | sap-config-compare | LEFT (pinned) and RIGHT (`--against`) resolve to the same SID+client — there is nothing to compare; refused before any read. |
| `CFG_OBJECT_NOT_FOUND` | sap-config-compare | The table/view exists on neither / only one side (DD02L + DD25L both empty) — the message names which side(s) miss it; no diff produced. |
| `CFG_NO_COMMON_KEY` | sap-config-compare | The two sides share no comparable key column (or a client-dependent table keyed only on MANDT — single-row cross-system value compare is v1.5). |
| `CFG_UNBOUNDED_READ` | sap-config-compare | A full read would exceed `--max-rows` and no `--where`/`--options` filter was given — refused with a suggested key-field filter; never silently capped. |

## Transport sequencing & freeze audit (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `SEQ_INPUT_INVALID` | sap-transport-sequencer | Empty TR list, or more than `--max` (hard cap 500) — refused before any read. |
| `SEQ_TR_NOT_FOUND` | sap-transport-sequencer | A requested TR is absent from source E070 — hard error naming the missing TRs, unless `--skip-missing` (then a WARN finding per skipped TR). |
| `SEQ_TARGET_UNREACHABLE` | sap-transport-sequencer | `--target` profile is ambiguous/unknown/unreachable — the user chooses continue-source-only (target rows `COULD_NOT_CHECK`, verdict capped) or abort; never a silent degrade. |
| `FREEZE_WINDOW_UNBOUNDED` | sap-transport-sequencer | Freeze window is missing a bound or exceeds 92 days — refused before any read. |
| `FREEZE_POLICY_INVALID` | sap-transport-sequencer | The freeze policy JSON is malformed (unparseable, bad date format) — refused. |

## Health check (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `HC_BASELINE_CORRUPT` | sap-health-check | The per-system baseline JSON could not be parsed (`{work_dir}\runtime\health\<SID>_<CLIENT>_baseline.json`) — fail loud rather than treat every finding as NEW; the operator reviews/repairs or `baseline reset`. |
| `HC_NO_HISTORY` | sap-health-check | `--trend` (v1.5) invoked with fewer than 2 persisted snapshots — no fabricated dashboard; states that trend needs accumulated history. |

## Post-refresh verify (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `REFRESH_IDENTITY_MISMATCH` | sap-refresh-verify | The connected SID/client does not match the expectations config — the run aborts before auditing so it can never sign off the wrong (possibly production) box. |
| `REFRESH_CONFIG_MISSING` | sap-refresh-verify | No expectations config for this (SID,client) — the skill refuses to audit rather than guess a landscape; `init-config` scaffolds one. |
| `REFRESH_CONFIG_INVALID` | sap-refresh-verify | The config parsed but a required key is absent (`sid`/`client`/`expected_logsys`) — named in the message. |

## Mass data load (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `MASS_LOAD_CLIENT_REFUSED` | sap-mass-load | The target client is production (T000 CCCATEGORY='P') or T000 was unreadable — a NON-OVERRIDABLE stop (never assume non-production). |
| `MASS_LOAD_TARGET_UNSUPPORTED` | sap-mass-load | The `--target-bapi` is not remote-enabled (FMODE blank) or not found — v1 refuses, pointing at the v1.5 wrapper path. |
| `MASS_LOAD_MAPPING_UNAPPROVED` | sap-mass-load | execute was requested without an operator-approved mapping, or the mapping is empty. |
| `MASS_LOAD_STALE_DRYRUN` | sap-mass-load | The input-file hash drifted from the snapshot, or the dry-run is missing / BLOCKED / older than the mapping. |
| `MASS_LOAD_ROW_CAP` | sap-mass-load | Row count exceeds the `--max-rows` cap (default 1000 BAPI / 200 BDC) — re-confirm to raise. |

## User guide (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `GUIDE_INPUT_INVALID` | sap-user-guide | The input is not a usable /sap-gui-probe run folder (no `sap_gui_probe_run.json` / no `step_NN_action.json`). |
| `REPLAY_DIVERGED` | sap-user-guide | During `--with-screens` replay the live screen (program/dynpro) did not match the recorded sidecar — the walkthrough stops with partial captures + an honesty note, never a wrong-screen action or a false-complete guide. |

## Test replay (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `REPLAY_SCENARIO_INVALID` | sap-test-replay | The scenario failed lint — unbound token, missing guard, or a tcode/checkpoint-field that does not exist. Nothing is replayed. |
| `REPLAY_GUARD_MISMATCH` | sap-test-replay | After an action the screen identity (program/dynpro) did not reach the step's guard within the timeout — the replay broke, NOT a regression (distinct from a FAIL). |
| `REPLAY_UNEXPECTED_POPUP` | sap-test-replay | A `wnd[1]` popup appeared whose discriminator is not in the step's `popups[]` — the interpreter refuses to guess a disposition. |
| `REPLAY_CAPTURE_FAILED` | sap-test-replay | A message checkpoint's `MessageParameter` capture could not be read (GUI-patch variance) — the dependent later steps cannot run. |
| `REPLAY_ASSERT_FAILED` | sap-test-replay | A checkpoint (field/message/table) did not match — a scenario FAIL (a real regression), kept strictly distinct from the REPLAY_* "replay broke" classes. |

## Fiori FLP audit (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `FLP_NOT_PRESENT` | sap-fiori-flp-audit | `/UI2/PB_C_PAGE` is absent — not an FLP-enabled system (or spaces-only); a loud stop, never an empty-but-green audit. |
| `FLP_USER_NOT_FOUND` | sap-fiori-flp-audit | `user`/`full` target user does not exist (BAPI_USER + USR02 both empty). |
| `FLP_CONTENT_READ_DENIED` | sap-fiori-flp-audit | An AGR_*/USR02 read was authorization-denied — the affected area renders COULD_NOT_CHECK + Coverage=PARTIAL, never silently empty. (The /UI2 Page-Builder persistence being un-RFC-readable is a technical COULD_NOT_CHECK carried in the findings, not this class.) |
| `FLP_DATA_TRUNCATED` | sap-fiori-flp-audit | A paginated read hit `--max-rows` — the audit is marked PARTIAL rather than presented as complete. |

## Document flow (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `DOCFLOW_NOT_FOUND` | sap-doc-flow | The (ALPHA-padded) document key is in no SD header (VBAK/LIKP/VBRK all empty) — no chain produced. |
| `DOCFLOW_AMBIGUOUS_KEY` | sap-doc-flow | The same number exists as more than one category — interactive category prompt (or, in `--evidence-dir` reader mode, skipped-with-reason so /sap-diagnose does not block). |

## Data volume (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `DATAVOL_COUNT_FAILED` | sap-data-volume | `EM_GET_NUMBER_OF_ENTRIES` returned `-1` (table not found / count failed) for ≥1 in-scope table AND `--strict` is set — the row is tri-state COUNT_FAILED (never a fake 0); without `--strict` it is reported per-row and the run still succeeds. |
| `DATAVOL_PARSE_FAILED` | sap-data-volume | The `--physical` RSTABLESIZE spool could not be parsed into a physical size (layout differs by DB/release) — the physical column degrades to COULD_NOT_CHECK; only fails the run under `--strict`. |

## Cutover runbook (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `CUTOVER_PARSE_FAILED` | sap-cutover-runbook (init) | The runbook parse produced zero steps, or commit failed a structural check (duplicate ids, unresolved dependency, no checkpoint) — the plan is not written. |
| `CUTOVER_CURATION_PENDING` | sap-cutover-runbook (record/report/checkpoint) | An operational verb ran before `init --commit` — curation is a hard gate, not advice; nothing proceeds until the curated draft is committed. |
| `CUTOVER_LEDGER_NOT_FOUND` | sap-cutover-runbook | No committed `cutover.json` exists at `{artifact_dir}\cutover\<id>\` for the given cutover id. |
| `CUTOVER_STEP_UNKNOWN` | sap-cutover-runbook (record) | The step id (or event verb) is not in the committed plan — no event appended. |
| `CUTOVER_DEP_CYCLE` | sap-cutover-runbook (commit) | The step dependency graph contains a cycle — the offending edge is named; the plan is refused. |
| `CUTOVER_AUTO_NOT_ALLOWED` | sap-cutover-runbook (run, v2) | `run` was requested on a MANUAL / off-whitelist step or one whose `auto_ok` is not YES — auto-execution refused. |

## Docs estimate (sap-gen-code)

| Class | Emitted by | Meaning |
|---|---|---|
| `EST_INPUT_MISSING` | sap-docs-estimate (score/batch/ledger) | No scoreable inputs found in the work folder (or the triage/batch path is empty) — nothing estimated, no files written. |
| `EST_LEDGER_IO` | sap-docs-estimate (record-actuals) | The estimate ledger is unreadable/corrupt or the append failed — no silent state change. |
| `EST_ID_UNKNOWN` | sap-docs-estimate (record-actuals) | `record-actuals` referenced an `estimate_id` with no ESTIMATE row — refused, no orphan actual written. |
| `EST_CALIBRATION_INSUFFICIENT` | sap-docs-estimate (calibrate, v1.5) | Fewer than `--min-pairs` (default 8) ESTIMATE↔ACTUAL pairs — calibration refused with an explicit cold-start message; no fake multipliers. |

## Retrofit (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `RETRO_LEDGER_IO` | sap-retrofit | The retrofit workspace/ledger is missing or unreadable (`{work_dir}\retrofit\<project>\` not initialized, or a bad `--workspace`). |
| `RETRO_LEDGER_CONFLICT` | sap-retrofit (set-state) | A ledger state-machine violation — e.g. `apply`/`APPLIED` on a row that is not GREEN/APPROVED, or an unknown object/state. No transition applied. |
| `RETRO_CLASSIFY_INCOMPLETE` | sap-retrofit (classify) | An evidence source (VRSD/E071) or /sap-compare could not be read mid-classify — the row stays HARVESTED rather than get a guessed verdict (never a false GREEN). |
| `RETRO_APPLY_VERIFY_FAILED` | sap-retrofit (apply) | After deploying a GREEN object, the post-deploy /sap-compare re-check was not identical — the row is VERIFY_FAILED and the batch is marked FAILED, never silently green. |

## Wave-3 skills (sap-project + sap-dev-core)

| Class | Emitted by | Meaning |
|---|---|---|
| `NOTE_INPUT_INVALID` | sap-note-status | No/invalid note number (non-numeric or >10 digits) — nothing queried. |
| `NOTE_NO_RFC_PROFILE` | sap-note-status | No saved profile has an RFC password / all target systems unreachable — matrix cannot be built. |
| `WF_WI_NOT_FOUND` | sap-workflow (explain/act) | The workitem id does not exist in SWWWIHEAD. |
| `WF_ACT_INVALID_STATE` | sap-workflow (act) | The requested verb is refused for the WI's state (restart needs ERROR; cancel refused on COMPLETED/CANCELLED; forward needs a dialog WI + --to) — refused BEFORE the confirm prompt. |
| `WF_ACT_FAILED` | sap-workflow (act) | The WAPI call returned rc<>0, OR rc=0 but the authoritative SWWWIHEAD.WI_STAT re-read shows no change (never a false success). |
| `WF_DEFINITION_NOT_FOUND` | sap-workflow (explain) | No active SWDSHEADER version for the WS task. |
| `WF_INPUT` | sap-workflow | Invalid invocation input (unparseable workitem id / unknown verb / missing required argument) — refused before any RFC. |
| `AUTHREQ_SOURCE_UNREADABLE` | sap-auth-requirements (derive) | Object source could not be read over RFC (and no --source-files given). |
| `AUTHREQ_EXTRACT_FAILED` | sap-auth-requirements (derive) | The offline extractor produced no rows file. |
| `AUTHREQ_INPUT` | sap-auth-requirements | Invalid invocation input (no resolvable object token / bad arguments) — refused before any read. |
| `SM35_RFC_UNAVAILABLE` | sap-sm35 (list) | RFC down — session list cannot be read (no silent empty list). |
| `SM35_SESSION_NOT_FOUND` / `SM35_LOG_NOT_FOUND` / `SM35_PROCESS_TIMEOUT` / `SM35_RERUN_SOURCE_MISSING` | sap-sm35 | Session absent / no TemSe log / process poll exceeded --wait / rerun source BDC file absent (never reconstructs from APQD). |
| `SOST_SELECTION_EMPTY` / `SOST_RESEND_FAILED` | sap-sost (resend, v1.5) | Resend selection resolved to 0 rows / the GUI resend did not flip the status on re-read. |
| `IMG_LAYOUT_UNKNOWN` / `IMG_HARVEST_INCOMPLETE` / `IMG_CACHE_STALE` / `IMG_CACHE_MISSING` / `IMG_ACTIVITY_NOT_FOUND` / `IMG_LAUNCH_NO_TARGET` / `IMG_LAUNCH_FAILED` | sap-img-find | Harvest layout drift / core table 0 rows / cache older than TTL (WARN) / cache absent / activity not in cache / launch has no tcode+object (INFO) / launch nav failed. |
| `TRANSLATE_EMPTY_SCOPE` / `TRANSLATE_LENGTH_OVERFLOW` / `TRANSLATE_VERIFY_MISMATCH` / `LXE_WRITE_FAILED` | sap-translate | Empty scope / a proposed translation exceeds the hard length (refused) / post-write RFC re-read differs / the LXE write FM failed. |
| `TRANSLATE_INPUT` | sap-translate | Invalid invocation input (bad language argument / unparseable translation input file) — refused before any write. |
| `SE14_DELETE_PATH_REFUSED` / `SE14_CONVERSION_RUNNING` / `SE14_QCM_DATA_AT_RISK` / `SE14_UNSUPPORTED_TABCLASS` / `SE14_ADJUST_FAILED` / `SE14_SDATA_NOT_DEFAULT` | sap-se14 | Delete-data variant refused (v1 no override) / running conversion blocks writes / QCM shadow holds data on release-lock / non-TRANSP table / adjust GUI failed / save-data rail not confirmable (radRSGTB-SDATA missing or not `.Selected`) so adjust was refused. |
| `GW_NOT_INSTALLED` / `GW_BACKEND_ONLY` / `GW_SERVICE_NOT_FOUND` / `GW_ERRLOG_GUI_ONLY` | sap-gateway-service | No Gateway hub / hub is on another system (IW_BEP only) / unknown service / SU_ERRLOG is not RFC-readable so errors need the GUI scrape. |
| `SM30_NO_MAINT_DIALOG` / `SM30_TWO_STEP_UNSUPPORTED` / `SM30_CLUSTER_UNSUPPORTED` / `SM30_CLIENT_NOT_MODIFIABLE` / `SM30_DELETE_UNSUPPORTED` / `SM30_VERIFY_MISMATCH` / `SM30_NO_BASE_TABLE` / `PREREAD_UNFILTERED` | sap-sm30 | No TVDIR entry / two-step view (v1) / SM34 cluster / client locked / delete refused / post-write re-read delta / view has no base table / pre-read could not apply the view WHERE (WARN). |
| `SM30_TR_REQUIRED` / `SM30_KEY_NOT_FOUND` / `SM30_SAVE_FAILED` | sap-sm30 | The Customizing-TR popup (KO008-TRKORR) fired with no resolved TR (never blind-Enter'd — resolve a Customizing TR and retry) / update: the Position lookup found no row for the target key (no silent upsert) / Save ended with sbar `E`/`A` — rows not written. |
| `AUTH_CLIENT_NOT_MODIFIABLE` / `PFCG_ROLE_EXISTS` / `PFCG_VERIFY_MISMATCH` / `PFCG_GENERATE_FAILED` / `PFCG_NEEDS_RECORDING` | sap-pfcg | Client locked / create on an existing role / AGR_* re-read delta / SUPC left 0 auth rows / unknown PFCG/SUPC layout (never guess-click). |

`NEEDS_RECORDING` (reused) covers the ships-unrecorded GUI legs of sap-sm35 (log scrape), sap-sost
(resend), sap-img-find (SM30/SM34 launch), sap-translate (SE63), sap-se14 (adjust/unlock),
sap-gateway-service (errors --deep), sap-sm30 (table-control), and sap-pfcg (create/menu/generate)
until captured via `/sap-gui-probe --record`.

Registered consumers: `/sap-log-analyze` (Top error_class section),
`sap_error_hints.ps1 -Action record` (auto-record attribution), customer
dashboards reading `{log_dir}` JSONL. See the Logging Settings section in the
repo CLAUDE.md for record shape and rotation.
