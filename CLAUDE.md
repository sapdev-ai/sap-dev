<coding_guidelines>

# SAP GUI Plugins - Project Context

Repository: sap-dev
Purpose: SAP GUI automation plugins for AI coding assistants
Version: 0.1.0 | Plugins: 3 | Last Updated: 2026-05-12

## What This Repository Is

SAP GUI automation plugins providing context-aware AI assistance for SAP GUI Scripting tasks including login, connection management, and credential storage.

## Critical Directives

### 1. ALWAYS Use plugin-dev First

For all general plugin development tasks:

- Creating skills, commands, agents, hooks
- YAML frontmatter syntax
- Plugin directory structure
- MCP server integration
- Basic validation

### 2. ALWAYS Use Manual Review Process

FORBIDDEN - Automated Refactoring:

- Creating Python/shell scripts to refactor skills
- Using sed/awk to programmatically rewrite sections
- Batch processing without human review
- Auto-generating content via scripts

REQUIRED - Manual Refactoring:

- Use Read, Edit, Write tools manually
- Review each change before applying
- Human judgment for extraction decisions
- Quality control via manual review

### 3. ALWAYS Honor Skill Operating Rules

Every skill in every plugin MUST observe the rules defined in
`plugins/sap-dev-core/shared/rules/skill_operating_rules.md`. Summary:

- **No direct SQL writes on SAP standard tables** (any table not starting with
  `Z` or `Y`). Reads (`SELECT`, `RFC_READ_TABLE`, read classes) are always
  allowed. For mutations, use SAP-supplied write APIs (`BAPI_*`, `RPY_*`,
  `DDIF_*`, `SEO_*`, etc.). If no write API exists, ASK the user before
  proceeding.
- **No unsolicited program/report deployment.** Skills must not create or
  deploy ABAP reports, function modules, or classes unless the user explicitly
  requested it (or the skill is explicitly a deploy skill like `/sap-se38`).
  When a helper would be useful, STOP and ask for permission first.

These rules override any conflicting guidance inside individual SKILL.md
files.

### 4. ALWAYS Honor TR Resolution Rule

Every deploy skill that needs a transport request (sap-se11, sap-se38,
sap-se37, sap-se24, sap-se91, …) MUST follow
`plugins/sap-dev-core/shared/rules/tr_resolution.md`. Summary:

- `/sap-transport-request` is the **single TR-resolution entry point**.
  Skills delegate to it; they MUST NOT prompt the user for a TR or call
  `/sap-se01` directly.
- The user-level policy is `userConfig.way_to_get_transport_request`:
  - `DEFAULT` — reuse `sap_dev_transport_request`; ask only if blank/released.
  - `ASK` — ask each time; offer to save the answer as the new default.
  - `CREATE_NEW` — always create a fresh TR via `/sap-se01`; never persist.
- `/sap-se01` defaults the request type to `W` (Workbench) and never asks
  for it. `C` (Customizing) only when the user explicitly requests it.
- New-TR descriptions are rendered per `userConfig.rule_of_tr_description`
  (`ASK` / `PATTERN` / `FIXED` / `RANDOM`) using
  `userConfig.tr_description_template`, then truncated/compressed to the
  60-char SE01 limit. PATTERN placeholders: `{YYYYMMDD}`, `{HHMMSS}`,
  `{USER}`, `{OBJECT_TYPE}`, `{OBJECT_DESCRIPTION}`, `{RANDOM4}`.
- Mid-session policy changes ("from now on, always ask") are persisted
  immediately to `way_to_get_transport_request` and honoured for the rest
  of the session.

### 5. ALWAYS Honor SAP GUI Language Independence Rules

Every skill that drives SAP GUI through VBScript MUST observe the rules in
`plugins/sap-dev-core/shared/rules/language_independence_rules.md`. The
recorded VBS files were captured under EN logon, but live operators may log
on in JA / DE / ZH / etc. Summary:

- **Identify controls by ID, never by displayed text.** Use
  `findById("wnd[0]/tbar[1]/btn[27]")` and DDIC field names like
  `ctxtKO008-TRKORR` — they are stable across all logon languages. Never
  branch on `.Text`, `.Tooltip`, window titles, or menu labels.
- **Status-bar checks use `MessageType`** (`S` / `W` / `E` / `I` / `A`),
  not substrings of `sbar.Text`. The text is translated; the code is not.
- **Detect popups by `wnd[1]` ID + DDIC discriminator**, never by translated
  modal title (e.g. probe `wnd[1]/usr/ctxtKO008-TRKORR` to confirm it is the
  TR popup).
- **Prefer VKey over menu-text navigation** — `sendVKey 11` (Save), `27`
  (Activate), `26` (Ctrl+A Select All), `12` (Cancel/F12).
- **Localised text is allowed only inside `WScript.Echo` diagnostic lines.**
- When recording new VBS: scan immediately and remove any `.Text =` /
  `.Tooltip =` / `InStr(..., "<English text>")` branches.

### 6. ALWAYS Check Skills Before Probing

Before solving any SAP-related task by reading source, running ad-hoc
commands, or writing one-off scripts, Claude MUST first scan the available
skill list for a matching capability. Plugins exist precisely so that the
hard-won SAP knowledge is reusable — re-deriving it from scratch each session
wastes the user's context, time, and trust.

Procedure (mandatory):

1. **Match intent against the skill catalogue.** Sources of truth:
   - The available-skills list shown in system reminders this turn.
   - `.claude-plugin/marketplace.json` — full registry by plugin.
   - The `## Shared Resources` and `## Standalone *` sections in this file.
2. **If a skill plausibly matches** (login, TR resolution, transaction
   driving, DDIC lookup, ATC, package move, activation, RFC wrapper, spec
   extraction, ABAP check/fix, etc.) → invoke it via the Skill tool. Do
   NOT replicate its logic with raw Read / Bash / PowerShell / Edit calls.
3. **Only fall through to ad-hoc tooling when no skill fits.** When you do,
   state explicitly: *"No matching skill — falling back to direct
   exploration."* This makes the choice visible and reviewable.
4. **Error recovery follows the same rule.** A failed deploy is recovered
   via `/sap-check-fix` or `/sap-activate-object`, not by manually
   re-opening SE38 and probing. A missing TR is resolved via
   `/sap-transport-request`, not by typing `/n SE01` into the OK code field.

