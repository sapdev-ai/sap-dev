# Test Plan: {DOC_NAME}

<!--
Canonical section layout for /sap-gen-test-plan. Claude fills this from the
derived model. The xlsx render (anthropic-skills:xlsx) mirrors these six
sections as sheets: Cover, Test Cases, Traceability, Test Data, Message
Coverage, Coverage Summary. Keep the headings stable — the xlsx builder keys
sheet names off them.
-->

## 1. Cover

| Field | Value |
|---|---|
| Object / spec | {OBJECT_OR_DOC} |
| Source mode | {from-spec \| from-dossier} |
| System (validate) | {SID}/{CLIENT} or "offline" |
| Generated | {DATE} |
| Verdict | {OK \| WARN} |

## 2. Test Cases

One row per case. `Provenance` = CONFIRMED (spec-traceable) or INFERRED
(model-derived). `Validate` = VERIFIED / MISMATCH / COULD_NOT_CHECK for the
SAP fact this case's expected message references (blank offline).

| TC ID | Scenario | Type (pos/neg/boundary) | Preconditions | Steps | Test Data | Expected Result | Provenance | Validate |
|---|---|---|---|---|---|---|---|---|
| TC-001 | ... | ... | ... | ... | ... | ... | CONFIRMED | VERIFIED |

## 3. Traceability Matrix (case <-> step <-> rule <-> message)

| TC ID | PROCESS step(s) | VALIDATION rule(s) | Message(s) | Golden row |
|---|---|---|---|---|
| TC-001 | S1 | - | - | G-01 |

**UNCOVERED steps:** {list PROCESS steps with no case, or "none"}
**UNMAPPED messages:** {list messages with no provoking case, or "none"}

## 4. Test Data Prerequisites

| Table | Purpose | Key template | Rows needed | Source |
|---|---|---|---|---|
| MARA | material master | MATNR | 1 finished good | /sap-mm01 |

## 5. Message Coverage

Every spec message and the case(s) that provoke it. `Live status` from --validate.

| Msg (class/no) | Text | Provoked by | Live status |
|---|---|---|---|
| ZMM 010 | ... | TC-004 | VERIFIED |

## 6. Coverage Summary

- Cases: {n} total ({c} CONFIRMED, {i} INFERRED)
- PROCESS steps: {covered}/{total} covered
- Messages: {mapped}/{total} mapped ({unmapped} unmapped)
- Validate: {verified} VERIFIED, {mismatch} MISMATCH, {cnc} COULD_NOT_CHECK
- **Verdict: {OK \| WARN}** — WARN when any message is unmapped, any step
  uncovered, or any fact COULD_NOT_CHECK / MISMATCH.

Suggested next steps: `/sap-gen-abap` MODE_UNIT_TESTS for the unit-level half;
manual review of every INFERRED row; resolve UNMAPPED/UNCOVERED before sign-off.
