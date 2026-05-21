# sap-gui-skill-scaffold

Author a new transaction-specific SAP skill from a small set of
natural-language scenarios. Runs `/sap-gui-probe` for each scenario, then
merges the probe folders into one coherent skill folder by cross-probe diff.

## When to reach for it

You want a new `/sap-mm03` (or `/sap-va02`, or whatever) that handles the
multiple routes / data states that real users hit -- display existing, display
missing, change with org levels, delete -- and you don't want to author the
SKILL.md + per-mode VBS files by hand.

Compared to siblings in the `sap-gui-*` family:

| Skill | Drives the GUI? | Output |
|---|---|---|
| `sap-gui-record` | no (user clicks) | one .vbs from one recording |
| `sap-gui-object-details` | no | dump of one screen |
| `sap-gui-diagnose` | no | screenshot of stuck screen |
| `sap-gui-probe` | yes | one probe folder (per-step dumps + synthesized.vbs) |
| **`sap-gui-skill-scaffold`** | **yes, multiple times** | **a complete skill folder** merged from N probes |

## Quick start

Log in once, then scaffold:

```
/sap-login
/sap-gui-skill-scaffold sap-mm03-mini \
  --scenario "MM03: display ZHKAMATVer7001 Basic Data 1 then exit" \
  --scenario "MM03: display ZNONEXISTENT (expect not-found error) then exit"
```

Output lands in `{work_dir}\skill_scaffolds\sap-mm03-mini_<timestamp>\`:

- `SKILL.md` -- mode dispatch (display vs. not-found), parameter hints
- `references\sap_sap-mm03-mini_display.vbs` -- replays the happy path with `%%MATNR%%` parameter
- `references\sap_sap-mm03-mini_not-found.vbs` -- replays the error path with `%%MATNR%%` parameter, popup-branch guard
- `_merge_report.json` -- full provenance
- `_source_probes\INDEX.txt` -- which probe folder informed which mode

Copy the folder into a plugin's `skills/` dir, register in `marketplace.json`,
and the skill is callable.

## Goal mode (`--goal`)

Instead of enumerating scenarios, hand it a one-line goal and let it imagine the
scenario set:

```
/sap-gui-skill-scaffold sap-se11-domain --goal "use SE11 to create a domain"
```

What happens (fully autonomous up to your final acceptance test):

1. **Imagine (Step 0.9).** The transaction + object type are derived from the
   goal / skill name, then `references/scenario_catalog.tsv` is consulted for the
   known stuck-points of that `txn`/`object_type`. The scaffolder brainstorms
   **1 happy-path + up to 4 failure-mode** scenarios (mapped to the 5-state
   taxonomy: `success` / `not_found` / `auth_error` / `popup_recovery` /
   `validation_error`), seeded by traps that real test runs already discovered.
2. **Probe → merge → emit** exactly as in scenario mode.
3. **Test + fix (Step 5.5).** Each generated mode is run against SAP with minted
   throwaway objects, classified pass/fail (status-bar `MessageType` + a
   post-create RFC verify), and the fixable failures (missing popup guard, drifted
   control id, missing token, missing enhancement-category step, …) are auto-fixed
   in the DRAFT and re-run — up to 3 iterations per mode. Test fixtures are then
   deleted; a report lands in `sap-dev/temp/testReport/`.
4. **You** run the final acceptance test before installing/releasing.

Flags: `--no-test` stops at the draft; `--test-budget-min N` widens the test
budget (default 20 min). The catalog grows over time — when a probe hits a trap
the catalog didn't predict, Step 5 surfaces a `CATALOG-CANDIDATE` row for you to
hand-add.

The catalog is the natural granularity for these skills: per-object-type
(`sap-se11-domain`, `sap-se11-table`, …) because DDIC object types share almost
no screen touchpoints. Lean on the existing shared helpers so the generated
skills stay thin.

## Cross-probe diff

The technical core is `references/merge_probes.ps1`. For every unique
`(verb, target)` control touchpoint across probes:

- **All probes hit it with the same value** -> constant, baked into VBS literally
- **All probes hit it with different values** -> parameter, becomes `%%TOKEN%%` (token name derived from DDIC field tail)
- **Only some probes hit it** -> mode-specific, only goes into those modes' VBS

Popups observed in any probe become `If IsPopupOpen(oSess) Then ...` guards
in *every* mode's VBS at the matching step -- because if a popup can appear
under one set of inputs, it might appear under another, and the generated
skill should be defensive.

## Safety

- Step 2 invokes `/sap-gui-probe` with `--auto` for each scenario. Write
  actions (Save / Activate / Delete) run without per-step confirmation. The
  whole authorisation is the act of typing the scenarios.
- If any probe fails mid-pipeline, the scaffolder aborts cleanly. No
  half-merged output.
- Refuses scenarios < 2 (single-probe scaffolding is just `synthesized.vbs`).

## What still needs human review

The generated skill is a **ready-to-test draft**, not a finished skill. The
"Notes for the human editor" section at the bottom of the generated
`SKILL.md` enumerates what's left: description polish, argument-hint
refinement, popup-branch recovery logic (every popup TODO gets a default
"Continue" action -- wrong for Delete confirmations), TR / ATC / customer-brief
alignment.

## See also

- `/sap-gui-probe` -- the per-scenario driver this skill orchestrates
- `/sap-gui-object-details` -- the dump engine probe uses