Common anti-patterns to avoid:

- ❌ Writing a fresh VBS to query SE16N when `/sap-se16n` exists.
- ❌ Reading source code to "understand the structure" before invoking a
  generation/check skill that already encodes that knowledge.
- ❌ Asking the user for a TR number — the user-facing entry point is
  `/sap-transport-request`, which honours the `way_to_get_transport_request`
  policy.
- ❌ Crafting `RFC_READ_TABLE` calls inline when `sap_rfc_lib.ps1` plus a
  domain skill (e.g. `/sap-check-abap`, `/sap-docs-check-ddic`) is the
  intended path.

The discipline is "skills first, raw tools second" — not "skills only."
Direct tooling remains valid for genuinely novel problems, exploratory
debugging of skills themselves, and one-off user requests that no skill
covers. The point is to *check first, then choose*, instead of reflexively
reaching for `Bash` and `Read`.

### 7. ALWAYS Use the Settings Merge Helper

User-configurable values for the sap-dev plugins live in two files —
tracked schema `plugins/<plugin>/settings.json` (all values blank) and
gitignored per-developer overrides `plugins/<plugin>/settings.local.json`.
The full contract is in
`plugins/sap-dev-core/shared/rules/settings_lookup.md`. Summary:

- **Reads** merge `settings.local.json` over `settings.json` per-key on
  the `.value` field. Never read `settings.json` directly when the value
  matters. PowerShell: `Get-SapSettingValue` from `sap_settings_lib.ps1`.
  VBScript: `GetSapSettingValue` from `sap_settings_lib.vbs`. Claude
  Read-tool flow: read both files, prefer the local `.value` when non-empty.
- **Writes** ALL go to `settings.local.json` — never `settings.json`.
  PowerShell: `Set-SapUserSetting`. VBScript: `SetSapUserSetting`.
  Claude Edit-tool flow: target the local file; create if missing.
- **Onboarding**: `pwsh ./scripts/dev-setup.ps1`, or run `/sap-login`,
  or hand-copy and edit. See `docs/settings-local-faq.md`.

## Marketplace System

Structure: Dual-level manifests (plugin + skill plugin.json)
Registry: Central marketplace.json

## Quality Standards

Production Testing: All skills tested with real SAP systems

Reserved Words Policy: Marketplace and plugin `name` and `description` fields MUST NOT contain: "official", "anthropic", or "claude". These are blocked by the CLI to prevent marketplace impersonation.

### Skill Naming Convention

All skills across all sap-dev plugins MUST follow this convention. The
prefix earns its keep at the boundaries of Claude Code's global skill
namespace — generic names like `/login`, `/check`, `/extract`, `/atc`
*will* eventually collide with another plugin's skill.

| Rule | Example (good) | Example (bad) |
|---|---|---|
| **Prefix every skill with `sap-`** | `/sap-login`, `/sap-se38`, `/sap-atc` | `/login`, `/se38`, `/atc` |
| **Sub-namespace with single dashes — never duplicate the prefix** | `sap-docs-extract`, `sap-rfc-wrapper-fm` | `sap-sap-docs-extract`, `sap_docs_extract` |
| **Use kebab-case** (lowercase, hyphen-separated) | `sap-change-package` | `sap_change_package`, `sapChangePackage`, `SAP-CHANGE-PACKAGE` |
| **Group consistently inside the prefix.** Established sub-namespaces: `sap-docs-*` (spec pipeline), `sap-check-*` / `sap-fix-*` (validation pairs), `sap-rfc-wrapper-*` (codegen), `sap-gui-*` (GUI utilities), `sap-se##` / `sap-se##-*` (SAP transactions) | `sap-fix-fm`, `sap-rfc-wrapper-class` | `sap-fm-fix`, `sap-class-rfc-wrapper` |
| **No hidden synonyms.** One skill = one name. Don't ship aliases. | only `sap-transport-request` | both `sap-transport-request` and `sap-tr` |

When adding a new skill, scan the existing list (`plugins/*/skills/*/`) for
prior art before inventing a new sub-namespace. Reuse beats inventing.

## Shared Resources

### sap-dev-core as Shared Foundation

Cross-plugin shared files live at `plugins/sap-dev-core/shared/`. All other plugins treat sap-dev-core as a required companion — install it first. Its `shared/` directory is distributed with sap-dev-core and accessible to any sibling plugin at runtime.

| Sub-directory | File types | Purpose |
|---|---|---|
| `shared/tables/` | `.tsv`, `.csv` | Static reference tables (read by Claude or injected via `%%TOKEN%%`) |
| `shared/scripts/` | `.ps1`, `.vbs` | Reusable automation scripts shared across plugins. RFC-calling scripts are PowerShell + SAP NCo 3.1; SAP GUI Scripting helpers remain VBScript. |
| `shared/rules/` | `.md`, `.txt` | AI guidance conventions applying to all plugins |

### Current Shared Files

