# Parallel-Safe & Multi-Connection Session Attach for SAP-Driving VBS

**Applies to**: every operational `.vbs` template under
`plugins/<plugin>/skills/<skill>/references/*.vbs` that drives SAP GUI
via `GetObject("SAPGUI") + GetScriptingEngine`.

**Enforced by**: `sap-dev/scripts/check-consistency.mjs` — runs in CI;
fails the build on legacy patterns.

> **Scope note (2026-06-20).** Session attach is **layer 1** of the
> parallel-safety model. After a batch of concurrent same-spec builds (one
> `MaterialUpload` spec built simultaneously across several SAP connections, plus
> several conversations on one connection) surfaced cross-session clobbering that
> attach alone doesn't cover, three more layers were added — **layer 2** per-run
> temp isolation, **layer 3** per-session dev defaults, **layer 4** per-session
> log files. They're summarized in *"Beyond session attach — the other three
> isolation layers"* near the end of this doc; CLAUDE.md holds the authoritative
> per-key detail. The temp model also gained a **runtime** enforcer,
> `sap-dev/scripts/run-temp-hook.mjs` (a `PreToolUse` hook), because the static
> `check-consistency.mjs` can't see the running *cache* copy of a skill or ad-hoc
> agent/orchestrator scratch.

---

## TL;DR for new skill authors

When writing a new SAP-driving VBS template:

1. **Declare `Const SESSION_PATH = "%%SESSION_PATH%%"`** in the Const block near the top.
2. **Include `%%ATTACH_LIB_VBS%%`** via the standard `ExecuteGlobal` block, before any other shared-include like `%%SESSION_LOCK_VBS%%`.
3. **Attach with `Set oSession = AttachSapSession(SESSION_PATH)`** — that's the entire attach. Do NOT roll your own `For Each oCandidate In oApp.Children` loop.
4. **In the wrapping SKILL.md**, substitute the two new tokens and resolve the AI-session's pinned session path via `Get-SapCurrentSessionPath` (see "Skill wrapper convention" below).

If you forget any of these, CI fails. If you intentionally need a different attach pattern (bootstrap before SAPGUI exists, custom session field, etc.), add the file to `TIER3_EXEMPT_VBS` in `check-consistency.mjs` with a comment explaining why.

---

## Why this rule exists

Before this contract, every operational VBS contained a copy of:

```vbs
Set oSession = Nothing
For Each oCandidate In oApplication.Children
    For Each oSessIter In oCandidate.Children
        Set oSession = oSessIter
        Exit For
    Next
    If Not (oSession Is Nothing) Then Exit For
Next
```

This grabs the **first session of the first connection**. Two failure modes:

1. **Parallel skill runs trample each other.** If two skills run concurrently (e.g. via `/sap-gui-skill-scaffold --parallel` or any other fan-out), both grab `/app/con[0]/ses[0]` and their actions interleave.
2. **Multi-connection users silently miss-target.** A user with DEV (`/app/con[0]`) + QAS (`/app/con[1]`) attached, or two different clients (100 vs 200) of the same system, ALWAYS gets `con[0]` regardless of which they meant. A skill targeted at QAS silently writes to DEV.

The shared helper at `plugins/sap-dev-core/shared/scripts/sap_attach_lib.vbs` fixes both. It exposes one function:

```vbs
Function AttachSapSession(sHint)
    ' Returns a GuiSession bound by the following resolution order:
    '   1. sHint                       — explicit /app/con[N]/ses[M] from caller
    '   2. SAPDEV_SESSION_PATH env var — same shape (set by the SKILL.md wrapper
    '                                    via Get-SapCurrentSessionPath, which
    '                                    reads the broker registry for this
    '                                    AI session's pinned connection)
    '   3. Sole-connection auto-default — only when exactly 1 connection attached
    '   4. Refuse loud with helpful error — multi-conn ambiguity
End Function
```

Strategies 1 and 2 take full session paths and **never silently retarget**. Strategy 3 keeps the 99% single-connection case zero-friction. Strategy 4 prevents the multi-connection-cross-target bug class.

