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

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | Two-file settings model — merge `settings.local.json` over `settings.json` per-key on `.value`; writes always go to `settings.local.json` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — generated VBS templates MUST follow these rules (identify by component ID + DDIC field name, status-bar checks via `MessageType` codes, VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | ABAP code-quality rules — when scaffolding skills that emit or paste ABAP source (deploy / codegen / fix templates), the generated SKILL.md must reference this file and the templated VBS must not embed literal MESSAGE strings or other quality anti-patterns |

---

## Step 0 — Resolve work directory + scaffold folder

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Read sap-dev-core's `settings.json` (2 levels up from `<SKILL_DIR>`). Read
`work_dir`. Default: `C:\sap_dev_work`.

Derive:
- `{WORK_TEMP}`       = `{work_dir}\temp`
- `{TS}`              = current timestamp `yyyyMMdd-HHmmss`
- Parse new skill name + scenarios from `$ARGUMENTS` (see Step 1).
- `{SCAFFOLD_FOLDER}` = `{work_dir}\skill_scaffolds\<new-skill-name>_<TS>`

```powershell
New-Item -Path '{WORK_TEMP}'       -ItemType Directory -Force | Out-Null
New-Item -Path '{SCAFFOLD_FOLDER}' -ItemType Directory -Force | Out-Null
```

Use `New-Item -Force` rather than `cmd /c … mkdir` — Windows' built-in
`mkdir` silently no-ops when the parent path is missing under some
cmd.exe extension states, leaving `{SCAFFOLD_FOLDER}` uncreated and
Step 0.5's `-StateFile` write below raising `DirectoryNotFoundException`.
`New-Item -Force` is reliable cross-shell and creates intermediate
directories.

---

## Step 0.5 — Start logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{SCAFFOLD_FOLDER}\sap_gui_skill_scaffold_run.json" -Skill sap-gui-skill-scaffold -ParamsJson "{\"new_skill\":\"<name>\",\"scenario_count\":\"<N>\"}"
```

The probe runs invoked in Step 2 inherit this run as their parent via the
`SAPDEV_PARENT_RUN_ID` env var, so `/sap-log-analyze` can reconstruct the
scaffold → probe call tree.

---

## Step 0.7 — Pre-flight: GUI session + active-session pin

First, confirm at least one SAP GUI session is attached:

```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```

If status is not `LOGGED_IN`, stop and tell the user to run `/sap-login` first.
Log end Status=FAILED ErrorClass=NO_SESSION.

Second, resolve the **active-session pin** via the connection lib:

```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$session = Get-SapCurrentSessionPath           -WorkTemp '{WORK_TEMP}'
$profile = Get-SapCurrentConnectionProfile     -WorkTemp '{WORK_TEMP}'
```

- `$session` is the SAP GUI session path for the AI-session's pinned connection (sole-conn fallback applies). Empty when no pin AND multi-conn.
- `$profile` is the full connection profile (or `$null` when nothing is pinned). It carries version fields used below.

**When `$session` is empty**, try auto-pin before refusing. If the broker
registry has exactly one connection block with a non-empty `connection_id`
(other blocks are unregistered shells the broker cannot acquire against
anyway), pin to it automatically; if more than one is registered, refuse:

```powershell
if ([string]::IsNullOrWhiteSpace($session)) {
    # Inspect the registry to count registered (connection_id-bearing) blocks.
    $registry = Get-Content '{work_dir}\runtime\session_registry.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $registered = @($registry.connections | Where-Object { "$($_.connection_id)" -ne '' })
    if ($registered.Count -eq 1) {
        $aid = Get-SapAiSessionId
        & '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1' `
            -Action pin -AiSessionId $aid -ConnectionId $registered[0].connection_id `
            -PinReason 'scaffold_auto' -WorkTemp '{WORK_TEMP}' | Out-Host
        $session = Get-SapCurrentSessionPath        -WorkTemp '{WORK_TEMP}'
        $profile = Get-SapCurrentConnectionProfile  -WorkTemp '{WORK_TEMP}'
    } else {
        Write-Error "multiple SAP GUI connections detected (registered: $($registered.Count)) and no active session pinned; run /sap-login to pin one. Candidates: $(($registered | ForEach-Object { $_.connection_id }) -join ', ')"
        # Log end Status=FAILED ErrorClass=NO_PIN.
        exit 1
    }
}
```

This handles the common "two connections in saplogon, only one registered
with the broker" case without forcing a full `/sap-login` cycle. When
auto-pin fires, the resulting pin's `pin_reason` is `scaffold_auto` so
the operator can audit it via `broker list` / inspecting the registry.
The refusal message lists candidate connection_ids so the operator can
pin manually via `broker -Action pin -ConnectionId <id>` if needed.

*Phase 4.2 note:* prior versions read `{WORK_TEMP}\sap_active_session.json` for both session_path AND version info. That file is gone. Session path resolution + version info both go through the lib helpers above. Cross-AI-session persistence lives in `connections.json` via `default_target_id`.

The resolved path is `{PINNED_SESSION}`. Its parent connection (everything
up to the final `/ses[N]`) is `{PINNED_CONNECTION}`. `{PINNED_SESSION}`
is the default session for serial-mode probes (Step 2-Serial). The
parallel path (Step 2-Parallel) doesn't use `{PINNED_SESSION}` directly —
the broker allocates fresh sessions there; `{PINNED_CONNECTION}` is kept
in scope for diagnostic logging only.

Also copy version fields from `$profile` into the scaffolder's run state
and into the generated SKILL.md's "Probed against" header:
- `gui_version_raw`, `gui_major`     ← `$profile.gui_version_raw`, `$profile.gui_major`
- `server_release_marker`, `server_release_raw`
- `system_name`, `client`

**System-id consistency check (mandatory).** The pinned connection's
`system_id` MUST match the system the operator is actually working in
on the active GUI window. Mismatch is silent today but routinely
misroutes probes to the wrong system (observed 2026-05: pin landed on
the registered S4D block while operator's active SAP GUI window was
S4H — probes drove S4H but the scaffolder logged everything as S4D,
and the configured `sap_dev_transport_request` for S4D was rejected by
S4H). Implement as:

```powershell
# Re-read the active-GUI status line emitted by Step 0.7's first command.
$activeSystem = (& "C:\Windows\SysWOW64\cscript.exe" //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
    | Select-String -Pattern '^SYSTEM:\s*(\S+)') -replace '^.*SYSTEM:\s*',''
$pinnedSystem = "$($profile.system_name)"   # could also use $profile.system_id
if ($activeSystem -and $pinnedSystem -and ($activeSystem -ne $pinnedSystem)) {
    Write-Error "GUI session is on '$activeSystem' but the pinned connection is '$pinnedSystem'. Run /sap-login to re-pin, or unpin and rerun the scaffolder."
    # Log end Status=FAILED ErrorClass=PIN_SYSTEM_MISMATCH
    exit 1
}
```

This guard is what makes Bug 6 (per-connection TR resolution) actually
correct downstream — if the pin and the GUI agree, then
`sap_dev_transport_request` resolved from the per-profile
`dev_defaults` in `connections.json` is automatically the TR for the
right system. Without this guard, the per-connection mapping is moot.

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
6. **Optional `--parallel`**: run all scenario probes concurrently, one
   SAP GUI session per probe sub-agent. See Step 2-Parallel below. Without
   this flag, Step 2 runs serially against the pinned session (today's
   behaviour).
7. **Optional `--parallel-cap N`** (default 6): max concurrent probes.
   Capped at 6 because SAP's default `rdisp/max_alt_modes` is 6 sessions
   per connection. If `--parallel` is set and scenario count > cap, run
   in batches of `cap`.

After parsing:
- If scenario count < 2, refuse with: *"scaffolding from one probe is just
  synthesized.vbs -- use that directly via /sap-gui-probe"*. Log end
  Status=SKIPPED.
- Derive a mode name per scenario in two passes:

  **Pass 1 — verb**: scan the scenario for an action verb. First match wins.

  | Keyword regex (case-insensitive) | Verb label |
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

  **Pass 2 — object discriminator**: when the verb matches but a SAP repo
  object noun is also present, append it as a suffix. This keeps
  multi-object SE11 / SE38 / SE24 / ... skills from collapsing every
  scenario into one mode. First match wins; case-insensitive.

  | Keyword regex | Suffix |
  |---|---|
  | `\btable\b` | `-table` |
  | `\bview\b` | `-view` |
  | `\bdataelement\b\|\bdata[ _-]?element\b` | `-dataelement` |
  | `\bdomain\b` | `-domain` |
  | `\bstructure\b` | `-structure` |
  | `\btabletype\b\|\btable[ _-]?type\b` | `-tabletype` |
  | `\btypegroup\b\|\btype[ _-]?group\b` | `-typegroup` |
  | `\bsearchhelp\b\|\bsearch[ _-]?help\b` | `-searchhelp` |
  | `\blockobject\b\|\block[ _-]?object\b` | `-lockobject` |
  | `\bprogram\b\|\breport\b\|\bpgm\b` | `-program` |
  | `\bfunction[ _-]?module\b\|\bfm\b` | `-fm` |
  | `\bfunction[ _-]?group\b\|\bfugr\b` | `-fugr` |
  | `\bclass\b` | `-class` |
  | `\binterface\b` | `-interface` |
  | `\bmessage[ _-]?class\b` | `-messageclass` |
  | `\bpackage\b` | `-package` |

  If neither pass matches a verb, fall back to `mode_NN` (NN = scenario
  index, 1-based). Two scenarios producing the same final mode label
  (e.g. both `create-domain`) get de-duplicated — both contribute their
  actions to a single merged mode VBS. This is fine when the actual
  flows differ only in payload values (the merge surfaces those as
  parameters); Step 5 self-review only flags a collision warning when
  the merge produced ZERO parameters (then the collapse was a real
  accident, not intentional value-variance).

Echo the parsed plan to the user before Step 2:

> Scaffolding **<new-skill-name>** from N scenario(s):
> 1. mode=`display` -- "<scenario 1 verbatim>"
> 2. mode=`delete` -- "<scenario 2 verbatim>"
> ...
> Output folder: `<SCAFFOLD_FOLDER>`

---

## Step 2 — Run /sap-gui-probe for each scenario

The execution path branches on `--parallel`:

### 2-Serial — default path (no `--parallel`)

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

### 2-Parallel — `--parallel` path

Active when `--parallel` is set on the invocation.

Allocation goes through the **SAP GUI Session Broker** —
`shared/scripts/sap_session_broker.ps1`, contract documented in
`shared/rules/sap_session_broker.md`. The broker owns session
discovery / spawn-on-demand / lifecycle / cleanup so the scaffolder
doesn't have to.

**Warmup-first sequencing (mandatory).** The FIRST scenario ALWAYS runs
serially (Steps 2-Serial below) BEFORE any parallel fanout begins. The
scaffolder treats scenario 1 as the warmup — by convention it creates
any prerequisites later scenarios depend on (a fresh TR, a new package,
a base function group, etc.). Running it solo first eliminates the
race condition where parallel followers hit SAP before the warmup has
landed its writes (observed in 2026-05 test run: 2 of 3 followers
failed with "package ZCMSKILLSC3 does not exist" because they raced
ahead of scenario 1's package-create step). Implementation:

1. Run scenario 1 via Step 2-Serial below — single probe, no broker
   acquire (use `{PINNED_SESSION}` directly).
2. On success, record the run folder and continue.
3. On FAILED / ABANDONED, abort the whole scaffold immediately.
4. THEN proceed to the broker-coordinated parallel fanout (Steps 2.0
   onward) for scenarios 2..N.

This applies regardless of whether scenario 1 has explicit prerequisite
syntax — the scaffolder cannot know which writes are prerequisites
without solving a semantics problem, so the conservative rule is "first
scenario always warms up." Operators who DON'T want a warmup (e.g. all
scenarios are read-only) can ignore the cost; one extra serial probe
adds maybe 30s and is correct.

**2.0 — Pre-flight: discover existing sessions, then gc any stale claims.**

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1" -Action gc -WorkTemp "{WORK_TEMP}"
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1" -Action discover -WorkTemp "{WORK_TEMP}"
```

`gc` first so any stale entries from a previous AI session (crashed sub-
agents, abandoned claims past TTL) get cleared before discover registers
the live sessions. Discover output:

```
DISCOVERED: <n> new (total free=<f> user_owned=<u>)
```

If `free < parallel_cap` we don't worry — the broker spawns on demand
inside the per-scenario `acquire` calls. If `free == 0` AND the SAP cap
is 6 already, the very first acquire will get `DENIED: ... cap reached`;
treat that as a hard abort.

**2.1 — Acquire one session per scenario in the batch.** Build descriptors
by acquiring up front (rather than letting each agent acquire its own —
the scaffolder is the orchestrator, so it holds every claim on the
agents' behalf):

```bash
# For each scenario i in this batch:
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1" `
    -Action     acquire `
    -TaskId     "scaffold_<runId>_scenario_<i>" `
    -OwnerSkill "sap-gui-skill-scaffold" `
    -OwnerPid   0 `
    -WorkTemp   "{WORK_TEMP}"
# (no -PinFile: broker auto-resolves the AI session's pinned connection via
# Get-SapAiSessionId + session_registry.json's ai_sessions map.)
```

**`-PinFile` is REQUIRED** — without a connection resolver, multi-connection
setups (any operator with two or more SAP Logon entries attached) get
`DENIED: ambiguous target: N connections attached and no resolver supplied`
on the very first acquire. The pin file from Step 0.7 has already pinned
`{PINNED_CONNECTION}`, so passing it routes every probe to the same
connection the operator authorised. If you ever need to scaffold across
connections, swap `-PinFile` for `-ConnectionPath "{PINNED_CONNECTION}"`
(same effect, no file read).

**`-OwnerPid 0` is INTENTIONAL** for the scaffolder. Each tool call from the
orchestrator (Claude) spawns a transient `pwsh.exe` process whose PID dies
immediately on return. Passing `-OwnerPid $PID` from inside such a call
would record a dead PID and the broker's reactive sweep would drop the
entry on the next operation. The scaffolder relies on TTL (10 min default)
for crash recovery instead — long enough to outlast any normal batch,
short enough that abandoned scaffolds get cleaned up. **Skill wrappers
that run as a single long-lived `pwsh` process (the typical Tier 3 case)
SHOULD pass `-OwnerPid $PID`** — they benefit from immediate pid_dead
detection.

Stdout last line is one of:

```
ACQUIRED: path=/app/con[0]/ses[N] sessionNumber=M reused=<bool>
DENIED:   <reason>     # exit 1 -- typically "cap reached"
ERROR:    <reason>     # exit 2 -- SAP unreachable
```

On `DENIED`/`ERROR` for ANY scenario in the batch, **release all already-
acquired claims for this batch** (`release -TaskId scaffold_<runId>_scenario_<j>` for j<i) and abort. The
broker's `release` is idempotent — calling it for an unknown task_id
returns `NOT_FOUND` and is a no-op.

The `task_id` MUST be unique per acquired claim across the whole scaffold
run; the suggested shape `scaffold_<runId>_scenario_<i>` satisfies that.
`runId` is the scaffolder's own log_helper run id (Step 0.5).

The resulting descriptor list:

```
descriptors = [
  { i: 0, scenario: "<text>", mode: "<label>", task_id: "scaffold_xxx_scenario_0", session: "/app/con[0]/ses[N0]" },
  { i: 1, scenario: "<text>", mode: "<label>", task_id: "scaffold_xxx_scenario_1", session: "/app/con[0]/ses[N1]" },
  ...
]
```

**2.2 — Spawn N general-purpose Task sub-agents** in a single tool message.
Each sub-agent's prompt:

> You are probe runner #i of N for a sap-gui-skill-scaffold run. Your
> assigned SAP GUI session is `<session>`. The orchestrator has already
> acquired this session through the broker; you do NOT need to touch the
> broker. Invoke `/sap-gui-probe` with this argument string verbatim:
>
>     <scenario> --auto --session <session>
>
> When the skill finishes successfully, return ONLY the absolute path of
> the resulting run folder as the LAST line of your message (no extra
> prose after it).
>
> If the probe fails or is abandoned, return the literal token
> `FAILED:<short reason>` as the last line.
>
> Do not touch any other SAP GUI session. Do not invoke unrelated skills.

**2.3 — Collect results.** Wait for all N sub-agents to return. Parse each
agent's last non-empty line:
- absolute folder path → success, append to probe list with the matching mode label.
- `FAILED:<reason>` → record the failure for this scenario index.

**2.4 — Release EVERY claim acquired in this batch.** Always, even on
failure:

```bash
# For each descriptor d in this batch:
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1" `
    -Action  release `
    -TaskId  "<d.task_id>" `
    -WorkTemp "{WORK_TEMP}"
```

Release drives `/n` on the session (back to Easy Access) and frees the
entry for the next batch. Release is idempotent; calling it for a
task_id that was already released or never acquired returns `NOT_FOUND`
and is harmless.

**2.5 — Failure policy.** If ANY sub-agent returned FAILED, abort the
whole scaffold after releasing all batch claims (Step 2.4 still runs).
Log end Status=FAILED ErrorClass=PROBE_FAILED ErrorMsg="<failed indices>".
Successful probe folders remain on disk.

**2.6 — Batching.** If `scenario_count > parallel_cap`, repeat
Steps 2.1–2.4 in batches of size `parallel_cap`. Each batch acquires
fresh from the broker — the previous batch's releases returned its
sessions to the broker's free pool, so subsequent acquires re-use them
without needing to re-spawn. The broker's reactive cleanup catches
any sessions destroyed by misbehaving sub-agents (e.g. yesterday's
CUKY runner Shift+F3'd its session out of existence — the next batch's
acquire would have noticed via the `session_closed` sweep and spawned
a fresh replacement transparently).

**Concurrency notes:**
- Each cscript process binds to exactly one session via the `session` field
  in its action JSON. No mid-script switching.
- SAP GUI Scripting's `session.LockSessionUI` is per-session, so concurrent
  probes don't fight each other.
- Each probe writes to its own folder; no shared writeable state.
- Cost: each sub-agent has its own context window — roughly N× the token
  cost of the serial path. Use `--parallel` for time savings on 4+ scenarios.

---

## Step 3 — Cross-probe merge

Once every probe succeeded:

```powershell
$folders = @('<folder1>','<folder2>', ...)
$modes   = @('<mode1>','<mode2>', ...)
& '<SKILL_DIR>\references\merge_probes.ps1' -ProbeFolders $folders -ModeNames $modes -OutputFile '{SCAFFOLD_FOLDER}\_merge_report.json'
```

**Why the call-operator (`& '<script>.ps1' ...`) instead of `powershell -File`?**
The PowerShell host's `-File` argument tokenizer turns a literal `-ProbeFolders "a","b","c"` into a SINGLE string `a,b,c` (one element), and `merge_probes.ps1` then refuses with "need at least 2 probe folders; got 1". Invoking via the call operator from a PowerShell host preserves the real `[string[]]` array binding. Pass `$folders` and `$modes` as arrays built up beforehand.

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

```powershell
& '<SKILL_DIR>\references\emit_skill_folder.ps1' `
    -MergeReport  '{SCAFFOLD_FOLDER}\_merge_report.json' `
    -SkillName    '<new-skill-name>' `
    -OutputDir    '{SCAFFOLD_FOLDER}' `
    -Tcd          '<TXN>' `
    -ServerMarker '<server_release_marker-from-pin-or-empty>' `
    -ForceParam   @('L_DEVCLASS','TRKORR')   # optional; see below
```

`-ForceParam` (optional `[string[]]`) overrides the merge classification by
DDIC field tail. Use this when every probe happened to use the same value
for a field — making the merge classify it as a `constant` — but real
users will want to vary it. Canonical examples:

- `L_DEVCLASS` — package name on the Object Directory popup; classified as
  constant because every test scenario said "in <one-package>", but the
  shipped skill should accept any package.
- `TRKORR` — transport request number on the Workbench Request popup;
  same reasoning.

For each matched touchpoint, the emit step flips `constant` → `parameter`,
derives a token from the tail (`%%L_DEVCLASS%%`, `%%TRKORR%%`), and rebuilds
per-probe values from each probe's recorded action so the argument-hint
and SKILL.md dispatch table list the new parameter alongside the
merge-discovered ones.

`-ServerMarker` is `$profile.server_release_marker` from the
`Get-SapCurrentConnectionProfile` call in the second-step of Step 0
(e.g. `S4HANA_2022`, `ECC6_EHP8`). When non-empty, every emitted mode
VBS is named `sap_<name>_<mode>.<marker>.vbs` so the version-aware
selector (`shared/scripts/sap_select_vbs_variant.ps1`) picks it on
matching systems and falls back to the default `.vbs` on non-matching
ones. When the profile has no marker (RFC system info was never captured
or returned empty), pass an empty string and filenames stay untagged.

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
4. **Mode collisions** -- if two scenarios produced the same mode label
   (e.g., both `display-table`) AND the merge report's parameter count
   is zero, surface a real collision warning: the scenarios merged
   without producing any distinguishing parameters, which usually means
   they shouldn't have been collapsed. When parameter count is > 0 the
   collapse was the intended outcome (the variance lives in the
   parameter tokens), so DO NOT warn.

Output a concise findings list; do not modify the generated files.

---

## Step 6 — Cleanup and install hint

Best-effort return SAP GUI to Easy Access (in case Step 2 left the session
mid-flow on the last probe's end state):

```bash
echo {"verb":"SET_OKCD","value":"/n","note":"scaffolder cleanup"} > "{WORK_TEMP}\scaffold_cleanup.json"
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-gui-probe\references\sap_gui_probe_action.vbs" "{WORK_TEMP}\scaffold_cleanup.json"
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