| File | Used By | Purpose |
|---|---|---|
| `shared/tables/abap_naming_rules.tsv` | sap-check-abap, sap-gen-abap, sap-fix-abap | ABAP variable naming prefix conventions (can be overridden via `{custom_url}`) |
| `shared/tables/sap_object_naming_rules.tsv` | sap-check-abap, sap-check-fm, sap-docs-check-ddic, sap-se11, sap-se38, sap-se37, sap-se24 | SAP repository-object naming patterns (PROGRAM/SUBROUTINE/FUNCTION_GROUP/FUNCTION_MODULE/GLOBAL_CLASS/METHOD/DDIC_*/MESSAGE_CLASS/PACKAGE). Customer override at `{custom_url}\sap_object_naming_rules.tsv`. Read by the shared validator below. |
| `shared/scripts/sap_check_object_name.ps1` | sap-check-abap, sap-check-fm, sap-docs-check-ddic, sap-se11, sap-se38, sap-se37, sap-se24 | Shared object-name validator. Inputs: `-ObjectType <KEY> -ObjectName <NAME> [-CustomUrl <path>] [-RulesFile <path>]`. Exit 0 = OK, 1 = VIOLATION (regex mismatch), 2 = UNKNOWN_TYPE / RULES_NOT_FOUND. Resolves rules file via custom override → default. Logs via `sap_log_lib.ps1` when available. |
| `shared/tables/domain_datatypes.tsv` | sap-se11 | Valid SAP DDIC data types with validation rules |
| `shared/tables/spec_conversion_rules.tsv` | sap-docs-convert | Field-name / DDIC-type / flag normalisation rules applied to extracted specs. Categories: `field_rename`, `type_rename`, `flag_mapping`, `schema_migration`. Override per customer at `{custom_url}\spec_conversion_rules.tsv`. |
| `shared/scripts/sap_rfc_lib.ps1` | **All RFC-using PowerShell scripts (shared library)** | Reusable NCo 3.1 connect/disconnect helpers (`Connect-SapRfc`, `Disconnect-SapRfc`, `Add-RfcField`, `Add-RfcOption`). Dot-sourced via `%%RFC_LIB_PS1%%` token to keep the GAC discovery + `RfcConfigParameters` boilerplate in one place. |
| `shared/scripts/sap_settings_lib.ps1` | **All PowerShell skill wrappers that need a userConfig value (mandatory — Rule 7)** | Settings reader/writer. Dot-source via `%%SETTINGS_LIB_PS1%%`. Functions: `Get-SapSettings` (returns merged object), `Get-SapSettingValue '<key>' '<default>'` (resolved string), `Set-SapUserSetting '<key>' '<value>'` (writes to settings.local.json). Reads merge `settings.local.json` over `settings.json` per-key on the `value` field. All writes go to `settings.local.json` — never to `settings.json`. |
| `shared/scripts/sap_settings_lib.vbs` | **All VBScript skill scripts that need a userConfig value (mandatory — Rule 7)** | VBScript counterpart to `sap_settings_lib.ps1`. Include via `ExecuteGlobal FSO.OpenTextFile("%%SETTINGS_LIB_VBS%%",1).ReadAll()`. Functions: `GetSapSettings()`, `GetSapSettingValue("<key>", "<default>")`, `SetSapUserSetting("<key>", "<value>")`. Uses ScriptControl + JScript for JSON parsing (zero external deps). Writes UTF-8 (no BOM) via ADODB.Stream. |
| `shared/scripts/sap_check_transport.ps1` | sap-se11, sap-se37, sap-se38, sap-se24, sap-se91 | Transport request validation via RFC (NCo 3.1) |
| `shared/scripts/sap_rfc_connect.ps1` | sap-login | Standalone RFC connection probe (NCo 3.1) — thin wrapper around `sap_rfc_lib.ps1` |
| `shared/scripts/sap_dpapi.ps1` | sap-login (Step 2a + 5b) | DPAPI encrypt/decrypt for `sap_password` at rest in `settings.json`. Functions `Protect-SapSecret` / `Unprotect-SapSecret` (dot-source) + CLI mode (`-Action protect\|unprotect -Value <text>`). Encrypted values are stored as `dpapi:<base64>`; CurrentUser scope binds decryption to the Windows user account. Plaintext input passes through with a stderr warning for backward compatibility / migration. |
| `shared/scripts/sap_rfc_lookup_ddic.ps1` | sap-check-abap, sap-check-fm (sidecar) | Generic DDIC type / data-element batch lookup (DDIF_FIELDINFO_GET + DD04L) |
| `shared/scripts/sap_rfc_lookup_fm.ps1` | sap-gen-abap (Step 1.5), sap-check-fm, sap-fix-fm (future) | Fetch FM signatures via RPY_FUNCTIONMODULE_READ_NEW with **per-system disk cache**. Cache layout: `{fm_cache_dir}\<server>_<sysnr>_<client>\<FM_NAME>.tsv`. TTL: 30 days for SAP standard (BAPI_*, RFC_*), 1 day for Z*/Y* (configurable via `userConfig.fm_cache_ttl_*_days`). Skip with `userConfig.fm_cache_enabled=false`. |
| `shared/scripts/sap_log_lib.ps1` | **All PowerShell skill wrappers (optional)** | Structured logger. Dot-source via `%%LOG_LIB_PS1%%`. Functions: `Start-SapLog -Skill -Params`, `Write-SapLog -Run -Level -Step -Message [-Extra]`, `Stop-SapLog -Run -Status -ExitCode [-ErrorClass] [-ErrorObject]`. Honours `userConfig.log_*` keys (JSONL/TSV/TEXT, console echo, redaction, size + date rotation). Run-id propagation via `$env:SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID` for parent/child call-tree analysis. |
| `shared/scripts/sap_log_helper.ps1` | **All Claude-driven skills (optional)** | Thin start/step/end wrapper around `sap_log_lib.ps1`. Persists `run_id` to a JSON state file so a skill made of multiple discrete bash blocks can append to one logical run. Best-effort: silently no-ops on lib-load failure. Wired into every skill in sap-dev-core, sap-gen-code, and sap-tcd via a per-skill **Step 0.5 — Start Logging** block and a closing **Final — Log End** section. |
| `shared/scripts/sap_log_lib.vbs` | **All VBScript skill scripts (optional)** | Structured logger. Include via `ExecuteGlobal FSO.OpenTextFile("%%LOG_LIB_VBS%%",1).ReadAll()`. Functions: `LogStart(skill, paramsArray)`, `LogStep(runId, level, step, msg)`, `LogEnd(runId, status, exitCode, errorMsg)`. Same JSONL/TSV/TEXT formats and redaction as the PS lib. Writes UTF-8 (no BOM) via ADODB.Stream so files concatenate cleanly with PS-emitted lines. |
| `shared/scripts/sap_session_lock.vbs` | **All GUI-scripting VBS reference scripts that perform multi-step writes (mandatory per Rule 7)** | Session-lock helpers. Include via `ExecuteGlobal FSO.OpenTextFile("%%SESSION_LOCK_VBS%%",1).ReadAll()`. Functions: `TryLockSession(sess)` → returns Boolean (False if API unavailable on this SAP GUI build); `ReleaseSession(sess, wasLocked)` — idempotent unlock that ALSO sweeps up to 5 chained orphan modal popups via `sendVKey 12` (F12 / Cancel) before unlocking, so the user never gets a frozen popup on session handover. Wrap source-paste / save / activate / popup-driving critical sections to block in-session focus stealing. Pair with the existing AppActivate-loop guards for SendKeys-based pastes (defence in depth: AppActivate blocks external focus stealing, LockSessionUI blocks internal, the pre-unlock sweep covers leftover modals). |
| `shared/scripts/sap_attach_lib.vbs` | **All GUI-scripting VBS reference scripts that drive SAP GUI** — mandatory for skills being migrated under Tier 3 (parallel-safe session attach). Today's migrated set: `sap-se16n`, `sap-sp02`, `sap-where-used-list`, `sap-gui-diagnose` (Phase 3.1 read-only). | Shared session-attach primitive — **multi-connection aware (Phase 3.5)**. Include via `ExecuteGlobal FSO.OpenTextFile("%%ATTACH_LIB_VBS%%",1).ReadAll()`. Exposes `Function AttachSapSession(sHint)` which resolves the target session in this order: (1) `sHint` (typically the `%%SESSION_PATH%%` token from the calling wrapper); (2) `SAPDEV_SESSION_PATH` env var; (3) `SAPDEV_PIN_FILE` env var → pin file's `session_path` field; (4) sole-connection + sole-session safe default; (5) **refuse loud** with `ERROR: N SAP connections attached; cannot pick one safely. Run /sap-login --remember to pin a default, or pass --session ...`. **Strategies 1, 2, 3 also work cross-connection** — they take full `/app/con[N]/ses[M]` paths and never silently retarget. Strategies 4 and 5 are how single-connection callers stay simple (no behavior change for the 99% case) while multi-connection callers get safe refusal instead of silent miss-targeting. Replaces the ~25-line nested `For Each oCandidate In oApplication.Children` boilerplate that lived in every operational VBS. The convention: each migrated VBS declares `Const SESSION_PATH = "%%SESSION_PATH%%"`, includes this lib, and calls `Set oSession = AttachSapSession(SESSION_PATH)` — one line replaces the entire attach block. Calling skill wrappers (PowerShell) substitute `%%SESSION_PATH%%` with the parsed `--session` argument (or empty), `%%ATTACH_LIB_VBS%%` with the absolute path to this file, AND set `$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'` so the pin-file fallback (strategy 3) works automatically. The unsubstituted-token sentinel is detected via a `Chr(37)`-built runtime string so global wrapper substitution cannot corrupt the comparison (same defence as `sap_gui_object_details.vbs`). Pairs with the broker (`sap_session_broker.ps1`): the broker decides WHICH session a task should use; this lib makes every VBS able to ATTACH to that decision safely across multiple SAP connections. |
| `shared/scripts/sap_session_broker.ps1` | **All GUI-scripting skills that may run in parallel** (today: `/sap-gui-skill-scaffold` parallel path + the 4 Phase-3.1 migrated read-only skills; will become broadly mandatory after Tier 3 migration). Full contract: `shared/rules/sap_session_broker.md`. | SAP GUI Session Broker — **multi-connection aware (v2 schema, Phase 3.5)**. PowerShell, ~600 LOC. Single-binary CLI with five actions — `acquire` / `release` / `discover` / `gc` / `list` — driven by `-Action <name> -WorkTemp <abs-path>` + per-action args. State lives in `{WORK_TEMP}\session_registry.json` (UTF-8 no BOM, nested `connections[]` shape); cross-process concurrency serialized by a named Windows mutex (`SapDevSessionBroker_v2`) acquired through `System.Threading.Mutex` with a 10s timeout for crash recovery. **Connection isolation**: a claim resolved against connection N never returns a session of connection M. Reactive cleanup sweep runs inside every acquire/release across ALL connections, dropping entries on five failure modes — session closed, owner PID dead, TTL expired, per-connection `SystemSessionId` changed (user logged out + back in on that connection only), entire connection closed. Idempotent on re-acquire by `task_id`. Connection-targeting acquire args: `-SessionPath` / `-ConnectionPath` / `-SystemName -Client -User` / `-PinFile` (reads `sap_active_session.json`); resolution falls through to sole-connection auto-default or DENIED. Spawns on demand on the target connection via `/oSESSION_MANAGER` (the only OK-code mechanism verified on S/4HANA 1909 kernel 754; `CreateSession` and bare `/o` no-op). Stdout last line: `ACQUIRED: path=<p> sessionNumber=<n> connection=<c> reused=<bool>` / `RELEASED: path=<p> connection=<c>` / `NOT_FOUND` / `DENIED: <reason>` (exit 1) / `ERROR: <reason>` (exit 2). Auto-rebuilds a v1 registry on first call after upgrade with a `WARN: v1 registry detected` line. Shells out to `sap_session_broker_com.vbs` for every SAP-side operation because PowerShell 7+/.NET 5+ cannot bind the SAP GUI Scripting Engine directly (`Marshal::GetActiveObject` removed in .NET 5+; even 32-bit Windows PowerShell 5.1 fails to resolve the SAPGUI ProgID through the ROT). |
| `shared/scripts/sap_session_broker_com.vbs` | **Internal helper for `sap_session_broker.ps1`** — not intended for direct calls by other skills. | SAP COM helper for the broker. VBScript run via 32-bit `cscript`. Single argv command + JSON-on-stdout protocol. **Multi-connection aware** (Phase 3.5): `INFO` returns ALL attached SAP connections (each with `connection_path` / `description` / `system_name` / `client` / `user` / `language` / `logon_id` + a `sessions[]` array); `SPAWN <connection_path>` spawns on a SPECIFIC connection (drives `/n` + `/oSESSION_MANAGER` on that connection's anchor, returns the newcomer's path + `SessionNumber`); `RESET <session_path>` drives `/n` on a specific session (used by `release` to return to SAP Easy Access); `PROBE <session_path>` does a single-session `findById` + `Info` read (used by acquire's pre-allocation Easy-Access verification). Exit codes: 0 success, 1 usage error, 2 SAP-unreachable, 3 command-level failure (details in JSON `error` field). JSON output is one line per invocation — broker parses with `ConvertFrom-Json`. |
| `shared/scripts/sap_activation_log.vbs` | **SE11 / DDIC GUI-scripting VBS only — do NOT include in SE38/SE37/SE24/SE91 (no equivalent menu in those transactions)** | Activation-log capture. Include via `ExecuteGlobal FSO.OpenTextFile("%%ACTIVATION_LOG_VBS%%",1).ReadAll()`. Functions: `CaptureActivationLog(oSess, sObjectName, sOutDir, kEnter, kBack)` → returns "" on failure or absolute path of saved log file on success; `ExtractTopActivationError(sLogPath)` → returns the top error line from the log (empty string if none). After Activate, when `sbar.MessageType = "E"` or `"A"`, call `CaptureActivationLog` then echo `ACTIVATION_LOG: <path>` and `ACTIVATION_ERROR: <top-error>` so the operator sees the specific failure instead of the generic "refer to log" SAP popup. Walks Utilities > Activation Log → Log > Save Local File via menu indices captured from `C:\Temp\Record_SE11_ActivateErrorLog_01.vbs` (S/4HANA 1909). Re-record on releases that move the menus. The `Utilities > Activation Log` menu is a DDIC-worklist concept and exists ONLY in SE11; SE38/SE37/SE24/SE91 surface activation errors inline in the source-code editor + status bar (read via `wnd[0]/sbar.Text` — already done in those skills). |
| `shared/scripts/sap_gui_security_sidecar.ps1` | **`/sap-dev-init` Step 1b** + any future skill that triggers a local-file IO via SAP GUI | OS-level auto-dismiss for the SAP GUI Security dialog using **Windows UI Automation** (`System.Windows.Automation`) with a **SendKeys fallback**. Bypasses SAP GUI Scripting entirely because the Scripting COM API is fully suspended while the security dialog is modal (confirmed 2026-05: tree dump returns nothing, even for wnd[0]). Detects the dialog by language-agnostic structural fingerprint (≥3 buttons + ≥1 checkbox + ≥1 path-like text element in any window owned by `saplogon.exe` / `sapgui.exe`). Ticks the first checkbox (Remember) via `TogglePattern.Toggle`, then clicks the leftmost button (Allow) via `InvokePattern.Invoke`. SendKeys fallback: `{TAB}{TAB}{TAB} ` to reach + tick checkbox, `+{TAB}+{TAB}+{TAB}{ENTER}` to return to Allow + press. Args: `-TimeoutSeconds 30 [-PollIntervalMs 200] [-LogPath <path>]`. Stdout last line: `DISMISSED:UIA` / `DISMISSED:SENDKEYS` / `TIMEOUT` / `NO_SAP_GUI` / `ERROR: <msg>`. Launch via `Start-Process powershell -NoNewWindow -PassThru -RedirectStandardOutput` BEFORE the dialog-triggering action; give it ~800 ms to load UIA assemblies; then `Wait-Process`. |
| `shared/scripts/sap_gui_security_warmup.vbs` | `/sap-dev-init` Step 1b only | One-shot trigger that drives `oWnd.Hardcopy <PROBE_FILE>` under `{work_dir}` to materialize the SAP GUI Security dialog. Tokens: `%%PROBE_FILE%%`. Stdout last line: `ALLOWED` / `NO_GUI` / `ERROR: <msg>`. Run in foreground; the **PowerShell sidecar** (above) runs in parallel to dismiss the dialog at the OS level. The Hardcopy call blocks until the sidecar acts. |
| `shared/scripts/sap_gui_foreground_guard.ps1` | **All GUI-scripting VBS reference scripts that paste via SendKeys (mandatory — `sap-se38`, `sap-se37`, `sap-se24`, `sap-se91`, future paste-based skills)** | OS-level foreground forcer. Brings the SAP GUI main window to the front so SendKeys lands in SAP, not in whatever app the user is editing in (Notepad, VS Code, browser, Outlook). Uses the `AttachThreadInput` Win32 trick to bypass Windows 7+'s SetForegroundWindow suppression — which is why `WshShell.AppActivate` alone fails reliably even in a 20-retry loop (it returns success while Windows just flashes the taskbar button). Token: `%%FOREGROUND_GUARD_PS1%%`. Args: `-TargetTitle <window-title-substring> [-TimeoutSeconds 5] [-PollIntervalMs 100] [-LogPath <path>]`. Stdout last line: `FOREGROUND:OK:<hwnd>` (exit 0, safe to SendKeys) / `FOREGROUND:STILL_NOT_FG:<hwnd>` (exit 1) / `FOREGROUND:NO_MATCH` (exit 1) / `FOREGROUND:NO_SAP_GUI` (exit 1) / `FOREGROUND:ERROR:<msg>` (exit 1). Caller convention: run synchronously via `oWshSend.Run(<cmd>, 0, True)` just BEFORE the SendKeys block; on non-zero exit, ABORT the paste with a clear error rather than risking the source landing in the user's editor. Pair with `sap_session_lock.vbs` (which locks SAP-side input but does nothing for OS-level focus). |
| `shared/rules/settings_lookup.md` | **ALL skills that read or write a userConfig value (mandatory — Rule 7)** | Two-file model — schema in `settings.json` (tracked, blank values), per-developer overrides in `settings.local.json` (gitignored). Reads merge per-key on the `value` field; writes always target the local file. Path resolution from sap-dev-core skills vs. cross-plugin skills. Implementation paths for PowerShell (`sap_settings_lib.ps1`), VBScript (`sap_settings_lib.vbs`), and Claude-driven Read/Edit-tool flows. |
| `shared/rules/skill_operating_rules.md` | **ALL skills (mandatory)** | Forbids direct SQL writes on SAP standard tables; forbids unsolicited program/report deployment |
| `shared/rules/tr_resolution.md` | **All deploy skills (mandatory)** + `/sap-transport-request` + `/sap-se01` | Transport request resolution flow — `way_to_get_transport_request` (DEFAULT/ASK/CREATE_NEW), `rule_of_tr_description` (ASK/PATTERN/FIXED/RANDOM), 60-char compression |
| `shared/rules/language_independence_rules.md` | **All GUI-scripting skills (mandatory)** | Make VBS work under any logon language — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `shared/rules/sap_session_broker.md` | **All GUI-scripting skills that may run in parallel** — will become broadly mandatory after the Tier 3 attach-helper migration. Today: `sap-gui-skill-scaffold` parallel path + the 4 Phase-3.1 migrated read-only skills. | SAP GUI Session Broker contract (v2, Phase 3.5 — multi-connection aware). Coordinates which AI task drives which SAP GUI session via `acquire` / `release` / `discover` / `gc` / `list` CLI on `sap_session_broker.ps1`. **Connection isolation guaranteed**: a claim resolved against `/app/con[1]` never returns a `/app/con[0]` path; ambiguous acquires (multiple connections, no resolver) are refused loud. Acquire's targeting args (`-SessionPath` / `-ConnectionPath` / `-SystemName -Client -User` / `-PinFile`) determine which connection the session comes from; resolution falls back to sole-connection auto-default for the 99% single-connection case. Cross-process named-mutex (`SapDevSessionBroker_v2`) serialises concurrent callers. Reactive cleanup sweep handles five failure modes — user closes a window, owner process crashes, TTL expires, per-connection logout+relogin, entire connection closed — surfaced as `DROP: <path> reason=<...>` lines. Identity caveat: SAP exposes no stable per-session ID on the kernels tested (`SystemSessionId` is per-logon; `(path, SessionNumber)` recycles together), so the broker uses operational hygiene (Easy-Access verification on every acquire + `findById` re-resolution on every use) instead of identification. Pairs with `shared/scripts/sap_session_broker.ps1` (PowerShell broker) + `shared/scripts/sap_session_broker_com.vbs` (32-bit cscript COM helper — required because PowerShell 7+/.NET 5+ cannot bind to the SAP GUI Scripting Engine directly). |
| `shared/rules/abap_code_quality_rules.md` | sap-gen-abap, sap-check-abap, sap-fix-abap | ABAP code-quality rules — modern syntax, OOP scaffolds, exception classes, performance gates, authz hooks, ABAP Unit, dependency + traceability emission. Driven by the customer brief. |
| `shared/templates/customer_brief.md` | sap-gen-abap (mandatory), sap-check-abap | One-page Project Profile customer fills once: ABAP release, namespace, packages, message class, reusable utilities, volume bands, authz objects, quality bar. Override at `{custom_url}\customer_brief.md`. |
| `shared/templates/customer_brief_sample.md` | reference | Filled-in example of `customer_brief.md` for project HK / `ZHKMM001R01`. Customers copy-and-edit. |
| `shared/templates/spec_template.xlsx` | sap-docs-extract input shape; sap-docs-layout `bootstrap` source | **Canonical design-spec workbook** — 17 content sheets (Cover, Interface Contract, Selection Screen, Selection Definition, Validation Rules, Processing Flow, Mapping (File In)/(File Out), Supplement, Domains, Data Elements, Tables, Error Messages, Text Elements, Golden Tests, Dependencies, README) + a hidden `(Meta) Layout` sheet that maps each section to its output file. Built by `tools/build_spec_template.py`. Customers copy this and fill in their project. |
| `shared/rules/ddic_excel_layout_rules.md` | sap-docs-extract, sap-docs-check-ddic, sap-se11 | 10-rule cheat-sheet for customers writing DDIC specs in Excel. Covers naming-suffix consistency, primitive-type-as-DTEL trap, currency reference, column order, no merged data cells, dropdown advice, self-check formulas, and a 1-page customer checklist. |
| `shared/templates/customer_brief_JA.md` | sap-gen-abap, sap-check-abap | Japanese variant of `customer_brief.md`. Picked up automatically when `userConfig.template_language=JA` (or `userConfig.sap_language=JA` if `template_language` is unset). |
| `shared/templates/customer_brief_sample_JA.md` | reference | Japanese variant of the worked customer-brief example. |
| `shared/templates/spec_template_JA.xlsx` | starting point | **Japanese variant** of `spec_template.xlsx` — Japanese sheet names (`表紙`, `インターフェース契約`, etc.) and field labels. Same `(Meta) Layout` schema; localized `sheet_name`, `source_column_header`, and `anchor_keyword` columns; stable English `key`, `output_file`, and `output_column` columns. Built by `tools/build_spec_template.py --lang JA`. |

### Template Language Resolution

When a skill needs a customer-facing template (`customer_brief.md`,
`spec_template.xlsx`, etc.), it resolves the file in this order, picking
the first hit:

1. **Explicit path argument** (e.g. `--brief <path>` for skills that read the customer brief).
2. **`{custom_url}\<base>_<LANG>.<ext>`** — per-customer language-specific override.
3. **`{custom_url}\<base>.<ext>`** — per-customer language-agnostic override.
4. **`<SAP_DEV_CORE_SHARED_DIR>\templates\<base>_<LANG>.<ext>`** — built-in language variant.
5. **`<SAP_DEV_CORE_SHARED_DIR>\templates\<base>.<ext>`** — built-in default (fallback).

Where `<LANG>` is resolved from:

1. `userConfig.template_language` (explicit override; allowed values: `EN`, `JA`, `ZH`).
2. `userConfig.sap_language` if `template_language` is unset (re-uses the SAP logon language).
3. `EN` if neither is set.

Currently shipped variants (all defaults are clean English):

- `customer_brief.md`             — default (EN) + `_JA`
- `customer_brief_sample.md`      — default (EN) + `_JA`
- `customer_brief_sample.xlsx`    — default (EN) only — `_JA` xlsx variant pending
- `spec_template.xlsx`            — default (EN, English sheet names) + `_JA` (Japanese sheet names)

`_ZH` variants are roadmap. After pilot-customer demand confirms Chinese
need, `tools/build_spec_template.py` (already language-parameterised via
`--lang`) makes adding `--lang ZH` straightforward — just add a `"ZH": {...}`
entry to each dict in `tools/spec_translations.py`. Until then a Chinese
customer should override at `{custom_url}\<base>_ZH.<ext>`.

**Build script is bilingual.** `tools/build_spec_template.py` accepts
`--lang EN` (default) or `--lang JA` and writes to the correctly-suffixed
output path. Translation strings live in `T_*` dicts in
`tools/spec_translations.py`. Adding a third language = add a third entry
to each dict, no other code changes.

### Standalone Package Reassignment

`/sap-change-package <OBJECT_TYPE> <OBJECT_NAME> <NEW_PACKAGE>` moves an
object's `TADIR-DEVCLASS` via the standard Goto > Object Directory Entry
dialog (SE38 / SE37 / SE24 / SE11 / SE91 by type). Three flows handled:
- `$TMP → Z*/Y*` — resolves a TR via `/sap-transport-request`, fills it
  into the dialog or presses Create Request.
- `Z*/Y* → Z*/Y*` — pre-checks `E071` / `E070` to ensure the object isn't
  in a modifiable TR (which would block the move), then enters the new
  package directly.
- `Z*/Y* → $TMP` — confirms with the user, then presses "Local object".

### Standalone ATC Quality Gate

`/sap-atc <OBJECT_TYPE> <OBJECT_NAME> [CHECK_VARIANT] [MAX_PRIORITY]` runs SAP
Code Inspector / ATC against the object via GUI scripting and writes findings
to a TSV (`<OBJECT_NAME>.atc.tsv`). Acts as a quality gate: any finding with
priority ≤ the customer brief's `MAX_PRIORITY` blocks deployment (default 2 =
critical + high block, medium + low warn). Routes by object type the same way
as `/sap-activate-object` (PROGRAM/CLASS/FUGR/FM/INTERFACE/PACKAGE).
**Requires a one-time Scripting Recorder session** to capture the SCI scope
radios + results-grid IDs (PLACEHOLDER constants in
`references/sap_atc_run.vbs`); SKILL.md documents the recording steps.