*(Phase 4.2 removed the legacy "Strategy 3: read `SAPDEV_PIN_FILE` JSON for session_path". The same role is filled now by the PowerShell-side `Get-SapCurrentSessionPath` helper in `sap_connection_lib.ps1`, which reads the broker registry directly. Wrappers compute the path once and pass it via `SAPDEV_SESSION_PATH`.)*

---

## The canonical VBS pattern (copy this)

```vbs
Option Explicit

Const SOME_PARAM    = "%%SOME_PARAM%%"
Const ANOTHER_PARAM = "%%ANOTHER_PARAM%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
' ... other VKey constants ...

' Include shared helpers. Order matters: attach first; session-lock's
' pre-unlock popup sweep reads from oSession.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()   ' only if write critical section

' ------ 1. Attach to existing SAP GUI session (via shared attach helper) ----
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ------ 2. ... your transaction logic here, using oSession.findById(...) ...
```

That's the entire attach. **No `Dim oSAPGUI, oApplication`, no `For Each` loop, no error-handling stanza** — the helper does all of that internally and either succeeds or `WScript.Echo "ERROR: ..."` + `Quit 2`.

For a clean reference, see `plugins/sap-dev-core/skills/sap-se38/references/sap_se38_check.vbs`.

---

## The canonical SKILL.md wrapper convention (copy this)

Every SKILL.md PowerShell block that generates a runtime VBS must include the Phase 4.2 plumbing block immediately before the `Set-Content`/`WriteAllText` line:

```powershell
$content = [System.IO.File]::ReadAllText('<SKILL_DIR>\references\sap_<skill>_<mode>.vbs', [System.Text.Encoding]::UTF8)
$content = $content -replace '%%SOME_PARAM%%','THE_SOME_PARAM'
# ... other parameter substitutions ...

# Phase 4.2 session-attach plumbing.
$sessionPath = ''   # set to the parsed --session value if supplied
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'

[System.IO.File]::WriteAllText('{RUN_TEMP}\sap_<skill>_<mode>_run.vbs', $content, [System.Text.UnicodeEncoding]::new($false, $true))
```

- **`{WORK_TEMP}` (base) vs `{RUN_TEMP}` (per-run) — do not confuse them.**
  `Get-SapCurrentSessionPath -WorkTemp` MUST stay on the base `{WORK_TEMP}`
  (`{work_dir}\temp`): it derives the durable runtime dir (`{work_dir}\runtime`,
  home of `session_registry.json` + the AI-session pin) from the parent of the
  path you pass, so a run-scoped path would silently relocate the broker registry
  and break parallel-session coordination. The generated runtime `.vbs` and every
  other scratch file the wrapper writes go to `{RUN_TEMP}` (`{work_dir}\temp\run_<id>`,
  minted once in Step 0 by `Get-SapRunTemp`) so two concurrent runs never clobber
  each other's `*_run.vbs` between write and `cscript` exec. See CLAUDE.md
  "Work Directory Configuration".

- `$sessionPath = ''` is intentional default — the helper auto-resolves via `SAPDEV_SESSION_PATH` → sole-connection → refuse.
- `Get-SapCurrentSessionPath` reads `session_registry.json`'s `ai_sessions[<id>].connection_id` for this AI session (parent-PID walk), finds the matching connection block, returns a usable session path on it. Empty string when nothing resolves; the attach lib's sole-connection fallback or "refuse" path then takes over.
- If the SKILL.md is wrapping a write-class skill that also includes `%%SESSION_LOCK_VBS%%`, leave that substitution in — it's complementary, not redundant.

---

## Exempt files (intentionally NOT migrated)

These four files in `plugins/sap-dev-core/shared/scripts/` use their own attach logic by design. Do not migrate them, and do not add new files to this list without a clear reason:

| File | Why exempt |
|---|---|
| `sap_login.vbs` | Bootstrap. Runs BEFORE SAPGUI is guaranteed to be running — `AttachSapSession` assumes the engine is already alive. |
| `sap_check_gui_login_status.vbs` | Single-purpose pre-flight probe; structured differently. |
| `sap_gui_security_warmup.vbs` | One-shot dialog warmup at `/sap-dev-init` Step 1b. Runs before any user task. |
| `sap_login_capture_active_session.vbs` | Captures the just-logged-in session as part of the `/sap-login` bootstrap. |
| `sap_gui_object_details.vbs` | Has its own `findById(SESSION_PATH)` from the Phase-1 sentinel-collision fix. Uses the `Chr(37)` sentinel idiom to detect unsubstituted tokens. |
| `sap_gui_probe_action.vbs` | Resolves session from the action-JSON `"session"` field (different contract: per-action explicit pin). |
| `sap_attach_lib.vbs` | The helper itself. |

If you write a new bootstrap-style file that legitimately needs custom attach, add it to `TIER3_EXEMPT_VBS` in `sap-dev/scripts/check-consistency.mjs` with an inline comment.

---

## Common gotchas

1. **Don't inline the literal `%%SESSION_PATH%%` token as a sentinel comparison.** The PowerShell wrapper's `.Replace()` is global, so any occurrence of the literal token will be rewritten. If you need to detect "unsubstituted token," build the comparison string at runtime via `Chr(37) & Chr(37) & "SESSION_PATH" & Chr(37) & Chr(37)`. See `sap_gui_object_details.vbs` for the precedent (and the bug it originally hid).
2. **Include order matters when both attach-lib and session-lock are present.** Attach lib MUST load first because session-lock's pre-unlock popup sweep reads from `oSession`. The canonical pattern above gets this right.
3. **The helper handles ALL error paths.** Don't wrap `AttachSapSession(SESSION_PATH)` in your own `If oSession Is Nothing Then ...` — the helper has already `WScript.Quit 2`'d on failure. Adding your own block is dead code.
4. **`SAPDEV_SESSION_PATH` is set in PowerShell, read by cscript.** Process env vars cross the boundary, so the cscript child inherits it. Don't try to pass it as an argv arg — the helper specifically looks at the env var.

---

## Verifying compliance

```bash
cd sap-dev
node scripts/check-consistency.mjs
```

Should print (counts grow as the repo grows — the shape is what matters):
```
OK: 4 plugins, 78 skills, all manifests aligned at version 0.6.7, Tier 3 attach contract clean, 10 non-ASCII warning(s), 30 run-temp warning(s), screen-baseline coverage 7/119 (112 unbaselined)
```

On failure, the script lists each non-conforming file with a specific reason. The check covers:

1. Legacy `For Each oCandidate In oApp.Children` (and its variant patterns) → must not appear in non-exempt operational VBS.
2. VBS with `Const SESSION_PATH` but no `%%ATTACH_LIB_VBS%%` include → the helper will be undefined at runtime.
3. VBS that drives SAP GUI (matches `GetObject("SAPGUI")` or `GetScriptingEngine`) but uses neither token → unmigrated.
4. VBS with `%%ATTACH_LIB_VBS%%` include but no `AttachSapSession(...)` call → dead include.
5. SKILL.md that wraps a template requiring `%%ATTACH_LIB_VBS%%` but doesn't substitute it → the runtime VBS will fail to attach.
6. SKILL.md that passes `{RUN_TEMP}` to `Get-SapCurrentSessionPath -WorkTemp` → **hard error** (that call derives `{work_dir}\runtime` from the parent, so a run-scoped path relocates `session_registry.json`; keep the base `{WORK_TEMP}` there). Layer 2.
7. SKILL.md that writes fixed-named generated scratch under the shared `{WORK_TEMP}` base instead of `{RUN_TEMP}` → **run-temp warning** (the Bucket-A coordination files are exempt via `RUN_TEMP_SHARED_ALLOWLIST`). Layer 2.

---

## Related contracts

