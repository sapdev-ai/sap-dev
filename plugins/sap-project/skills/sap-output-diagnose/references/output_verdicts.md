# Output-diagnosis verdict vocabulary (maintainer reference)

The two engines emit these tokens; `SKILL.md` ranks them into the human verdict.

## NAST status (stage 2, `sap_output_nast_read.ps1`)

| Token | VSTAT | Meaning | Typical action |
|---|---|---|---|
| `ISSUED_OK` | 1 | Output was processed successfully | Name the print program/form (TNAPR); nothing wrong |
| `PROCESSING_FAILED` | 2 | Output was determined but processing failed | Read the CMFP (WFMC) log excerpt; fix the cause, then `reissue` |
| `NOT_YET_PROCESSED` | 0 | Determined, not yet dispatched | Check dispatch time (VSZTP=1 → batch → is RSNAST00 job running?) |

## Determination walk (stages 4-7, `sap_output_walk.ps1`)

| Verdict | Meaning | Ranking |
|---|---|---|
| `NO_RECORD` | No condition record for the exact rebuilt key across all accesses of an output type — the output was never determined | **highest** (the usual root cause of "no output") |
| `RECORD_EXISTS` | A condition record DID match — determination succeeds; the problem is downstream (processing failed / not yet processed / manually deleted). A matched record WINS over the requirement flag; `requirement=true` is carried as a modifier | routes back to the NAST status |
| `REQUIREMENT_BLOCKED` | **SKILL.md synthesis, not a raw walk verdict**: the walk reports `RECORD_EXISTS requirement=true` but the NAST row is absent → the requirement routine (T683S-KOBED≠0, `RV61B<nnn>`) suppressed the output despite the record. The routine is named, never evaluated locally | high |
| `MANUAL_ONLY` | The output type has no access sequence (T685-KOZGF empty) — it can only be added manually | informational |
| `COULD_NOT_CHECK` | An access key field could not be rebuilt from the document, or a B-table / table was unreadable | never rendered as NO_RECORD |
| `NOT_IN_PROCEDURE` | A `--type` was requested that is not a step of the resolved procedure | informational |

## Disclosures

| Token | Meaning |
|---|---|
| `BRF_PLUS_OM present` | S/4 Output Management (BRF+) framework exists (APOC_D_OR_ROOT) — if this document is OM-managed, the NAST verdict is **not complete**; the verdict is capped at GO_WITH_WARNINGS |
| `SKIPPED_ECC` | BRF+ stage skipped (ECC — APOC_D_OR_ROOT absent) — expected, not an error |

## Verdict ranking for the human story

`NO_RECORD` > `REQUIREMENT_BLOCKED` > `PROCESSING_FAILED` > `NOT_YET_PROCESSED` >
`MANUAL_ONLY` > `RECORD_EXISTS`(as "determination OK") ; a `BRF_PLUS_OM` disclosure is
prepended and caps the overall verdict at GO_WITH_WARNINGS. Any `COULD_NOT_CHECK`
downgrades a clean verdict (honesty contract).