### Standalone Object Activation

`/sap-activate-object <OBJECT_TYPE> <OBJECT_NAME>` activates an inactive
repository object outside of a deploy flow (e.g. when an object was left
inactive after a failed activation). It routes by type to SE38 / SE37 / SE24
/ SE11, handles the inactive-objects worklist popup (Select All + Continue),
and verifies via `PROGDIR` (programs / FM includes) and `DWINACTIV`. The
inactive-objects worklist popup is filtered by SAP based on the **locality**
(transportable vs local — `TADIR-DEVCLASS` starts with `$`) of the triggering
object.

### Standalone Log Analyzer

`/sap-log-analyze [--since YYYY-MM-DD] [--skill <name>] [--status <CODE>] [--top N] [--csv <path>]`
summarizes JSONL log files written by `sap_log_lib.ps1` / `sap_log_lib.vbs`.
Reads `log_dir` from sap-dev-core settings (default `{work_dir}\logs`) and
prints four sections to stdout:

1. **Overall** — file count, record count, date range, phase totals.
2. **Per-skill summary** — runs / SUCCESS / FAILED / SKIPPED / EXISTED /
   ABANDONED counts plus p50 / p95 `duration_ms`.
3. **Top error_class** — counts, last_seen, sample skills.
4. **Recent FAILED runs** — `run_id`, `parent_run_id` chain, `error_class`,
   truncated `error_msg`.

