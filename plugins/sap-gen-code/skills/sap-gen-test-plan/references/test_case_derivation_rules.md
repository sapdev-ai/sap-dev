# Test-Case Derivation Rules (read by Claude in Step 3)

The checklist that turns a parsed spec model (or an /sap-explain-object dossier)
into functional test cases. This is the generation analog of
`abap_code_quality_rules.md` — deterministic where it can be, explicit about
where model judgement fills a gap. Follow it in order; every case carries a
`provenance` value and every rule/message is accounted for.

## Provenance (assign to every case)

| Value | When |
|---|---|
| `CONFIRMED` | Directly traceable to a spec row — an imported golden-test row, a validation rule, or an explicit PROCESS step. |
| `INFERRED` | Model-derived — a boundary/edge case, a negative case not spelled out in the spec, an environment permutation. |

The `--validate` pass adds a SECOND, independent axis per referenced SAP fact
(message / table / tcode / FM): `VERIFIED | MISMATCH | COULD_NOT_CHECK`. Never
collapse the two — a case can be `CONFIRMED` (spec-traceable) yet reference a
message that is `MISMATCH` (wrong on the live system). Both surface.

## Derivation steps

1. **Import golden rows verbatim (CONFIRMED).** Each `_golden.txt` row
   (`TEST_ID, SCENARIO, INPUTS, EXPECTED, NOTES`) becomes one case, keeping its
   own id as an alias. Never rewrite the expected result — it is the oracle.

2. **One positive case per PROCESS step (CONFIRMED).** For each `# === PROCESS ===`
   row (`STEP, ACTION, NOTES`) emit at least one case whose steps exercise that
   action on the happy path. A step already fully covered by a golden row may
   reference that row instead of duplicating it (note the coverage; do not drop
   the step).

3. **Exactly one negative case per VALIDATION rule (CONFIRMED).** For each
   `# === VALIDATION ===` row (`NO, FIELD, RULE, ERR_MSG_REF`) emit one case that
   violates the rule and asserts `ERR_MSG_REF` as the expected result. This is the
   load-bearing discipline: a validation rule with no provoking case is a hole.

4. **Boundary cases per selection field (INFERRED).** For each
   `_selection_definition.txt` field, add the applicable boundary cases: empty,
   single value, interval, pattern/wildcard, max length, and (for numeric/date)
   min/max/overflow. Only the boundaries that make sense for the field's type.

5. **Model-derived edge cases (INFERRED).** Cross-field contradictions, duplicate
   keys, authorization-absent, empty result set, and concurrency where the spec's
   process implies them. Keep these few and defensible — do not pad.

## Message-mapping discipline (the core invariant)

- Every `_errorMsgs.txt` / `_interface.txt` message MUST be the expected result of
  at least one provoking case.
- A message you cannot tie to any plausible provoking rule/step is NOT dropped —
  it lands in the `UNMAPPED MESSAGES` section and downgrades the plan verdict to
  WARN. Guessing a provoking case for it is worse than admitting the gap.
- A validation rule whose `ERR_MSG_REF` is blank is reported in `UNCOVERED` —
  the spec is incomplete, say so.

## Traceability

Build the case <-> step <-> rule <-> message matrix as you derive (not after).
Each case links to the step(s) it covers, the rule it violates (negative cases),
and the message(s) it expects. `UNCOVERED steps` = PROCESS steps with no case;
`UNMAPPED messages` = messages with no case. Both are rendered, never hidden.

## Test-data prerequisites

From golden `INPUTS`, `_tables.txt` + `table_data_*.txt`, and (dossier mode)
map.json `db_reads`, list the master/config data each case needs: table, purpose,
the key template (from `--validate` DD03L key fields when available), rows needed,
and a source (`/sap-bp`, `/sap-mm01`, existing config, ...). A prerequisite you
cannot source is a WARN, not a silent omission.

## Anti-padding rule

Coverage honesty beats case count. An empty/weak spec yields few CONFIRMED cases
and visible UNCOVERED rows — that is the correct output. Never invent filler
cases to make a matrix look full; the coverage summary must reflect the spec's
real state.
