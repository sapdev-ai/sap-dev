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
| `TR_RESOLUTION_FAILED` | deploy skills' Step 1b (`/sap-transport-request` delegation) | No modifiable transport request could be resolved under the active `way_to_get_transport_request` policy. |
| `TR_NOT_MODIFIABLE` | reserved (canonical name; use for a supplied TR that exists but is released/foreign) | The named TR cannot take new objects. |
| `GUI_TIMEOUT` | reserved (canonical name for GUI-scripting stalls) | A GUI-scripting wait loop exhausted its budget (screen never arrived, modal never closed). |
| `OBJECT_NOT_FOUND` | sap-explain-object, sap-impact-analysis, sap-review-abap | The named repository object does not resolve on the target system (TADIR/TFDIR probe empty). |
| `SCREEN_DRIFT` | sap-doctor (`--screens`) | A golden-screen baseline checkpoint no longer matches the live screen (release/locale moved a control). |
| `SE38_CHECK_FAILED` | sap-se38 | Program existence/syntax pre-check failed before deploy. |

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

Registered consumers: `/sap-log-analyze` (Top error_class section),
`sap_error_hints.ps1 -Action record` (auto-record attribution), customer
dashboards reading `{log_dir}` JSONL. See the Logging Settings section in the
repo CLAUDE.md for record shape and rotation.