Read-only; never modifies log files. Only JSONL records are parsed — TSV /
TEXT lines (and any JSON parse failures) are counted as `bad_lines` and
skipped. Use `--csv <path>` to also export the per-skill summary.

### SAP Development Environment Initialization

When any sap-dev skill is invoked and `sap_dev_transport_request` in sap-dev-core settings is blank or not configured, suggest to the user:
> "The SAP development environment has not been initialized. Run `/sap-dev-init` to set up the transport request, package, function group, and deploy utility programs."

The `sap-dev-init` skill orchestrates:
1. `/sap-transport-request` — creates or validates a modifiable transport request
2. `/sap-se21` — creates or validates a development package
3. `/sap-function-group` — creates or validates a function group
4. `/sap-se38` — deploys `ZCMRUPDATE_ADDON_TABLE.abap` utility program

### Work Directory Configuration

All skills resolve a centralized work directory from sap-dev-core's `settings.json` `userConfig`:

| Setting | Default | Purpose |
|---|---|---|
| `work_dir` | `C:\sap_dev_work` | Root working directory |
| `custom_url` | `{work_dir}\custom` | Custom overrides (e.g., `abap_naming_rules.tsv`) |
| `design_docs_url` | `{work_dir}\design_docs` | Design documentation directory |
| `source_code_url` | `{work_dir}\source_code` | Source code repository directory |
| `fm_cache_dir` | `{work_dir}\cache\fm_signatures` | FM signature cache (per-system; see "FM Signature Cache" below) |