- **`shared/rules/sap_session_broker.md`** — the broker's CLI contract (`acquire` / `release` / `discover` / `gc` / `list`), v2 multi-connection registry schema, cleanup architecture. Read this when you need to coordinate session ownership across parallel agents.
- **`shared/scripts/sap_attach_lib.vbs`** — the helper itself; well-commented.
- **`shared/scripts/sap_session_broker.ps1`** + **`shared/scripts/sap_session_broker_com.vbs`** — broker implementation.
- **`shared/scripts/sap_dev_default.ps1`** + `Get-SapCurrentDevDefault` (`sap_connection_lib.ps1`) + `Set-SapUserSetting -Scope Session` (`sap_settings_lib.ps1`) — layer 3, per-session dev defaults.
- **`scripts/run-temp-hook.mjs`** — runtime `PreToolUse` enforcer for layer 2 (mirrors `RUN_TEMP_SHARED_ALLOWLIST` from `check-consistency.mjs` as `SHARED_ALLOWLIST`).
- **CLAUDE.md** — "Work Directory Configuration" (two-bucket temp), "Transport Request Settings" (two-layer dev defaults), "Logging Settings" (per-session log patterns): authoritative per-key detail for layers 2–4.

---

## Phase 4 — Multi-profile connection store + AI-session pin

Phase 4 extends the Phase-3.5 multi-connection-aware broker with **persistent
saved profiles** and an **AI-session pin** that keeps the AI session (and its
subagents) on a single SAP connection for its lifetime.

### What changed

