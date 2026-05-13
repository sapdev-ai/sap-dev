---
name: sap-gui-skill-scaffold
description: |
  Author a new transaction-specific SAP skill from multiple natural-language
  scenarios. Runs /sap-gui-probe for each scenario, then merges the resulting
  probe folders into one coherent skill folder: SKILL.md with mode dispatch,
  one references/sap_<name>_<mode>.vbs per probe, parameter tokens derived
  by cross-probe diff (values that vary across probes become %%TOKEN%%;
  values that stay constant bake in), popup-branch guards at every step where
  any probe observed a wnd[1] popup. Output is a ready-to-test draft.
  Prerequisites: active SAP GUI session (use /sap-login first).
argument-hint: "<new-skill-name> --scenario \"...\" --scenario \"...\" [...]   or  <name> --manifest <path>"
---

# SAP GUI Skill Scaffold

You author a new transaction-specific SAP skill from a small set of
natural-language scenarios. Each scenario is probed via /sap-gui-probe; the
resulting probe folders are merged by cross-probe diff to identify parameters
(values that vary) vs. constants (values that stay the same). The output is
a scaffolded skill folder under `{work_dir}\skill_scaffolds\<name>_<ts>\`.

Task: $ARGUMENTS

---

## Step 0 — Resolve work directory + scaffold folder

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field. Resolve sap-dev-core paths: 2 levels up from `<SKILL_DIR>`, then `settings.json` and (if present) `settings.local.json`. Read `work_dir`. Default: `C:\sap_dev_work`.

Derive:
- `{WORK_TEMP}`       = `{work_dir}\temp`
- `{TS}`              = current timestamp `yyyyMMdd-HHmmss`
- Parse new skill name + scenarios from `$ARGUMENTS` (see Step 1).
- `{SCAFFOLD_FOLDER}` = `{work_dir}\skill_scaffolds\<new-skill-name>_<TS>`

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
cmd /c if not exist "{SCAFFOLD_FOLDER}" mkdir "{SCAFFOLD_FOLDER}"
```

---

## Step 0.5 — Start logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{SCAFFOLD_FOLDER}\sap_gui_skill_scaffold_run.json" -Skill sap-gui-skill-scaffold -ParamsJson "{\"new_skill\":\"<name>\",\"scenario_count\":\"<N>\"}"
```

The probe runs invoked in Step 2 inherit this run as their parent via the
`SAPDEV_PARENT_RUN_ID` env var, so `/sap-log-analyze` can reconstruct the
scaffold → probe call tree.

---

## Step 0.7 — Pre-flight: GUI session

```bash
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```

If status is not `LOGGED_IN`, stop and tell the user to run `/sap-login` first.
Log end Status=FAILED ErrorClass=NO_SESSION.

---

## Step 1 — Parse arguments

`$ARGUMENTS` shape:

```
<new-skill-name> --scenario "<s1>" --scenario "<s2>" ...
<new-skill-name> --manifest <path-to-manifest.txt>
<new-skill-name> --scenario "<s1>" ... --force-overwrite
```

Parse rules:

1. **First positional arg** = the new skill name. Must match `^sap-[a-z0-9-]+$`
   (CLAUDE.md naming convention). Reject otherwise.
2. **`--manifest <path>`**: UTF-8 file, one scenario per line, blank lines and
   `#`-prefixed lines ignored. Read and treat as if each was `--scenario "..."`.
