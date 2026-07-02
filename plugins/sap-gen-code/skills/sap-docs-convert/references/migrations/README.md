# schema_migration transformation specs

This directory holds the pluggable transformation specs behind the
`schema_migration` rule category of `/sap-docs-convert` (see SKILL.md
Step 4).

## How the mechanism works

1. A `schema_migration` row in `spec_conversion_rules.tsv` names a
   migration, e.g.:

   ```tsv
   schema_migration	LEGACY_HK_V1	CUSTOMER_BRIEF		see notes
   ```

2. When `/sap-docs-convert` applies that rule, it looks for the
   step-by-step transformation spec at:

   ```
   references/migrations/<FROM-name>.md      e.g. references/migrations/LEGACY_HK_V1.md
   ```

3. If the doc exists, the skill follows its steps to transform the
   extracted `_*.txt` files from the legacy layout into the Customer
   Brief layout.

4. **If the doc does NOT exist** (the normal case — see below), the skill
   logs a WARNING naming the missing migration and SKIPS the rule. It
   never guesses a transformation.

## What ships with the plugin

**No migration docs ship with the plugin — this README is the only file
here.** Legacy-layout migrations are inherently customer-specific, so
each one is authored per project:

- Write a `<NAME>.md` describing, step by step, how each affected
  `_*.txt` file's columns/sections map from the legacy layout to the
  Customer Brief layout (input file, column order before/after, value
  transformations, rows to drop).
- Drop it in this directory (or ship it with your `{custom_url}` rules
  and copy it here during onboarding).
- Reference its name in the `FROM` column of a `schema_migration` row in
  `spec_conversion_rules.tsv`.

Until such a doc exists, `schema_migration` rows are inert
(WARNING + skip) — the other three rule categories (`field_rename`,
`type_rename`, `flag_mapping`) are unaffected.
