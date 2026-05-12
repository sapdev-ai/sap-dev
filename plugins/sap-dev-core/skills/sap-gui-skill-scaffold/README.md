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