Temp files go to `{work_dir}\temp` (referenced as `{WORK_TEMP}` in SKILL.md files).

Every skill includes a **Step 0 — Resolve Work Directory** that reads these settings and creates `{WORK_TEMP}` if needed.

**Custom naming rules override:** Skills that use `abap_naming_rules.tsv` check `{custom_url}\abap_naming_rules.tsv` first. If found, the custom file is used instead of the default in `sap-dev-core/shared/tables/`.

### Transport Request Settings

| Setting | Allowed values | Default | Purpose |
|---|---|---|---|
| `sap_dev_transport_request` | TR number or blank | blank | The default modifiable TR. Read by `/sap-transport-request` under `DEFAULT` mode. |
| `way_to_get_transport_request` | `DEFAULT`, `ASK`, `CREATE_NEW` | `DEFAULT` | TR sourcing policy applied by `/sap-transport-request`. Asked during `/sap-dev-init`. |
| `rule_of_tr_description` | `ASK`, `PATTERN`, `FIXED`, `RANDOM` | `ASK` | How `/sap-se01` builds the description for new TRs. |
| `tr_description_template` | string | blank | Template for `PATTERN` (placeholders) or literal for `FIXED`. Final result truncated to 60 chars. |

### FM Signature Cache Settings

Read by `sap_rfc_lookup_fm.ps1` (used by `sap-gen-abap` Step 1.5 to pre-fetch FM signatures before generation). All keys are optional — defaults below.