1. **`{work_dir}\runtime\` is the new home for DURABLE broker state.**
   `session_registry.json` moved from `{work_dir}\temp\` to
   `{work_dir}\runtime\` so it survives `sap-dev-clean` temp wipes. The
   broker auto-migrates on first call after upgrade.
   Phase 4.2: the pin file `sap_active_session.json` is **eliminated entirely**.
   Session path and version info are now resolved live via
   `Get-SapCurrentSessionPath` / `Get-SapCurrentConnectionProfile` in
   `sap_connection_lib.ps1`. The remaining durable files in `runtime/`:
   `connections.json`, `session_registry.json`, `ai_session_by_pid/<owner_pid>.txt`.
2. **`{work_dir}\runtime\connections.json` stores saved profiles.**
   Multi-profile, DPAPI-encrypted passwords, identified by stable UUIDs.
   Library: `shared/scripts/sap_connection_lib.ps1` (4-step compare,
   dedup-on-save, legacy migration).
3. **AI-session id is derived automatically** from the parent-process tree.
   `Get-SapAiSessionId` in `sap_connection_lib.ps1` walks `ParentProcessId`
   skipping script-host processes (`powershell`, `pwsh`, `cscript`,
   `wscript`, `cmd`, `conhost`) and stops at the first non-script-host
   ancestor — that's the Claude Code conversation process. State lives at
   `{work_dir}\runtime\ai_session_by_pid\<owner_pid>.txt`. Subagents
   inherit the parent's owner PID and therefore the same id; parallel
   Claude Code conversations have different parent PIDs and get different
   ids. Opportunistic GC drops files for dead PIDs.
   The env var `SAPDEV_AI_SESSION_ID` is honoured if set (test/override
   only); normal operation derives it from the process tree without any
   external setup.
4. **Broker new actions**: `pin`, `unpin`, `set-connection-id`, `stuck`.
   New parameters on existing actions: `-AiSessionId`, `-WasCreated`,
   `-ForceUnpin`, `-ConnectionId`, `-Program`, `-Screen`, `-WorkRuntime`.
5. **Pin enforcement at acquire**: when an `acquire` is called with
   `-AiSessionId` AND the registry holds a pin for that AI session AND
   the resolved target connection's `connection_id` differs from the
   pinned one, the broker refuses with `DENIED: ai_session ... pinned to
   ...`. The orchestrator (`/sap-login --switch <id>`) bypasses with
   `-ForceUnpin`; everyone else stays on rails.
6. **Re-pin releases stale claims**: `broker pin -AiSessionId X
   -ConnectionId Y` walks the registry, sends `/n` to every session this
   AI session previously claimed on connection X, and marks them free.
7. **Stuck-screen tracking**: skills that fail mid-flow call `broker
   stuck -Program ... -Screen ...` to record where they got stuck without
   releasing the claim. Next acquire from the same task_id sees the
   marker on `entries[].stuck_program`/`stuck_screen` and decides whether
   to resume or `/n` first.
8. **Created-vs-borrowed**: when `acquire` spawns a session via
   `/oSESSION_MANAGER` it tags `entries[].was_created = true`. `release`
   then calls broker COM helper's `CLOSE` (instead of RESET) so the
   spawned session is actually destroyed — keeps the SAP GUI session
   count clean. Skills can also pass `-WasCreated` explicitly.
9. **RFC load-balanced**: `Connect-SapRfc` accepts
   `-MessageServer -LogonGroup -SystemID` as an alternative to
   `-Server -Sysnr`. Mirrors the GUI-side
   `OpenConnectionByConnectionString("/M/.../G/.../S/...")` flow.
10. **GuiSessionInfo richer capture**: `sap_login_capture_active_session.vbs`
    and `sap_session_broker_com.vbs` now read `MessageServer`, `Group`,
    `SystemNumber`, `ApplicationServer`, `Program`, `ScreenNumber` per
    the SAP GUI Scripting API reference. The
    `sap_session_broker_com.vbs INFO` payload carries the full identity
    tuple per connection block so callers can 4-step-compare without a
    second probe.

### Identity model (4-step compare)

Two "connection info" tuples are the same logical connection iff:

1. `system_name == system_name AND client == client AND user == user`  *(necessary precondition)*
2. THEN any one of:
   - both `logon_pad_entry` non-empty AND equal
   - both `message_server` non-empty AND equal
   - both `application_server` non-empty AND `system_number` non-empty on both sides AND both equal

Implementation: `Test-SapConnectionsEqual` in `sap_connection_lib.ps1`,
duplicated as `Test-IdentityMatch` in `sap_session_broker.ps1`.

### Skill-author contract (Phase 4 additions)

Every PS skill wrapper that calls the broker MUST:

1. **AI session id: no action required.** The broker auto-resolves
   `-AiSessionId` via `Get-SapAiSessionId` (parent-process walk) when the
   caller doesn't pass one. Skill wrappers can omit `-AiSessionId`
   entirely and still get correct pin enforcement for their conversation.
   Pass `-AiSessionId` explicitly only when overriding (e.g.,
   `sap-login --switch` operates on a remembered id from a previous run).
2. Wrap SAP-driving work in `try { ... } finally { broker release ... }` so reset is best-effort even on exception.
3. Pass `-WasCreated` to `release` when the wrapper itself spawned the session (vs claiming a pre-existing free one).

### CI gate additions

`sap-dev/scripts/check-consistency.mjs` Phase-4 checks (see CI source):
- Skills calling `acquire` should pass `-AiSessionId`.
- Skills using `release -WasCreated` should not also `RESET` the session.
- The broker auto-resolves AI session id via parent-PID walk — no wrapper bootstrap code needed (Phase 4.1).

---

## Beyond session attach — the other three isolation layers

Session attach (layer 1, everything above) decides *which GUI session a VBS
drives*. Three more layers, added **2026-06-20** after concurrent same-spec
builds clobbered each other, isolate the *build artifacts* around it. Full
per-key detail lives in CLAUDE.md; this is the parallel-safety summary.

### Layer 2 — Two-bucket temp model

Route every temp file by **scope, not transience** ("it's transient → `{RUN_TEMP}`"
is the trap — some scratch is genuinely cross-session and must stay shared):

- **Bucket A — cross-session coordination → stable shared path** in
  `{work_dir}\runtime\`: files a *different* session must find by a *predictable*
  path — `session_registry.json` (broker), `connections.json`,
  `session_dev_defaults.json`, the AI-session pins. **Allowlisted.**
- **Bucket B — per-run private scratch → `{RUN_TEMP}`** (`{work_dir}\temp\run_<id>`,
  minted by `Get-SapRunTemp` in Step 0): a skill's generated `*_run.vbs`/`.ps1`,
  asXML payloads, `_run.json`, clipboard/title temp files, input files — **and any
  ad-hoc orchestrator/agent probe or verify script.**

Decision rule: *will another session read this exact file by a predictable path?*
Yes → Bucket A; no → Bucket B. Writing a **fixed-named** file into the
`{WORK_TEMP}` root (or the repo root) is the smell that caused the 2026-06-20
cross-session `sap_se38_update_run.vbs` collision — two concurrent v74 builds
clobbered each other's generated VBS between write and `cscript` exec.

Enforced **twice**, because the static checker can't see the running *cache* copy
of a skill or ad-hoc scratch:
- `scripts/check-consistency.mjs` — static (repo SKILL.md): hard error on
  `{RUN_TEMP}` passed to `Get-SapCurrentSessionPath -WorkTemp`; warning on
  fixed-named scratch outside `{RUN_TEMP}`. Shared basenames in
  `RUN_TEMP_SHARED_ALLOWLIST`.
- `scripts/run-temp-hook.mjs` — runtime `PreToolUse` hook (registered per-developer
  in the gitignored `.claude/settings.local.json`, so it's absent from a fresh
  checkout; modes `block` (default) / `warn` / `off` via `SAPDEV_RUNTEMP_HOOK`,
  and it fails **open**): catches the live tool call, including cache-lagged
  skills and **agent/orchestrator scratch**. Blocks a `Write`/`Edit` of a
  generated `.vbs`/`.ps1` into the `{WORK_TEMP}` root; mirrors the Bucket-A
  basenames in `SHARED_ALLOWLIST`.

> This applies to **agents and ad-hoc orchestration**, not just skills. A probe /
> verify / generator script you write on the fly goes to `{RUN_TEMP}`, never a
> fixed name in `{WORK_TEMP}` or the repo root.

### Layer 3 — Two-layer dev defaults (per-(AI-session × connection))

The per-connection dev keys (`sap_dev_transport_request`, `sap_dev_package`,
`sap_dev_function_group`, `sap_dev_mode`, `way_to_get_transport_request`,
`rule_of_tr_description`, `tr_description_template`) now resolve through **two**
layers, highest first:

1. **Session** — `{work_dir}\runtime\session_dev_defaults.json`, keyed per
   `(AI-session × connection)`. A *task's* TR/package lives here, so two
   conversations on the **same** connection stop clobbering each other (the
   2026-06-20 `069 → 074 → 075` thrash). Keyed on the connection too, so a
   `/sap-login --switch` can't carry an `S4DK…` TR onto S4H.
2. **Connection** — `connections.json[<id>].dev_defaults`: the developer's
   **standing** default for that system (the Phase 4.4 layer).

Then the global settings file.

- **Writers:** a *task* TR/package → **Session** scope, which is now the
  **default** — `Set-SapUserSetting … -Scope Session` or the CLI
  `shared/scripts/sap_dev_default.ps1`. A deliberate **standing** default
  (onboarding via `/sap-dev-init` / `/sap-login`) must pass `-Scope Connection`
  explicitly. **Never hand-edit `connections.json` for a task default** — that is
  the cross-conversation clobber this layer exists to prevent.
- **Readers:** go through `Get-SapCurrentDevDefault` (`sap_connection_lib.ps1`)
  for the layered resolution. Session entries are age-pruned (7 days).

### Layer 4 — Per-session log files

Set `log_file_pattern = sap-dev-{YYYYMMDD}-{SID}-{CLIENT}-{AI_SESSION}.log` so
parallel builds get one coherent file per *(AI session × SAP connection)* instead
of interleaving into the daily file; each JSONL record still carries `run_id` /
`skill` for in-file drill-down. Gotchas: `{SYSTEM}` is the Windows
`%COMPUTERNAME%` (workstation), **not** the SAP SID — it does NOT separate
parallel builds on one machine; use `{SID}` / `{CLIENT}` (pinned connection) +
`{AI_SESSION}`. `{AI_SESSION}` resolves `CLAUDE_CODE_SESSION_ID` (stable across a
Claude host restart) → `SAPDEV_AI_SESSION_ID` (override) → `Get-SapAiSessionId`
(parent-PID fallback, **drifts** on host restart).

### The layers at a glance

| Layer | Isolates | Mechanism | Keyed by |
|---|---|---|---|
| 1 — session attach | which GUI session a VBS drives | `AttachSapSession` + broker pin | AI-session → connection_id |
| 2 — temp buckets | generated scratch files | `{RUN_TEMP}` + Bucket-A allowlist | run_id |
| 3 — dev defaults | task TR / package | `session_dev_defaults.json` | AI-session × connection |
| 4 — logs | forensic log streams | `{AI_SESSION}`/`{SID}`/`{CLIENT}` pattern | AI-session × connection |

**Known gap — the customer brief is still a single shared file.**
`{custom_url}\customer_brief.md` is NOT auto-isolated. Keep it
**connection-agnostic** so parallel builds in different logon languages don't
contend: leave *Comments language* **blank** (each build then inherits its own
connection's logon language) and let per-build specifics (program / package /
message class) come from the spec, not the brief.

---

## History

- **Pre-Tier-3** (legacy): every operational VBS had its own attach loop. Parallel runs and multi-connection users both broken.
- **Phase 3.0** (2026-05-14): introduced `sap_attach_lib.vbs`.
- **Phase 3.1**: migrated 4 read-only skills as proof.
- **Phase 3.5**: made the broker multi-connection aware (registry schema v2, new acquire args, attach-lib's pin-file fallback).
- **Phase 3.2 / 3.3 / 3.4**: migrated 19 / 32 / 9 more files across sap-dev-core and sap-tcd plugins, for 100 total.
- **Phase 3.6**: added CI gate at `scripts/check-consistency.mjs` to prevent regression.
- **Phase 4** (2026-05-16): multi-profile connection store (`connections.json`), AI-session pin, broker pin enforcement, RFC load-balanced login, stuck-screen tracking, `was_created` close-semantics.
- **Phase 4.1** (2026-05-16): AI-session id derived from parent-process tree (Get-SapAiSessionId in sap_connection_lib.ps1) so parallel Claude Code conversations get distinct ids and subagents inherit. Broker auto-resolves `-AiSessionId` — wrappers no longer need to bootstrap it.
- **Phase 4.2** (2026-05-16): `sap_active_session.json` pin file eliminated. Version fields moved into the connection profile in `connections.json`. Session path resolved live via `Get-SapCurrentSessionPath` (reads broker registry). 25+ deploy SKILL.md wrappers migrated from `SAPDEV_PIN_FILE` to `SAPDEV_SESSION_PATH`. `sap_attach_lib.vbs` Strategy 3 removed.
- **Layer 2 — two-bucket temp model** (2026-06-20): per-run scratch isolation via `{RUN_TEMP}` + a Bucket-A shared allowlist for `{work_dir}\runtime\` coordination files; dual enforcement — `check-consistency.mjs` (static) + `run-temp-hook.mjs` (runtime `PreToolUse`). Motivated by the cross-session `sap_se38_update_run.vbs` collision between two concurrent v74 builds.
- **Layer 3 — two-layer dev defaults** (2026-06-20): `{work_dir}\runtime\session_dev_defaults.json` keyed per (AI-session × connection); `Set-SapUserSetting -Scope Session` (now the writers' default) + `sap_dev_default.ps1`; reads centralized through `Get-SapCurrentDevDefault`. Fixes the same-connection `069 → 074 → 075` default thrash and stops a `--switch` carrying a TR across systems.
- **Layer 4 — per-session log files** (2026-06-20): `{AI_SESSION}` / `{SID}` / `{CLIENT}` `log_file_pattern` placeholders, so parallel builds get one log per (AI session × connection) instead of interleaving the daily file.