3. **`--scenario "..."`** (repeatable): collect into an ordered list.
4. **`--force-overwrite`** (optional): if a skill folder with this name
   already exists inside any installed plugin's `skills/` dir, snapshot the
   old folder under `{SCAFFOLD_FOLDER}\.scaffold-overlay\` before generating.
   Without this flag, refuse with a clear message.
5. **Optional `--tcd <TXN>`**: informational tag for the SKILL.md header. If
   omitted, derive from the first scenario via the same TXN-extraction
   heuristic /sap-gui-probe uses.

After parsing:
- If scenario count < 2, refuse with: *"scaffolding from one probe is just
  synthesized.vbs -- use that directly via /sap-gui-probe"*. Log end
  Status=SKIPPED.
- Derive a mode name per scenario by parsing for action-verb keywords. Use
  this lookup table; first match wins, scan in order:

  | Keyword regex (case-insensitive) | Mode label |
  |---|---|
  | `\bnot[ _-]?found\b\|missing\|nonexistent` | `not-found` |
  | `\bdisplay\b\|show\|view\b` | `display` |
  | `\bcreate\b\|new\b\|add\b` | `create` |
  | `\bchange\b\|update\|modify\|edit\b` | `change` |
  | `\bdelete\b\|drop\|remove\b` | `delete` |
  | `\bcheck\b\|syntax\b` | `check` |
  | `\bactivate\b` | `activate` |
  | `\bwhere[ _-]?used\b\|usages?\b` | `where-used` |
  | `\bcopy\b\|clone\b` | `copy` |
  | `\brename\b` | `rename` |

  If no keyword matches, fall back to `mode_NN` (NN = scenario index, 1-based).
  Two scenarios producing the same mode label (both "display") get
  de-duplicated -- both contribute their actions to a single merged mode.

Echo the parsed plan to the user before Step 2:

> Scaffolding **<new-skill-name>** from N scenario(s):
> 1. mode=`display` -- "<scenario 1 verbatim>"
> 2. mode=`delete` -- "<scenario 2 verbatim>"
> ...
> Output folder: `<SCAFFOLD_FOLDER>`

---

## Step 2 — Run /sap-gui-probe for each scenario

Use the Skill tool to invoke `/sap-gui-probe` with each scenario, in order.
Always append `--auto` to the scenario string -- the scaffolder is
non-interactive; the human authorised this whole run by typing the scenarios.
After each probe, capture the resulting run folder path from the probe's
final report and append to your in-memory probe list:

```
[
  { "scenario": "<s1>", "mode": "display",  "folder": "{work_dir}\\probes\\SE37_20260512-200000" },
  { "scenario": "<s2>", "mode": "delete",   "folder": "{work_dir}\\probes\\SE37_20260512-200430" },
  ...
]
```

If any probe ends with status FAILED or ABANDONED, **stop the scaffold here**.
Log end Status=FAILED ErrorClass=PROBE_FAILED ErrorMsg="<scenario index>".
The failed probe's run folder is still on disk for the user to inspect; the
partial probes that succeeded are also kept. Do NOT proceed to merge --
a partial scaffold is worse than no scaffold.

---

## Step 3 — Cross-probe merge

Once every probe succeeded:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\merge_probes.ps1" -ProbeFolders <folder1>,<folder2>,... -ModeNames <mode1>,<mode2>,... -OutputFile "{SCAFFOLD_FOLDER}\_merge_report.json"
```

The script reads every `step_NN_action.json` across all probe folders, groups
by `(verb, target)` touchpoint, classifies each as:

- **constant** -- appears in all probes with identical value -> bakes into VBS
- **parameter** -- appears in all probes with varying value -> becomes a
  `%%TOKEN%%` placeholder (token name derived from the DDIC field tail of
  the target, e.g. `%%MATNR%%` from `wnd[0]/usr/ctxtRMMG1-MATNR`)
- **mode-specific** -- appears in only some probes -> goes only into the
  mode VBS files for the modes that used it

