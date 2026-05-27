# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

## [0.3.0] — 2026-05-27

### Syntax-check classifier — locale-aware shared lib (2026-05-27)

- **Bug fixed.** `sap-se38`, `sap-se37`, and `sap-se24` deploy skills silently passed real syntax errors on non-EN logons. The Ctrl+F2 grid's MSGTYPE column is rendered as `"@<HEX-ID>\Q<localized-label>@"` — the label is in the user's logon language. The inline classifier matched only the literal English `"ERROR"` substring (plus `"1"` / `"E"`), so on a ZH logon `@5C\Q错误@` and on JA `@5C\Qエラー@` were classified as non-errors, `SYNTAX_ERRORS: 0` was emitted, the script proceeded to Activate against syntactically-broken code, the popup walker dismissed the "Activate anyway?" SPOP, the verify heuristic accepted screen 101 + empty sbar as success, and the run reported `SUCCESS` while PROGDIR still held `STATE='I'`. Reproduced on 2026-05-27 against ZMMRMAT049R02 (line 21 `TYPE matkl2` — unknown DDIC type) on an S/4HANA 1909 ZH session.
- **New shared lib**: [`shared/scripts/sap_syntax_check_lib.vbs`](plugins/sap-dev-core/shared/scripts/sap_syntax_check_lib.vbs). Three functions:
    - `GetSyntaxErrorWord(sLang)` — returns the SAP-localized "Error" word for the given logon-language code. Accepts both 1-char SAP codes (`E`/`D`/`F`/`S`/`I`/`P`/`1`/`M`/`J`/`3`/`R`) and 2-char ISO codes (`EN`/`DE`/`FR`/`ES`/`IT`/`PT`/`ZH`/`ZF`/`JA`/`KO`/`RU`). Uses `ChrW()` literals so the source stays ASCII.
    - `ExtractIconId(sCell)` — parses `@<HEX-ID>\Q…@` and returns the uppercased ID, locale-independent.
    - `IsErrorMsgType(sCell, sLogonLang)` — two-tier classifier: legacy `"1"` / `"E"` / English `"ERROR"` substring (backward compat) → localized-word `InStr` (primary path on non-EN logons) → icon-ID prefix in `{03, 0A, 5C, AT, AY}` (locale-independent fallback). Empty MSGTYPE returns `False` so continuation/child rows don't double-count.
- **Refactor**: deduplicated five identical 28-line inline `GetSyntaxErrorWord` blocks plus five inline two-tier match sites into a single shared include. Caller VBS files include via `ExecuteGlobal FSO.OpenTextFile("%%SYNTAX_CHECK_LIB_VBS%%",1).ReadAll()` and call `IsErrorMsgType(sCell, sLogonLang)` directly. Net change across 9 files: **−270 lines** (+77 / −347).
- **Token wiring**: SKILL.md PS1 generators for sap-se38 (create + update), sap-se37 (create + update), and sap-se24 (update) substitute `%%SYNTAX_CHECK_LIB_VBS%%` with the absolute path to the shared lib.
- **CLAUDE.md Shared Resources table** updated with a row for the new file describing the contract, calling convention, and the pre-refactor bug history.
- **Affected files**:
    - Added: `plugins/sap-dev-core/shared/scripts/sap_syntax_check_lib.vbs`
    - Modified callers: `sap_se38_create.vbs`, `sap_se38_update.vbs`, `sap_se37_create.vbs`, `sap_se37_update.vbs`, `sap_se24_update.vbs`
    - Modified SKILL.md: `sap-se38/SKILL.md`, `sap-se37/SKILL.md`, `sap-se24/SKILL.md`
    - Modified `CLAUDE.md` (Shared Resources table)
- **Verified end-to-end**: regenerated the update VBS from the refactored template + new shared lib and re-ran against the unchanged broken matkl2 source on ZH S/4HANA 1909. Output: `INFO: Logon language = 'ZH'; matching syntax-error word = '错误'`, `SYNTAX_ERRORS: 1`, `ERROR: Syntax errors found. Fix errors and retry.`, exit code 1 — no activation attempt.