| Setting | Allowed values | Default | Purpose |
|---|---|---|---|
| `fm_cache_enabled` | `true` / `false` | `true` | Master switch. When `false`, sap-gen-abap skips Step 1.5 entirely and falls back to AI training knowledge for FM signatures. |
| `fm_cache_dir` | path | `{work_dir}\cache\fm_signatures` | Cache root. Per-system partition: `<fm_cache_dir>\<server>_<sysnr>_<client>\<FM_NAME>.tsv`. |
| `fm_cache_ttl_std_days` | integer | `30` | TTL for SAP standard FMs (`BAPI_*`, `RFC_*`, etc.). SAP standard signatures change rarely across patches; long TTL is safe. |
| `fm_cache_ttl_z_days` | integer | `1` | TTL for `Z*` / `Y*` customer FMs. Customer code changes during dev; short TTL avoids stale signatures driving incorrect generation. |

Cache invalidation is purely TTL-based on file mtime — no metadata file. To force a full re-fetch, delete the cache subfolder for the affected system or pass `--refresh-cache` to `/sap-gen-abap` (when implemented per skill).

Negative cache: if RPY_FUNCTIONMODULE_READ_NEW returns "FM not found," a single `NOT_FOUND` row is cached for the same TTL — prevents repeated misses for typoed FM names.

### SAP GUI Security Settings

