# <PATTERN_ID> — <Title>

- **pattern_id:** <PATTERN_ID>   (MUST match the `catalog.tsv` key, and is the value `/sap-cc-triage` writes into `findings_triaged.tsv.pattern`)
- **category:** <FIELD_LENGTH|DATA_MODEL|HANA|API_REMOVED|SYNTAX|FUNCTIONAL>
- **tier:** <R1|R2|R3|R4>   **confidence_default:** <AUTO_OK|AI_REVIEW|MANUAL_ONLY>
- **simplification item:** <S4TWL item name, or blank for behavioral patterns>
- **status:** <ACTIVE|DRAFT|DEPRECATED>   **applies modules:** <FI|MM|SD|CROSS|...>

## Summary
What changed and why — one short paragraph.

## Applies when
- ATC simplification item / message id(s) that map here, and/or
- code signature(s) (mirror `catalog.tsv` `detect_code_regex`).
- Modules.

## Old → New mapping
Point at `object_map.tsv` / `field_map.tsv` rows for this `pattern_id`; summarize
in a small table. Behavioral patterns: write "None — behavioral fix".

## Remediation approach
1. Step-by-step transformation the AI follows.
2. Which released API / view to use (from `api_replacements.tsv`).
3. What NOT to do (anti-patterns) and when to escalate to MANUAL.

## Released APIs / objects
List from `api_replacements.tsv` (this `pattern_id`).

## Caveats & non-1:1 cases (when to downgrade to MANUAL_ONLY)
- ...

## Before / After example
```abap
" before
```
```abap
" after
```

## Validation
- ABAP Unit assertion(s) to generate; the ATC finding that must clear.

## Confidence & gating
- Default fixability; when human sign-off is mandatory.

## Sources (provenance — reference only)
- Cite the SAP simplification item / note for reference. Do NOT paste SAP's
  Simplification Database content. Verify names against the target release.
