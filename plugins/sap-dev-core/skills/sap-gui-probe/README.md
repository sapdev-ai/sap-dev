# sap-gui-probe

Drive a SAP transaction step by step against a natural-language scenario,
dump every screen via the sap-gui-inspect engine, and emit a single
replayable VBS at the end.

## When to reach for it

You're about to author or rewrite a transaction-specific skill
(`/sap-se37`, `/sap-mm03`, `/sap-mb1c`, ...) and you need to know:

- The exact `findById` paths for every input and button in the target flow
- The full property set of each control (`Changeable`, `Tooltip`, `IconName`)
  -- the SAP recorder does **not** capture these
- The screen identity (program / dynpro / title) at every transition
- Which popups appear, and in what order

Compared to siblings:

| Skill | Drives the GUI? | Captures properties? | Multi-screen? |
|---|---|---|---|
| `sap-gui-record` | no (user clicks) | no | yes |
| `sap-gui-inspect` | no | yes (structural + visual) | no (single screen) |
| **`sap-gui-probe`** | **yes** | **yes** | **yes** |

## Quick start

Make sure SAP GUI is logged in on the target session:

```
/sap-login
```

Then probe a transaction flow with a natural-language scenario:

```
/sap-gui-probe "SE37: display FM RFC_READ_TABLE; then F3 back to Easy Access"
```

Output lands in `{work_dir}\probes\SE37_<timestamp>\` -- per-step
before/after dumps, per-step action JSON, and a consolidated
`synthesized.vbs` you can replay or use as a starting template.

## Safety

Default mode is `confirm`: read-only actions (Enter, F3, F4, navigation,
field text entry) auto-proceed; any write action (Save / Activate / Delete
buttons or the matching VKey codes 11 / 14 / 27 / 28 / 33) pauses for an
explicit `Proceed` / `Abort` choice.

Append `--auto` anywhere in the scenario to skip prompts:

```
/sap-gui-probe "SE38: open ZSANDBOX, syntax check, activate, exit --auto"
```

Even in auto mode the safety classifier still runs -- every WRITE action is
tagged in the per-step JSON so the end-of-run report can surface what
mutated. See the skill SKILL.md "Edge cases and gotchas" section for the
non-obvious cases (table-row checkboxes, AbapEditor status-bar swallowing,
SAPLSETX master-language popups).

## See also

- `/sap-gui-inspect` -- the underlying dump/screenshot engine (reused verbatim)
- `--record <vbs>` -- capture the flow by hand with the SAP Script Recorder instead of driving it (Mode R; replaces the retired `/sap-gui-record`)