## [0.2.0] — 2026-05-17

### Phase 4.3 — Per-connection settings + universal RFC credential fallback (2026-05-17)

- **Per-connection dev defaults**: `sap_dev_transport_request`, `sap_dev_package`, and `sap_dev_function_group` are now stored per-connection in `runtime/connections.json` under `connections[].dev_defaults`. Fixes silent cross-system contamination where a parallel session on a different SID would overwrite the shared `settings.local.json` keys with an invalid TR for the other system. New helpers in `sap_connection_lib.ps1`: `Get-SapPerConnectionDevKeys`, `Get-SapCurrentDevDefault`, `Set-SapCurrentDevDefault`. `Get-SapSettingValue` (sap_settings_lib.ps1) auto-routes reads for the three system-keyed values through the per-connection store with file-based settings as fallback — existing skills get isolation without code changes.
- **Connect-SapRfc auto-fallback to pinned profile**: `shared/scripts/sap_rfc_lib.ps1::Connect-SapRfc` parameters (`-Client`, `-User`, `-Password`, `-Language`, endpoint fields) are no longer `Mandatory`. When any required value is empty or still a literal `%%TOKEN%%`, the function dot-sources `sap_connection_lib.ps1` and resolves credentials from the AI-session's pinned connection profile (DPAPI-decrypted password via `sap_dpapi.ps1`). All ~19 downstream RFC PS1 templates start working once the user saves a password via `/sap-login` Step 5b — no per-file edits needed. Callers that pass explicit values still take precedence (backward-compatible). Literal-token detection uses `StartsWith('%%') -and EndsWith('%%')`.
- **SE11 create post-activate RFC verify wired**: all 9 `sap-se11/references/sap_se11_*_create.vbs` templates (domain, dataelement, table, structure, tabletype, typegroup, searchhelp, lockobject, view) now call a shared `PostActivateVerifyOrFail` Sub (new `shared/scripts/sap_se11_post_activate_verify.vbs`) which shells out to a new `shared/scripts/sap_se11_post_activate_verify.ps1`. The PS1 reads the pinned connection profile and runs `RFC_READ_TABLE` against the appropriate DDIC catalog (DD01L/DD02L/DD04L/DD25L/DD30L/DD40L). Fail-closed on `INACTIVE` / `MISSING`; soft-warn on `ERROR:` (RFC unavailable). Also promotes `sbar.MessageType="E"|"A"` after Activate from `WARNING (fall-through)` to `ERROR + WScript.Quit 1`. SE11 SKILL.md create-wrapper PS block substitutes two new tokens: `%%POST_ACTIVATE_VERIFY_VBS%%`, `%%POST_ACTIVATE_VERIFY_PS1%%`.
- Legacy `sap-se11/references/sap_se11_verify_active.ps1` is now obsolete (never wired); replaced by the credential-less Phase-4.3 helper.

### Phase 4 — Multi-profile + AI-session pin (2026-05-16)