It also collects every popup observed in any probe (read from the
`POPUP WINDOW wnd[1]` marker in each step's `_after.txt` dump). Output is
`_merge_report.json` in the scaffold folder.

Last line of stdout: `MERGE OK: probes=<N> touchpoints=<M> parameters=<P> modeSpecific=<MS> popups=<X>`.

---

## Step 4 — Emit the skill folder

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\emit_skill_folder.ps1" -MergeReport "{SCAFFOLD_FOLDER}\_merge_report.json" -SkillName "<new-skill-name>" -OutputDir "{SCAFFOLD_FOLDER}" -Tcd "<TXN>"
```

The script reads the merge report and writes, into `{SCAFFOLD_FOLDER}`:

- `SKILL.md` -- mode dispatch, derived from `references\skill_md.template`
- `README.md` -- short doc with provenance
- `references\sap_<name>_<mode>.vbs` -- one per distinct mode, derived from
  `references\mode_vbs.template`. Each VBS:
  - Attaches to the active SAP GUI session
  - Replays the probe's actions in order
  - Inserts a popup-branch guard (`If IsPopupOpen(oSess) Then ...`) at every
    step where any probe observed a wnd[1] popup
  - Reads the status bar's `MessageType` at the end (per the language
    independence rules) and exits with ERROR if `E` or `A`
- `_source_probes\INDEX.txt` -- provenance (which probe folder informed which mode)
- `_merge_report.json` -- full provenance for downstream tools

Last line of stdout: `EMIT OK: <SCAFFOLD_FOLDER>`.

---

## Step 5 — Self-review

Read the generated `SKILL.md` and each `references\sap_<name>_<mode>.vbs`.
Surface to the user any obvious gaps:

1. **TODO markers** -- any line containing `TODO (human review)`. The popup
   branch guards always emit a TODO so the human chooses dismiss / accept /
   abort logic.
2. **Language-dependent literals** -- the `language_independence_rules.md`
   says: no `.Text =` comparisons, no `.Tooltip =` branches, no `InStr` on
   localized text. Grep each generated VBS for these patterns and flag.
3. **Missing parameter validation** -- the generated SKILL.md does not
   validate that the user passed each required parameter; that's left to the
   human author.
4. **Mode collisions** -- if two scenarios produced the same mode label (e.g.,
   both "display"), confirm to the user that the de-dup was intentional and
   the resulting single VBS covers both scenarios' actions.

Output a concise findings list; do not modify the generated files.

---

## Step 6 — Cleanup and install hint

Best-effort return SAP GUI to Easy Access (in case Step 2 left the session
mid-flow on the last probe's end state):

```bash
echo {"verb":"SET_OKCD","value":"/n","note":"scaffolder cleanup"} > "{WORK_TEMP}\scaffold_cleanup.json"
cmd /c C:\Windows\SysWOW64\cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-gui-probe\references\sap_gui_probe_action.vbs" "{WORK_TEMP}\scaffold_cleanup.json"
```

Tell the user how to install the generated skill into a plugin:

> The scaffolded skill is at `{SCAFFOLD_FOLDER}`. To install:
> 1. Copy the folder into a plugin's `skills/` directory:
>    `cp -r <SCAFFOLD_FOLDER> <repo>/sap-dev/plugins/<plugin-name>/skills/<new-skill-name>`
> 2. Register in `<repo>/sap-dev/.claude-plugin/marketplace.json` (add to the
>    plugin's `"skills"` array, increment `metadata.total_skills`).
> 3. Run `node sap-dev/scripts/check-consistency.mjs` to verify.
> 4. Reload the plugin (`/plugin install ...`) and test the smoke flow per
>    each source probe's scenario.

---

## Final — Log end

On success:
```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{SCAFFOLD_FOLDER}\sap_gui_skill_scaffold_run.json" -Status SUCCESS -ExitCode 0
```

Suggested ErrorClass on failure: `PROBE_FAILED`, `MERGE_FAILED`,
`EMIT_FAILED`, `NO_SESSION`, `BAD_SKILL_NAME`, `INSUFFICIENT_SCENARIOS`.

---

## Recipes

**Two-mode SE37 skill (display + delete):**
```
/sap-gui-skill-scaffold sap-se37-mini \
  --scenario "SE37: display FM RFC_READ_TABLE then exit" \
  --scenario "SE37: delete FM Z_SANDBOX_FM"
```

**MM03 with three routes via manifest:**
```
/sap-gui-skill-scaffold sap-mm03-display --manifest mm03_routes.txt
```
where `mm03_routes.txt` contains:
```
# happy path
MM03: display material ZHKAMATVer7001 Basic Data 1 then exit
# error path
MM03: display material ZNONEXISTENT (expect not-found error) then exit
# multi-view path
MM03: display material ZHKAMATVer7001 Sales Org 1 + Plant Data then exit
```

**Overwrite an existing scaffold:**
```
/sap-gui-skill-scaffold sap-se37-mini --manifest se37.txt --force-overwrite
```

---

## Edge cases and gotchas

1. **Scenarios must produce reachable end states.** /sap-gui-probe has a
   30-step hard cap. If a scenario can't complete in 30 steps, the probe
   abandons and the whole scaffold aborts. Keep scenarios focused.

2. **Auto mode side-effects.** Step 2 invokes /sap-gui-probe with `--auto`
   which means write actions (Save / Activate / Delete) run without
   confirmation. If a scenario includes a write action that you'd want to
   pause and approve manually, run that probe by itself first with the
   default confirm mode, then feed only the *folder* to a future
   `/sap-gui-skill-scaffold --from-existing-probes` (not implemented today
   -- recorded in the plan as out-of-scope).

3. **Token-name collisions.** Two different fields can have the same DDIC
   tail (`RS38L-NAME` vs. `RMMG1-NAME` both tail to `NAME`). The merge
   currently de-dups by sorting token output unique; if a collision is
   detected (two distinct targets sharing a token), the emit step falls back
   to `PARAM_NN` for the second one.

4. **De-duplication of probes by mode label.** If two probes get the same
   mode label, their action lists are concatenated into a single mode VBS in
   probe order. This works for "two display variants" but breaks down if the
   action lists overlap in incompatible ways (e.g., both start with `/nSE37`
   but then diverge -- you'll get two `/nSE37` calls in a row). Step 5 flags
   this. The cleanest fix is to give the two scenarios distinct mode labels
   manually in your scenario text (e.g., "display-short" / "display-long").

5. **`POPUP REMINDER` TODOs.** Every popup branch has a default action
   (Continue via `wnd[1]/tbar[0]/btn[0]`) and a TODO comment. This is a
   safe default for informational popups but wrong for "Delete confirmation"
   popups (which need Yes/No). The human must review every popup TODO.
