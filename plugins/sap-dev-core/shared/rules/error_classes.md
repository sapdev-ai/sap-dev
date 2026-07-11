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

## Version history (`/sap-version-history`)

| Class | Meaning |
|---|---|
| `VH_NO_VERSIONS` | The object's version store is empty (versions are written only on release/generation, so a freshly built object legitimately has none) — reported honestly, never rendered as "no differences". |
| `VH_VERSION_NOT_FOUND` | A requested `VERSNO` is not in the version store (out of range) — `SVRS_GET_REPS_FROM_OBJECT` returned no source for it. |
| `VH_TYPE_UNSUPPORTED` | The resolved object is a class / interface — per-include class versioning is v2; v1 supports programs / includes / function modules only. |

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

## Document flow (sap-project)

| Class | Emitted by | Meaning |
|---|---|---|
| `DOCFLOW_NOT_FOUND` | sap-doc-flow | The (ALPHA-padded) document key is in no SD header (VBAK/LIKP/VBRK all empty) — no chain produced. |
| `DOCFLOW_AMBIGUOUS_KEY` | sap-doc-flow | The same number exists as more than one category — interactive category prompt (or, in `--evidence-dir` reader mode, skipped-with-reason so /sap-diagnose does not block). |

Registered consumers: `/sap-log-analyze` (Top error_class section),
`sap_error_hints.ps1 -Action record` (auto-record attribution), customer
dashboards reading `{log_dir}` JSONL. See the Logging Settings section in the
repo CLAUDE.md for record shape and rotation.