- **Multi-profile connection store** at `{work_dir}\runtime\connections.json`. Supports multiple saved SAP systems per Windows user, DPAPI-encrypted passwords, identity-based 4-step dedup (SystemName/Client/User → LogonPadEntry / MessageServer / AppServer+SysNr). New `/sap-login` argument modes: `--list`, `--add`, `--switch <id>`, `--set-default <id>`, `--delete <id>`.
- **AI-session pin** tying each Claude Code conversation (and its subagents) to a single SAP connection. Pin enforcement at broker layer refuses cross-connection acquires with a clear error. Mid-session `--switch` releases stale claims on the old connection atomically.
- **Phase 4.1: parent-PID-based AI session id** (`Get-SapAiSessionId` in `sap_connection_lib.ps1`). Walks the process tree skipping script-host processes (powershell, cscript, etc.) until it hits the Claude Code process. Subagents inherit; parallel conversations get distinct ids. Replaces the earlier write-once-if-missing `ai_session_id.txt` approach, which silently shared one id across parallel conversations. Broker auto-resolves `-AiSessionId` — wrappers no longer need bootstrap code.
- **Phase 4.2: `sap_active_session.json` pin file eliminated.** Version info (gui_*, server_*) moved into the connection profile in `connections.json`. Session path resolved live via `Get-SapCurrentSessionPath` (reads broker registry's `ai_sessions` pin + matching connection block). 25+ deploy SKILL.md wrappers migrated from `SAPDEV_PIN_FILE` to `SAPDEV_SESSION_PATH`. `sap_attach_lib.vbs` Strategy 3 (pin-file read) removed.
- **RFC load-balanced login**: `Connect-SapRfc` in `sap_rfc_lib.ps1` now accepts `-MessageServer` + `-LogonGroup` + `-SystemID` as an alternative to `-Server` + `-Sysnr`.
- **MessageServer / LogonGroup / Group / Program / ScreenNumber** captured from `GuiSessionInfo` by `sap_login_capture_active_session.vbs` and broker `INFO`. Stuck-screen tracking on broker entries via `-Action stuck -Program -Screen`.
- **Broker actions added**: `pin`, `unpin`, `set-connection-id`, `stuck`. Broker `release -WasCreated` calls the COM helper's new `CLOSE` action to drop spawned sessions.
- Legacy single-connection settings (`sap_logon_description`, `sap_application_server`, `sap_system_number`, `sap_client`, `sap_user`, `sap_password`, `sap_language`, `sap_pinned_session`) removed from `settings.json` schema. `Import-LegacyConnectionFromSettings` remains as a one-shot migration path for fresh upgrades.

## [0.1.0] — 2026-05-12

Initial public release. Early-access status — APIs and skill arguments may change between 0.x releases without strict semver compatibility. A `1.0.0` will be declared once the API contract is stable and at least one customer has used the toolkit in production for ≥3 months.

### Repository structure
- Monorepo with three plugins under `plugins/`: `sap-dev-core`, `sap-gen-code`, `sap-tcd`.
- Central marketplace catalog at `.claude-plugin/marketplace.json`.
- JSON Schemas for `marketplace.json` and per-plugin `plugin.json` under `schemas/`.

### sap-dev-core (36 skills + `abap-developer` agent)
- SAP GUI Scripting login + DPAPI-encrypted credential storage (`sap-login`).
- BDC execution via RFC `ABAP4_CALL_TRANSACTION` (`sap-call-bdc`).
- Add-on table maintenance via SE16/SM30 (`sap-update-addon`).
- ABAP Workbench drivers: `sap-se01`, `sap-se11`, `sap-se16n`, `sap-se19`, `sap-se21`, `sap-se24`, `sap-se37`, `sap-se38`, `sap-se41`, `sap-se51`, `sap-se54`, `sap-se91`, `sap-snro`, `sap-sp02`, `sap-cmod`.
- Object lifecycle helpers: `sap-activate-object`, `sap-change-package`, `sap-check-fix`, `sap-transport-request`, `sap-function-group`, `sap-where-used-list`.
- Dev-environment lifecycle: `sap-dev-init`, `sap-dev-status`, `sap-dev-clean`.
- Quality + observability: `sap-atc` (4-stage ATC pipeline with Object Set + Run Series + Run Monitor + Manage Results), `sap-log-analyze`.
- GUI utilities: `sap-gui-record`, `sap-gui-object-details`, `sap-gui-diagnose`, `sap-gui-probe` (drives a transaction step-by-step against a natural-language scenario, dumps each screen via the object-details engine, and emits a synthesized replay VBS — skill-authoring aid), `sap-gui-skill-scaffold` (consumes N probe folders for the same TCD and emits a ready-to-test mode-aware skill draft via cross-probe diff; supports `--parallel` to run probes concurrently against multiple SAP GUI sessions).

### Active-session pinning + version capture (2026-05-13)

- `sap-login` Step 6 now captures the active SAP GUI session — connection / session index, system / client / user / language, SAP GUI version (`oApp.MajorVersion`), and server release via `RFC_SYSTEM_INFO` + `CVERS` (S/4HANA 2022, ECC 6.0 EhP8, etc.). When multiple connections are open, asks the user which to pin. Writes `{WORK_TEMP}\sap_active_session.json`.
- Every GUI-using skill reads the pin to resolve its default session — fixes the multi-connection ambiguity (DEV + QAS, DEV/100 + DEV/121) where the implicit `Children(0).Children(0)` could target the wrong system.
- `sap-gui-probe` accepts `--session "/app/con[N]/ses[M]"` for explicit pinning and threads the session path through every dump + action call. `sap_gui_probe_action.vbs` gains an optional `session` field in the action JSON.
- `sap-gui-skill-scaffold --parallel` spawns one Task sub-agent per scenario, each bound to a distinct SAP GUI session (auto-created via `oCon.CreateSession()` up to SAP's default cap of 6). Cap configurable via `--parallel-cap`.
- New shared helper `sap_select_vbs_variant.ps1` for version-aware VBS picking: skills can ship multiple variants tagged by `server_release_marker` (e.g., `sap_se38_update.S4HANA_2022.vbs`) and the selector picks the best match at execution time. Framework only — no existing skill ships variants today; `sap-gui-skill-scaffold` auto-tags emitted files with the captured release.
- New shared `sap_rfc_system_info.ps1` (calls `RFC_SYSTEM_INFO` + `CVERS`) and `shared/tables/sap_release_markers.tsv` (component → canonical marker lookup).
- **Cross-AI-session persistence (opt-in):** `/sap-login --remember` writes the captured `session_path` to `settings.local.json` via `Set-SapUserSetting sap_pinned_session` (per Rule 7 — never to the tracked `settings.json`). Next AI session: consumer skills read the hint via `Get-SapSettingValue`, re-capture GUI fields against the hinted session, and rebuild `{WORK_TEMP}\sap_active_session.json`. Stale-hint guard: if the hinted session no longer resolves via `findById`, the hint is cleared via `Set-SapUserSetting sap_pinned_session ''` and the skill falls through to single-connection silent default or multi-connection refusal.
- RFC wrapper generators: `sap-rfc-wrapper-class`, `sap-rfc-wrapper-fm`.
- `abap-developer` agent: BUILD / FIX / DEPLOY orchestrator that reads a Customer Brief and dispatches the workbench skills.

### sap-gen-code (10 skills)
- Spec ingestion: `sap-docs-extract`, `sap-docs-convert`, `sap-docs-layout`.
- Validation: `sap-docs-check-ddic`, `sap-docs-check-process`, `sap-check-abap`, `sap-check-fm`.
- Generation + auto-fix: `sap-gen-abap`, `sap-fix-abap`, `sap-fix-fm`.

### sap-tcd (3 skills)
- Business process automation: `sap-bp`, `sap-mm01`, `sap-va01`.

### Shared infrastructure (sap-dev-core/shared)
- Reusable PowerShell + VBScript libraries: RFC connection helpers (NCo 3.1), DPAPI secret protection, structured JSONL logging, session-lock + foreground guards for SAP GUI Scripting, OS-level dismissal of the SAP GUI Security dialog via UI Automation.
- Mandatory rule docs: skill operating rules, transport-request resolution policy, SAP GUI language-independence rules, ABAP code-quality rules.
- Customer-facing templates: `customer_brief.md`, `spec_template.xlsx` (EN + JA variants), DDIC Excel layout cheat-sheet.

### Tooling
- `npm run validate:marketplace` — JSON Schema validation via ajv-cli.
- `npm run check:consistency` — verifies all skill directories are registered, manifest versions match, and counts are correct.
- `npm run validate` — runs both of the above.