| Setting | Allowed values | Default | Purpose |
|---|---|---|---|
| `sap_gui_security_warmup_done` | `true` / `false` | `false` | Set to `true` after `/sap-dev-init` Step 1b successfully persists SAP GUI Security trust for `{work_dir}`. Subsequent `/sap-dev-init` runs skip the warmup when `true`. Reset to `false` (or delete the key) if SAP GUI is reinstalled or a different Windows account starts using sap-dev. |

The warmup persists trust at the SAP GUI level (via the dialog's own "Remember My Decision" checkbox), not in our settings — this flag is only a fast-path skip for re-running `/sap-dev-init`.

### Logging Settings

Read by `sap_log_lib.ps1` / `sap_log_lib.vbs`. All keys are optional — defaults below.

| Setting | Allowed values | Default | Purpose |
|---|---|---|---|
| `log_enabled` | `true` / `false` | `true` | Master switch. When `false`, `Start-SapLog` / `LogStart` still return a run object/id (so wrappers don't crash) but write nothing. |
| `log_level` | `DEBUG`, `INFO`, `WARN`, `ERROR`, `OFF` | `INFO` | Minimum level recorded. |
| `log_dir` | path | `{work_dir}\logs` | Output directory (auto-created). |
| `log_file_pattern` | template | `sap-dev-{YYYYMMDD}.log` | Filename. Placeholders: `{YYYYMMDD}`, `{YYYYMM}`, `{HHMMSS}`, `{HHMM}`, `{RUN_ID}`, `{SKILL}`, `{USER}`, `{SYSTEM}`. Default groups all runs of a day into one file (cheap log analysis); use `sap-dev-{YYYYMMDD}-{HHMMSS}-{SKILL}.log` for one-file-per-invocation (forensic mode — each run gets its own file, easy to diff), or `sap-dev-{YYYYMMDD}-{RUN_ID}.log` for guaranteed uniqueness even when two skills fire in the same second. |
| `log_retention_days` | integer | `30` | Delete `*.log` older than N days (PS1 only, sweep runs ~1-in-50 invocations). `0` = keep forever. |
| `log_format` | `JSONL`, `TSV`, `TEXT` | `JSONL` | On-disk record format. `JSONL` is required for `/sap-log-analyze`. `TSV` writes a header row on first write. `TEXT` is human-readable. |
| `log_console_echo` | `true` / `false` | `false` | Mirror each record to stdout (or stderr for `WARN` / `ERROR`). |
| `log_max_size_mb` | number | `10` | Rotate the active log when it reaches N MB. Rotated files become `{name}.1`, `{name}.2`, ... up to `log_max_backups`. `0` disables size-based rotation. Combines with the daily rotation provided by `{YYYYMMDD}` in `log_file_pattern`. |
| `log_max_backups` | integer | `5` | Number of rotated backups to keep when `log_max_size_mb` triggers. |
| `log_redact_keys` | comma-separated list | `sap_password,password,passwd,pwd,token,secret,api_key` | Param/extra keys whose values are masked as `***` in records (case-insensitive). Recursive into nested hashtables (PS) / param-pair arrays (VBS). |

JSONL records have shape `{ts, run_id, parent_run_id, skill, phase=start|step|end, level, …}`. Errors carry an optional `error_class` enum (e.g. `TR_NOT_MODIFIABLE`, `RFC_LOGON_FAILED`, `GUI_TIMEOUT`). End records carry `status` (`SUCCESS` / `FAILED` / `SKIPPED` / `EXISTED` / `ABANDONED`), `exit_code`, and `duration_ms`. Run-id chaining via env vars `SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID` lets analyzers reconstruct parent → child skill call trees (e.g. `/sap-se11` → `/sap-transport-request` → `/sap-se01`).

### Path Placeholders

| Placeholder | Resolves to |
|---|---|
| `<SKILL_DIR>` | Absolute path to the current skill's directory |
| `<SAP_DEV_CORE_SHARED_DIR>` | Absolute path to `sap-dev-core/shared/` — go 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\shared` |
| `{WORK_TEMP}` | `{work_dir}\temp` — resolved from sap-dev-core `settings.json` `work_dir` (default `C:\sap_dev_work\temp`) |
| `{custom_url}` | Custom overrides directory — resolved from sap-dev-core `settings.json` |
| `<SAP_LOGIN_SKILL_DIR>` | **Deprecated** — use `<SAP_DEV_CORE_SHARED_DIR>` instead |

### Reference Convention in SKILL.md

Skills using shared resources MUST declare them in a `## Shared Resources` section placed immediately after the YAML frontmatter. The section lists each file, its token name (if injected into VBScript), and its purpose.

Token convention: `%%NAMING_RULES%%` for abap_naming_rules.tsv; `%%TEMP_DIR%%` for work temp directory in VBS; `%%RFC_LIB_PS1%%` for the absolute path of `sap_rfc_lib.ps1` (dot-sourced by every RFC-using PowerShell script); `%%LOG_LIB_PS1%%` and `%%LOG_LIB_VBS%%` for the absolute paths of the JSONL logging libraries; `%%SETTINGS_LIB_PS1%%` and `%%SETTINGS_LIB_VBS%%` for the absolute paths of the settings.json + settings.local.json merge helpers (mandatory per Rule 7 — every skill that reads or writes a userConfig value must go through these); `%%SESSION_LOCK_VBS%%` for the absolute path of `sap_session_lock.vbs` (dot-included by every GUI-scripting VBS that performs multi-step writes); `%%ACTIVATION_LOG_VBS%%` for the absolute path of `sap_activation_log.vbs` (dot-included by GUI-scripting VBS that calls Activate / Ctrl+F3 and needs to surface SAP-side activation errors); `%%SHARED_<UPPERCASE_STEM>%%` for new tokens. **Do NOT introduce any VBS-side helper for the SAP GUI Security dialog** — the SAP GUI Scripting COM API is fully suspended while that dialog is modal (every `findById` returns nothing, even `wnd[0]`), so no VBS pattern can dismiss it. Skills that trigger file IO must launch `shared/scripts/sap_gui_security_sidecar.ps1` as a parallel PowerShell process; see the sidecar's row above and `/sap-dev-init` Step 1b for the coordination pattern.

## Getting Help

General Plugin Development: → Use plugin-dev skills
Issues: → File GitHub issues

</coding_guidelines>
