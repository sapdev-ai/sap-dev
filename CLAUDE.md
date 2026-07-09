<coding_guidelines>

# SAP GUI Plugins - Project Context

Repository: sap-dev
Purpose: SAP GUI automation plugins for AI coding assistants
Version: 0.7.2 | Plugins: 4 | Last Updated: 2026-07-09

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
  domain skill (e.g. `/sap-check-abap`, `/sap-docs-check`) is the
  intended path.
- ❌ **Substituting a sub-skill's `references/*.vbs` for the skill itself.**
  Delegation is skill→skill: when a SKILL.md says "delegate to `/sap-X`" (e.g.
  `/sap-dev-clean` and `/sap-dev-init` → `/sap-function-group`, `/sap-se11`,
  `/sap-se38`, `/sap-se21`, `/sap-se01`), **invoke `/sap-X` via the Skill tool**
  and read its result — do NOT open and run its reference VBS directly to save
  context. Mode dispatch, release-specific fallbacks, TR resolution and
  post-action verification live in the **SKILL.md**; a reference VBS is only one
  implementation branch. The canonical failure (field, 2026-06-22): running
  `sap_function_group_gui_delete.vbs` bare on ECC6, where it aborts *by design*
  so `/sap-function-group` can fall through to `/sap-se38 delete SAPL<FG>` —
  bypassing the skill turns that fallback-trigger into a false "FG blocked"
  report. (Driving a reference VBS directly is legitimate only for skill
  development/debugging — see the closing paragraph.)

The discipline is "skills first, raw tools second" — not "skills only."
Direct tooling remains valid for genuinely novel problems, exploratory
debugging of skills themselves, and one-off user requests that no skill
covers. The point is to *check first, then choose*, instead of reflexively
reaching for `Bash` and `Read`.

### 7. ALWAYS Use the Settings Merge Helper

User-configurable values for the sap-dev plugins resolve across four tiers,
**highest precedence first**: (0) env var `SAPDEV_AI_WORK_DIR` — bootstrap for
`work_dir` only, durable across plugin updates; (1) `settings.local.json` —
gitignored dev *checkout* override, live only when running from a repo checkout
(`--plugin-dir`); (2) `{work_dir}\runtime\userconfig.json` — machine-global user
overrides + the single skill WRITE target, outside the versioned cache so it
survives updates; (3) `plugins/<plugin>/settings.json` — tracked schema
(blank/default values). **`work_dir` itself** has a dedicated bootstrap chain
(it locates `userconfig.json`, so it can't read it): env var → `settings.local.json`
→ **`%APPDATA%\sapdev-ai\work_dir.txt`** (durable out-of-cache pointer) →
`settings.json` → default. The pointer is the durable mirror of the env var that
ALSO bridges the current AI session (a freshly-set User env var never reaches
already-running processes — host + every sibling subprocess); `set` writes both.
The full contract is in
`plugins/sap-dev-core/shared/rules/settings_lookup.md`. Summary:

- **Reads** merge per-key on `.value`: env (work_dir only) > settings.local.json
  > userconfig.json > settings.json. Never read `settings.json` directly when
  the value matters. PowerShell: `Get-SapSettingValue` from `sap_settings_lib.ps1`.
  Claude Read-tool flow: read the files in that order, first non-empty `.value`
  wins.
- **Writes** (non-per-connection) go to `userconfig.json` — never `settings.json`,
  and not `settings.local.json` (hand-edited dev override). PowerShell:
  `Set-SapUserSetting`. Claude Edit-tool flow: target `{work_dir}\runtime\userconfig.json`.
- **PowerShell only**: tiers 0/2 + the new write target are implemented in
  `sap_settings_lib.ps1`. There is no VBScript settings library — settings are
  resolved in PowerShell and the resolved values are passed into VBS via
  `%%TOKEN%%` substitution + environment variables, so load-bearing reads are
  all PowerShell.
- **Onboarding**: set `SAPDEV_AI_WORK_DIR` (durable root) then run `/sap-login`;
  or `pwsh ./scripts/dev-setup.ps1`. See `docs/settings-local-faq.md` and
  `contributing/local_development_and_testing.md`.

### 8. ALWAYS Write Test Reports to `sap-dev/temp/testReport/`

Any markdown report that documents a test run, a scaffold invocation's
findings, an end-to-end skill exercise, or per-run observations MUST be
written to `sap-dev/temp/testReport/<descriptive-name>_<YYYYMMDD>.md`.

| Directory | Use for |
|---|---|
| `sap-dev/temp/testReport/` | **Test/run reports** — ephemeral per-invocation findings, scaffold test outcomes, skill exercise logs |
| `sap-dev/contributing/` | Shipped architectural rules read by repo authors (e.g. `parallel_safe_session_attach.md`) |
| `sap-dev/docs/` | End-user documentation (getting-started, FAQs) |

Do NOT place test reports under `contributing/` — that path is reserved
for durable architectural docs that the CI gate / repo authors rely on.
Mixing ephemeral test artifacts there pollutes the signal-to-noise.

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
| **Sub-namespace with single dashes — never duplicate the prefix** | `sap-docs-extract`, `sap-rfc-wrapper` | `sap-sap-docs-extract`, `sap_docs_extract` |
| **Use kebab-case** (lowercase, hyphen-separated) | `sap-change-package` | `sap_change_package`, `sapChangePackage`, `SAP-CHANGE-PACKAGE` |
| **Group consistently inside the prefix.** Established sub-namespaces: `sap-docs-*` (spec pipeline), `sap-check-*` / `sap-fix-*` (validation pairs), `sap-gui-*` (GUI utilities), `sap-cc-*` (migration), `sap-se##` / `sap-se##-*` (SAP transactions) | `sap-fix-abap`, `sap-docs-check` | `sap-fm-fix`, `sap-check-docs` |
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

#### Placement rule — `shared/scripts/` vs `skills/<skill>/references/`

A script belongs in `shared/scripts/` ONLY if at least one of these holds
(otherwise it lives in its owning skill's `references/` and is documented in
that SKILL.md's Shared Resources section, not here):

1. **≥2 consumer skills, or any cross-plugin consumer.** sap-dev-core is the
   only cross-plugin distribution vehicle, so anything a satellite plugin's
   skill consumes must be hosted here (e.g. `sap_rfc_lookup_struct.ps1`,
   `sap_check_spec_refs.ps1` — two sap-gen-code skills, no gen-code shared/
   exists).
2. **Platform primitive wired into shared infrastructure** — referenced by a
   shared lib or shared rules contract even with one caller today (e.g.
   `sap_select_vbs_variant.ps1` + `sap_rfc_system_info.ps1` form the
   release-marker loop with `sap_connection_lib.ps1`; `sap_build_kpi.ps1` has
   the `build_metrics.md` contract; `sap_run_with_lock.ps1` is the
   machine-global paste mutex, sibling of the foreground guard, designed for
   any future paste-based skill; the `sap_se*_post_activate_verify` family is
   the cross-skill safety-gate contract — se11's member is also called by
   sap-gui-skill-scaffold — and is maintained as one unit).
3. **Non-driving VBS include-library** (pure `ExecuteGlobal` function lib —
   `sap_attach_lib.vbs`, `sap_session_lock.vbs`, `sap_delete_popups.vbs`,
   `sap_syntax_check_lib.vbs`, `sap_activation_log.vbs`): lives here to stay
   outside the `references/` Tier-3/baseline scan scope. A skill-private
   include lib MAY instead live in `references/` with a `TIER3_EXEMPT_VBS`
   entry (precedent: `sap_se38_content_verify.vbs`).

Enforced by CI in BOTH directions (`check-consistency.mjs`): (a) every file
that IS here must have a row in the table below — HARD ERROR otherwise; (b) a
shared script whose consumers shrink to one same-plugin skill (or zero), with
no wiring from a sibling shared script / shared rules doc, draws a
`shared-placement` WARN telling you to relocate it — clause-2/3 exceptions
carry a reasoned entry in the checker's `SHARED_PLACEMENT_ALLOWLIST`.
Single-consumer scripts relocated 2026-07-03 under this rule:
`sap_se38_content_verify.ps1/.vbs` → sap-se38,
`sap_check_conversion/signatures/spec_coverage.ps1` → sap-check-abap
(sap-dev-core), `sap_session_owner.ps1` + `sap_probe_end_of_run.ps1` →
sap-gui-probe; the zero-consumer `sap_check_transport.ps1` (dead since
v0.1.0 — superseded by `/sap-transport-request`'s built-in E070 validation)
was deleted the same day.

### Current Shared Files

| File | Used By | Purpose |
|---|---|---|
| `shared/tables/abap_naming_rules.tsv` | sap-check-abap, sap-gen-abap, sap-fix-abap | ABAP variable naming prefix conventions (can be overridden via `{custom_url}`) |
| `shared/tables/sap_object_naming_rules.tsv` | sap-check-abap, sap-docs-check, sap-se11, sap-se38, sap-se37, sap-se24 | SAP repository-object naming patterns (PROGRAM/SUBROUTINE/FUNCTION_GROUP/FUNCTION_MODULE/GLOBAL_CLASS/METHOD/DDIC_*/MESSAGE_CLASS/PACKAGE). Customer override at `{custom_url}\sap_object_naming_rules.tsv`. Read by the shared validator below. |
| `shared/scripts/sap_check_object_name.ps1` | sap-check-abap, sap-docs-check, sap-se11, sap-se38, sap-se37, sap-se24 | Shared object-name validator. Inputs: `-ObjectType <KEY> -ObjectName <NAME> [-CustomUrl <path>] [-RulesFile <path>]`. Exit 0 = OK, 1 = VIOLATION (regex mismatch), 2 = UNKNOWN_TYPE / RULES_NOT_FOUND. Resolves rules file via custom override → default. Logs via `sap_log_lib.ps1` when available. |
| `shared/tables/domain_datatypes.tsv` | sap-se11 | Valid SAP DDIC data types with validation rules |
| `shared/tables/spec_conversion_rules.tsv` | sap-docs-convert | Field-name / DDIC-type / flag normalisation rules applied to extracted specs. Categories: `field_rename`, `type_rename`, `flag_mapping`, `schema_migration`. Override per customer at `{custom_url}\spec_conversion_rules.tsv`. |
| `shared/tables/frequently_errors.tsv` | sap-gen-abap (Step 1.5f), sap-error-kb | **TIER-3 seed of the frequently_errors loop** — curated FM / class-method / codegen traps + remedies (the machine-readable mirror of `abap_code_quality_rules.md` §14/§22/§24). Read merged with the two `{custom_url}` tiers. See `shared/rules/frequently_errors.md`. |
| `shared/tables/required_authorizations.tsv` | sap-doctor (auth probe), docs/security.md (§1 mirror) | Per-capability required SAP authorizations (`capability · auth_object · field · values`). Rows sharing `(capability, auth_object)` form one AUTHORITY-CHECK group. Read by `sap-doctor/references/sap_doctor_authz_probe.ps1` (calls `SUSR_USER_AUTH_FOR_OBJ_GET` for the logged-in user). Machine-readable mirror of `docs/security.md §1` — keep in sync. |
| `shared/scripts/sap_rfc_lib.ps1` | **All RFC-using PowerShell scripts (shared library)** | Reusable NCo 3.1 connect/disconnect helpers (`Connect-SapRfc`, `Disconnect-SapRfc`, `Add-RfcField`, `Add-RfcOption`). Dot-sourced via `%%RFC_LIB_PS1%%` token to keep the GAC discovery + `RfcConfigParameters` boilerplate in one place. |
| `shared/scripts/sap_settings_lib.ps1` | **All PowerShell skill wrappers that need a userConfig value (mandatory — Rule 7)** | Settings reader/writer. Dot-source via `%%SETTINGS_LIB_PS1%%`. Functions: `Get-SapSettings` (returns merged object), `Get-SapSettingValue '<key>' '<default>'` (resolved string), `Set-SapUserSetting '<key>' '<value>'` (writes to settings.local.json). Reads merge `settings.local.json` over `settings.json` per-key on the `value` field. All writes go to `settings.local.json` — never to `settings.json`. |
| `shared/scripts/sap_tadir_delete.ps1` | sap-se21 (Step 8a), sap-dev-clean (Step 5) | **TADIR orphan cleanup ("P2" fix)** — deletes an orphaned object-directory row (definition gone, `TADIR` row survives, blocks the package delete) via the dev-init wrapper FM → `TR_TADIR_INTERFACE` (the SAP write API for TADIR; **not** remote-enabled, so it is reached through `Z_GENERIC_RFC_WRAPPER_TBL` as an asXML-serialized dynamic call — no raw SQL on TADIR). Forces `WI_TEST_MODUS=' '` (FM default is `'X'`=dry-run) + `WI_DELETE_TADIR_ENTRY='X'`. **Safety-guarded**: deletes a row ONLY when the object's definition is verifiably gone (DOMA→DD01L, DTEL→DD04L, TABL→DD02L, TTYP→DD40L, VIEW→DD25L, SHLP→DD30L, FUNC→TFDIR, FUGR→TLIBG, PROG/REPS→TRDIR; unmapped→`REFUSED_UNMAPPED`), `REFUSED_DEF_EXISTS` for a live object — so it can never orphan a live object. Authoritative success = a post-delete RFC re-read of TADIR returning zero rows (NOT the wrapper's echo). Args: `-Object/-ObjName` or `-Entries "OBJECT:NAME[,PGMID:OBJECT:NAME]"`, `-Force` (skip the def-gone guard), `-TestOnly` (classify only). 32-bit PS. Stdout: `TADIR: <DELETED\|WOULD_DELETE\|ALREADY_GONE\|REFUSED_DEF_EXISTS\|REFUSED_UNMAPPED\|FAILED> …` + `STATUS: OK deleted=<n> would=<w> gone=<g> refused=<r> failed=<f>`; exit 0/1/2. **Circular-teardown caveat**: cleaning the dev-init package's OWN orphans fails (the wrapper FM was deleted with it) — redeploy via `/sap-dev-init` or clean manually (SE03 / `RSWBO052`). |
| `shared/scripts/sap_rfc_connect.ps1` | sap-login | Standalone RFC connection probe (NCo 3.1) — thin wrapper around `sap_rfc_lib.ps1` |
| `shared/scripts/sap_dpapi.ps1` | sap-login (Step 2a + 5b) | DPAPI encrypt/decrypt for `sap_password` at rest in `settings.json`. Functions `Protect-SapSecret` / `Unprotect-SapSecret` (dot-source) + CLI mode (`-Action protect\|unprotect -Value <text>`). Encrypted values are stored as `dpapi:<base64>`; CurrentUser scope binds decryption to the Windows user account. Plaintext input passes through with a stderr warning for backward compatibility / migration. |
| `shared/scripts/sap_rfc_lookup_ddic.ps1` | sap-check-abap (Step 3 + `fm` dimension sidecar) | Generic DDIC type / data-element batch lookup (DDIF_FIELDINFO_GET + DD04L) |
| `shared/scripts/sap_rfc_lookup_fm.ps1` | sap-gen-abap (Step 1.5), sap-check-abap (`fm` dimension), sap-fix-abap (`fm` fix) | Fetch FM signatures via RPY_FUNCTIONMODULE_READ_NEW with **per-system disk cache**. Cache layout: `{fm_cache_dir}\<server>_<sysnr>_<client>\<FM_NAME>.tsv`. TTL: 30 days for SAP standard (BAPI_*, RFC_*), 1 day for Z*/Y* (configurable via `userConfig.fm_cache_ttl_*_days`). Skip with `userConfig.fm_cache_enabled=false`. |
| `shared/scripts/sap_error_hints.ps1` + `sap_error_hints_lib.ps1` | sap-gen-abap (Step 1.5f, READ), sap-se38/se37/se24 + sap-atc (auto-record, WRITE), sap-error-kb (curate) | **frequently_errors feedback loop** — CLI (`-Action resolve\|record\|curate`) + engine. `resolve` merges 3 tiers (`{custom_url}\frequently_errors.tsv` > `{custom_url}\frequently_errors\<OBJECT>.tsv` > `shared\tables\frequently_errors.tsv`) for the spec's FMs/methods/auth-objects into `_error_hints.txt`. `record` attributes a deploy/ATC error to its FM/METHOD (by source line, locale-independent) and upserts a CANDIDATE row. `curate` lists/promotes/mutes. OFFLINE; dot-source-safe lib (no top-level `param()`). Full contract: `shared/rules/frequently_errors.md`. |
| `shared/scripts/sap_object_resolver.ps1` | **Phase-0 foundation for the delivery-assurance skills** (sap-impact-analysis, sap-transport-readiness, sap-evidence-pack, sap-enhancement-advisor) | Canonical SAP object-identity resolver (RFC, NCo 3.1). `Resolve-SapObject -Destination $dest -Token "<PROGRAM ZMMR001 \| ZMMR001 \| TCODE ME21N \| TR DEVK… \| PACKAGE …>" [-TypeHint] [-Expand] [-ProbeActive]` → `{pgmid, object, obj_name, kind, package, exists, active, system, client, resolved_via, confidence, note}` in the TADIR `OBJECT`-code vocabulary. Dual-use: **dot-source** for the `Resolve-SapObject` function (caller supplies the RFC destination), or run as a **CLI** (creds fall back to the pinned profile via `Connect-SapRfc`, so `-Token` alone works on a logged-in session). Reads `TADIR`/`TFDIR`/`ENLFDIR`/`TSTC`/`E070`/`E071`/`TDEVC` (+ `DWINACTIV` only under `-ProbeActive`); REPOSRC never touched. FMs resolved via TFDIR+ENLFDIR (not TADIR); `-Expand` turns a TR/PACKAGE into one record per contained object. CLI emits `OBJECT: …` lines + `STATUS: RESOLVED\|NOT_FOUND\|AMBIGUOUS\|UNKNOWN_TYPE\|RFC_ERROR`; exit `0`/`1`/`2`/`3`. Token `%%OBJECT_RESOLVER_PS1%%`. |
| `shared/scripts/sap_artifact_lib.ps1` | **Phase-0 foundation for the delivery-assurance skills** | Artifact index / manifest — pure-local (no SAP/RFC). Every analytical skill registers each file it writes so `/sap-evidence-pack` collects them by scope / ticket / date without filesystem scraping. Dot-source for: `New-SapScopeKey -Resolved $obj` (→ `PROG_ZMMR001` / `TR_…` / `PKG_…`); `Get-SapArtifactDir -ScopeKey -Skill [-RunId]` (creates + returns `{artifact_dir}\<scope>\<skill>\<run_id>`); `Register-SapArtifact -Skill -ScopeKey -Kind -Format -Path [-Object] [-Coverage] [-Verdict] [-Ticket] [-Rows] [-Supersedes]` (appends one `sapdev.artifact/1` JSONL record to `{artifact_dir}\index.jsonl`, returns its id); `Find-SapArtifacts [-ScopeKey] [-Since] [-Ticket] [-Kind] [-Skill] [-IncludeSuperseded]` (newest-first with append-order tie-break under same-millisecond ts; explicit `supersedes` honored; bad lines skipped). Shares `run_id` with `sap_log_lib` via `$env:SAPDEV_RUN_ID`. `artifact_dir` resolves `$env:SAPDEV_ARTIFACT_DIR` → `userConfig.artifact_dir` → `{work_dir}\artifacts`. Token `%%ARTIFACT_LIB_PS1%%`. |
| `shared/scripts/sap_finding_lib.ps1` | **Phase-0 foundation for the delivery-assurance skills** | Reconciled finding model — pure-local (no SAP). ONE severity / category / coverage / gate vocabulary that impact-analysis, transport-readiness, ATC, and check-abap map into. `severity` (intrinsic: `BLOCKER>HIGH>MEDIUM>LOW>INFO`) is kept SEPARATE from `gate` (computed by `sap_gate_policy.ps1`). `New-SapFinding -Severity -Category -Detail [-Object] [-Source] [-Coverage CHECKED\|COULD_NOT_CHECK] …` → `sapdev.finding/1`; `New-SapCheckResult -Check [-Findings] [-CouldNotCheck] [-NotApplicable]` → the tri-state honesty contract (`CHECKED_CLEAN\|CHECKED_FINDINGS\|COULD_NOT_CHECK\|NOT_APPLICABLE`) so "couldn't run" is never rendered as "passed". Adapters `ConvertFrom-SapAtcPriority` (1→BLOCKER…4→LOW) + `ConvertFrom-SapCheckAbapSeverity` (ERROR→HIGH…) map existing producers in with no rewrites. `Get-SapVerdict` rolls gated findings up to GO / GO_WITH_WARNINGS / NO_GO (any COULD_NOT_CHECK downgrades a clean GO). `Export-SapFindingsTsv` (header block + columns, UTF-8 **BOM** for Excel) / `Export-SapFindingsJson` (no BOM). Token `%%FINDING_LIB_PS1%%`. |
| `shared/scripts/sap_gate_policy.ps1` | **Phase-0 foundation for the delivery-assurance skills** | Gate computation for the finding model — reads the customer brief's Quality bar (§6), NOT a second policy store. Auto-loads `sap_finding_lib.ps1`. `Get-SapGatePolicy [-BriefPath] [-Strict]` resolves the brief per the Template Language Resolution chain (`{custom_url}\customer_brief_<LANG>.md` → `{custom_url}\customer_brief.md` → shared `customer_brief_<LANG>.md` → shared template) and parses ATC gating (`priority 1+2`→block sev≥HIGH / `priority 1 only`→block sev≥BLOCKER / `no`→non-gating; an unfilled template falls back to the HIGH default) + ABAP-Unit gating (`mandatory`→BLOCK / `nice to have`→WARN) + the `unit_gate_when_no_tests` knob (`block`/`warn`, default WARN; consumed by `/sap-cc-remediate`'s record unit-test gate). Directives are read ONLY from the brief's `| Field | Pick |` tables (prose is ignored); both the EN tokens and the JA tokens of `customer_brief_JA.md` §6 are recognized (codepoint-built regexes keep the .ps1 source pure ASCII). `Set-SapFindingGates -Findings -Policy` sets each `finding.gate` ∈ BLOCK/WARN/INFO via `Resolve-SapGate` (order: COULD_NOT_CHECK caps at WARN → ATC severity threshold → unit → category map → severity fallback → `--strict` promotes LOCK_OTHER_USER / MISSING_DEPENDENCY WARN→BLOCK). Token `%%GATE_POLICY_PS1%%`. |
| `shared/scripts/sap_log_lib.ps1` | **All PowerShell skill wrappers (optional)** | Structured logger. Dot-source via `%%LOG_LIB_PS1%%`. Functions: `Start-SapLog -Skill -Params`, `Write-SapLog -Run -Level -Step -Message [-Extra]`, `Stop-SapLog -Run -Status -ExitCode [-ErrorClass] [-ErrorObject]`. Honours `userConfig.log_*` keys (JSONL/TSV/TEXT, console echo, redaction, size + date rotation). Run-id propagation via `$env:SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID` for parent/child call-tree analysis. |
| `shared/scripts/sap_log_helper.ps1` | **All Claude-driven skills (optional)** | Thin start/step/end wrapper around `sap_log_lib.ps1`. Persists `run_id` to a JSON state file so a skill made of multiple discrete bash blocks can append to one logical run. Best-effort: silently no-ops on lib-load failure. Wired into every skill in sap-dev-core, sap-gen-code, and sap-tcd via a per-skill **Step 0.5 — Start Logging** block and a closing **Final — Log End** section. |
| `shared/scripts/sap_log_lib.vbs` | **All VBScript skill scripts (optional)** | Structured logger. Include via `ExecuteGlobal FSO.OpenTextFile("%%LOG_LIB_VBS%%",1).ReadAll()`. Functions: `LogStart(skill, paramsArray)`, `LogStep(runId, level, step, msg)`, `LogEnd(runId, status, exitCode, errorMsg)`. Same JSONL/TSV/TEXT formats and redaction as the PS lib. Writes UTF-8 (no BOM) via ADODB.Stream so files concatenate cleanly with PS-emitted lines. |
| `shared/scripts/sap_session_lock.vbs` | **All GUI-scripting VBS reference scripts that perform multi-step writes (mandatory per Rule 7)** | Session-lock helpers. Include via `ExecuteGlobal FSO.OpenTextFile("%%SESSION_LOCK_VBS%%",1).ReadAll()`. Functions: `TryLockSession(sess)` → returns Boolean (False if API unavailable on this SAP GUI build); `ReleaseSession(sess, wasLocked)` — idempotent unlock that ALSO sweeps up to 5 chained orphan modal popups via `sendVKey 12` (F12 / Cancel) before unlocking, so the user never gets a frozen popup on session handover. Wrap source-paste / save / activate / popup-driving critical sections to block in-session focus stealing. Pair with the existing AppActivate-loop guards for SendKeys-based pastes (defence in depth: AppActivate blocks external focus stealing, LockSessionUI blocks internal, the pre-unlock sweep covers leftover modals). |
| `shared/scripts/sap_delete_popups.vbs` | **The delete VBS of sap-se37 / sap-se11 / sap-se24 / sap-se38 / sap-se21** | Shared post-delete popup walker. Included by deriving its path from the already-substituted `%%ATTACH_LIB_VBS%%` token (same dir, so no extra generator token): `sDpDir = oDpFso.GetParentFolderName("%%ATTACH_LIB_VBS%%") : ExecuteGlobal oDpFso.OpenTextFile(oDpFso.BuildPath(sDpDir, "sap_delete_popups.vbs"),1).ReadAll()`. Exposes `Function WalkDeletePopups(oSession, objdirPkg, objdirLang, sapTr)` → walks the active window (cap 10), dispatching each modal by DDIC control id ONLY (locale-independent): SAPLSETX language (`ctxtRSETX-MASTERLANG`/`btnPUSH1`), KO007 "Create Object Directory Entry" (ECC6 — fill empty package from `objdirPkg` + 1-char `objdirLang`, else accept pre-filled, else Local Object `btn[7]`), TR prompt (`ctxtKO008-TRKORR`; returns `"ABORT_EMPTY_TR"` when `sapTr` is empty so the caller releases its lock + `WScript.Quit 1`), and a confirm cascade (`btnSPOP-OPTION1` / `btnBUTTON_1` / `tbar[0]/btn[0]` / Enter). Each branch is gated by its control id, so the union is a strict superset of every per-skill loop it replaced and cannot misfire on a screen lacking that control. Pure function library (receives an already-attached `oSession`; does NOT bind the Scripting engine / declare `SESSION_PATH` / include the attach lib / call `AttachSapSession`), so — like `sap_session_lock.vbs` — it is not a "driving" VBS and lives in `shared/scripts/`, outside the `skills/*/references/` scan scope of `scripts/check-consistency.mjs` (no baseline required). se19 (classic + new) and cmod keep their own popup handling (divergent `For pass` / sequential structure + lenient-TR semantics). |
| `shared/scripts/sap_attach_lib.vbs` | **All GUI-scripting VBS reference scripts that drive SAP GUI** — mandatory for the Tier 3 (parallel-safe session attach) contract. | Shared session-attach primitive — **multi-connection aware (Phase 3.5)** + **pin-file-free (Phase 4.2)**. Include via `ExecuteGlobal FSO.OpenTextFile("%%ATTACH_LIB_VBS%%",1).ReadAll()`. Exposes `Function AttachSapSession(sHint)` which resolves the target session in this order: (1) `sHint` (typically the `%%SESSION_PATH%%` token from the calling wrapper); (2) `SAPDEV_SESSION_PATH` env var — set by the SKILL.md wrapper to `Get-SapCurrentSessionPath`'s return; (3) sole-connection + sole-session safe default; (4) **refuse loud** with `ERROR: N SAP connections attached; cannot pick one safely. Run /sap-login to pin a connection, or pass --session ...`. **Strategies 1 and 2 also work cross-connection** — they take full `/app/con[N]/ses[M]` paths and never silently retarget. Strategies 3 and 4 keep single-connection callers simple while multi-connection callers get safe refusal instead of silent miss-targeting. The convention: each migrated VBS declares `Const SESSION_PATH = "%%SESSION_PATH%%"`, includes this lib, and calls `Set oSession = AttachSapSession(SESSION_PATH)`. Calling skill wrappers (PowerShell) substitute `%%SESSION_PATH%%` with the parsed `--session` argument (or empty), `%%ATTACH_LIB_VBS%%` with the absolute path to this file, AND set `$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'` (from `sap_connection_lib.ps1`) so the AI session's pin propagates. Unsubstituted-token sentinel via a `Chr(37)`-built runtime string so global wrapper substitution cannot corrupt the comparison. Pairs with the broker: the broker decides which session belongs to this AI session; the helper lets every VBS attach to that decision safely. |
| `shared/scripts/sap_session_broker.ps1` | **All GUI-scripting skills that may run in parallel** (today: `/sap-gui-skill-scaffold` parallel path + the 4 Phase-3.1 migrated read-only skills; will become broadly mandatory after Tier 3 migration). Full contract: `shared/rules/sap_session_broker.md`. | SAP GUI Session Broker — **multi-connection aware (v2 schema, Phase 3.5)**. PowerShell, ~600 LOC. Single-binary CLI with five actions — `acquire` / `release` / `discover` / `gc` / `list` — driven by `-Action <name> -WorkTemp <abs-path>` + per-action args. State lives in `{WORK_TEMP}\session_registry.json` (UTF-8 no BOM, nested `connections[]` shape); cross-process concurrency serialized by a named Windows mutex (`SapDevSessionBroker_v2`) acquired through `System.Threading.Mutex` with a 10s timeout for crash recovery. **Connection isolation**: a claim resolved against connection N never returns a session of connection M. Reactive cleanup + identity-reconciliation sweep runs inside every acquire/release/discover/gc across ALL connections: it mirrors live SAP identity onto each block (live is source of truth) then drops entries on these failure modes — session closed, owner PID dead, TTL expired, relogin, entire connection closed. A reused `/app/con[N]` slot now hosting a DIFFERENT system is detected by the `(system,client,user)` tuple — NOT `SystemSessionId`, which on the tested kernels is per-workstation, not per-logon, and stays identical across an A→B swap on one slot (the 2026-06-07 stale-identity bug); on a tuple change the block is reset to the live identity and its stale `connection_id` cleared (re-bound on next finalize). Idempotent on re-acquire by `task_id`. Connection-targeting acquire args (Phase 4.1+): broker auto-resolves `-AiSessionId` via parent-PID walk and reads its `ai_sessions[<id>].connection_id` pin. Explicit `-SessionPath` / `-ConnectionPath` / `-SystemName -Client -User` still override; resolution falls through to sole-connection auto-default or DENIED. Spawns on demand on the target connection via `/oSESSION_MANAGER` (the only OK-code mechanism verified on S/4HANA 1909 kernel 754; `CreateSession` and bare `/o` no-op). Stdout last line: `ACQUIRED: path=<p> sessionNumber=<n> connection=<c> reused=<bool>` / `RELEASED: path=<p> connection=<c>` / `NOT_FOUND` / `DENIED: <reason>` (exit 1) / `ERROR: <reason>` (exit 2). Auto-rebuilds a v1 registry on first call after upgrade with a `WARN: v1 registry detected` line. Shells out to `sap_session_broker_com.vbs` for every SAP-side operation because PowerShell 7+/.NET 5+ cannot bind the SAP GUI Scripting Engine directly (`Marshal::GetActiveObject` removed in .NET 5+; even 32-bit Windows PowerShell 5.1 fails to resolve the SAPGUI ProgID through the ROT). |
| `shared/scripts/sap_session_broker_com.vbs` | **Internal helper for `sap_session_broker.ps1`** — not intended for direct calls by other skills. | SAP COM helper for the broker. VBScript run via 32-bit `cscript`. Single argv command + JSON-on-stdout protocol. **Multi-connection aware** (Phase 3.5): `INFO` returns ALL attached SAP connections (each with `connection_path` / `description` / `system_name` / `client` / `user` / `language` / `logon_id` + a `sessions[]` array); `SPAWN <connection_path>` spawns on a SPECIFIC connection (drives `/n` + `/oSESSION_MANAGER` on that connection's anchor, returns the newcomer's path + `SessionNumber`); `RESET <session_path>` drives `/n` on a specific session (used by `release` to return to SAP Easy Access); `PROBE <session_path>` does a single-session `findById` + `Info` read (used by acquire's pre-allocation Easy-Access verification). Exit codes: 0 success, 1 usage error, 2 SAP-unreachable, 3 command-level failure (details in JSON `error` field). JSON output is one line per invocation — broker parses with `ConvertFrom-Json`. |
| `shared/scripts/sap_activation_log.vbs` | **SE11 / DDIC GUI-scripting VBS only — do NOT include in SE38/SE37/SE24/SE91 (no equivalent menu in those transactions)** | Activation-log capture. Include via `ExecuteGlobal FSO.OpenTextFile("%%ACTIVATION_LOG_VBS%%",1).ReadAll()`. Functions: `CaptureActivationLog(oSess, sObjectName, sOutDir, kEnter, kBack)` → returns "" on failure or absolute path of saved log file on success; `ExtractTopActivationError(sLogPath)` → returns the top error line from the log (empty string if none). After Activate, when `sbar.MessageType = "E"` or `"A"`, call `CaptureActivationLog` then echo `ACTIVATION_LOG: <path>` and `ACTIVATION_ERROR: <top-error>` so the operator sees the specific failure instead of the generic "refer to log" SAP popup. Walks Utilities > Activation Log → Log > Save Local File via menu indices captured from `C:\Temp\Record_SE11_ActivateErrorLog_01.vbs` (S/4HANA 1909). Re-record on releases that move the menus. The `Utilities > Activation Log` menu is a DDIC-worklist concept and exists ONLY in SE11; SE38/SE37/SE24/SE91 surface activation errors inline in the source-code editor + status bar (read via `wnd[0]/sbar.Text` — already done in those skills). |
| `shared/scripts/sap_syntax_check_lib.vbs` | **All ABAP-workbench GUI-scripting VBS that parse the Ctrl+F2 syntax-check ALV grid (mandatory — sap-se38, sap-se37, sap-se24; future SE19 / SE91-msg syntax-check paths)** | Locale-aware syntax-check classifier. Include via `ExecuteGlobal FSO.OpenTextFile("%%SYNTAX_CHECK_LIB_VBS%%",1).ReadAll()`. Three functions: `GetSyntaxErrorWord(sLang)` → returns the localized SAP "Error" word for the given logon-language code (EN/DE/FR/ES/IT/PT/ZH/ZF/JA/KO/RU, both 1-char SAP codes and 2-char ISO codes accepted; uses `ChrW()` so the source stays ASCII); `ExtractIconId(sCell)` → parses `@<HEX-ID>\Q<label>@` and returns the uppercased ID; `IsErrorMsgType(sCell, sLogonLang)` → two-tier classifier (legacy "1"/"E" literal → localized-word `InStr` → icon-ID prefix in {03, 0A, 5C, AT, AY}; empty MSGTYPE returns False so continuation/child rows don't double-count). Replaces five copies of the inline classifier in sap_se38_create/update.vbs, sap_se37_create/update.vbs, sap_se24_update.vbs. Pre-refactor (2026-05-27 morning) the inline match was English-only ("ERROR" substring) and silently dropped real errors on ZH/JA logons, producing false `SYNTAX_ERRORS: 0` and proceeding to Activate against syntactically-broken code. The 2-char hex prefix in `@<HEX-ID>\Q…@` is locale-independent — it's the load-bearing path when SAP returns an unmapped logon language. Wrappers (PowerShell) substitute `%%SYNTAX_CHECK_LIB_VBS%%` with the absolute path to this file inside the create/update PS1 generator blocks of the three SKILL.md files. Adding a new ABAP-workbench skill that runs Ctrl+F2? Include this lib instead of re-implementing per-row classification. |
| `shared/scripts/sap_gui_security_sidecar.ps1` | **`/sap-dev-init` Step 1b** + any skill that triggers a local-file IO via SAP GUI (sap-se16n / sap-se38 / sap-se37 / sap-se24 / sap-se11 / sap-sp02 / sap-atc) | OS-level (**Win32**) auto-dismiss for the SAP GUI Security dialog. Runs in a separate process because the Scripting COM API is fully suspended while the dialog is modal. The dialog is a standard `#32770` window titled "SAP GUI Security", **owned** by saplogon — invisible to `FindWindow`-exact (owned) and to UI Automation (SAP GUI doesn't expose it to UIA, which is why the **older UIA sidecar found nothing → silent TIMEOUT**). Detects it via `EnumWindows` (caption match, OR the locale-proof structural test "has both an Allow and a Deny child Button"), then ticks **Remember My Decision** (`SendMessage BM_SETCHECK`) + clicks **Allow** (`SendMessage BM_CLICK`) via `EnumChildWindows` — no focus/foreground dependency. Ticking Remember persists an Allow rule into `saprules.xml` live (no GUI restart). **Dismisses EVERY dialog that appears within its window — not just the first — verifying each one actually closed** (a dismissed `#32770` goes `IsWindowVisible`-false): a first-time source upload raises **two** dialogs in quick succession, so the pre-2026-06-17 single-shot loop (it `exit 0`'d on the first `BM_CLICK` without verifying) left the second one hanging the cscript for minutes; a no-op early click had the same effect. Args: `-TimeoutSeconds 30 [-PollIntervalMs 200] [-LogPath <path>]`. Stdout last line: `DISMISSED:WIN32` (≥1 closed; a preceding `INFO: closed N security dialog(s)` line gives the count) / `FOUND_BUT_STUCK` (dialog seen but the click never closed it — caller must surface, not assume OK) / `TIMEOUT` / `NO_SAP_GUI` / `ERROR: <msg>`. Launch via `Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput <file>` BEFORE the dialog-triggering action; then `Wait-Process` and check the captured verdict for `FOUND_BUT_STUCK`. Full process contract: `shared/rules/sap_gui_security_handling.md`. |
| `shared/scripts/sap_gui_security_warmup.vbs` | `/sap-dev-init` Step 1b only | One-shot trigger that drives `oWnd.Hardcopy <PROBE_FILE>` under `{work_dir}` to materialize the SAP GUI Security dialog. Tokens: `%%PROBE_FILE%%`. Stdout last line: `ALLOWED` / `NO_GUI` / `ERROR: <msg>`. Run in foreground; the **PowerShell sidecar** (above) runs in parallel to dismiss the dialog at the OS level. The Hardcopy call blocks until the sidecar acts. NOTE: Hardcopy is a **write**, so the warmup only ever persists a `w` rule — it does NOT cover reads (`GUI_UPLOAD`). Read coverage is handled by `sap_gui_security_grant.ps1` (below). |
| `shared/scripts/sap_gui_security_grant.ps1` | `/sap-dev-init` Step 1b ("Cover read access" sub-step) + any skill that needs to pre-trust read/write of a directory for **arbitrary programs** | Idempotently merges one well-formed `<directories>` Allow rule into `%APPDATA%\SAP\Common\saprules.xml`, in SAP's native serialization (forward-slash path, rule-level + context-level `<permissions>`/`<action>`, action 0 = Allow). Exists because SAP keys "Remember" rules on the per-program **dynpro**, so neither the warmup (write-only) nor the watcher (narrow per-context) can pre-cover reads from newly generated programs. Args: `-Path <dir-or-file> -Access <rwx combo, default rw> [-AsDirectory] [-System ''] [-Client ''] [-Transaction ''] [-DynproName ''] [-DynproNum ''] [-RulesFile <path>]`. Empty context field = "any" (mirrors SAP's always-empty `<network>`). For the operator's own `{work_dir}` sandbox the intended scope is **any-system** (empty `-System`/`-Client`, plus empty txn/program); pin `-System`/`-Client` only for a least-privilege policy. Any-system grants are a Security-Weaken action the auto-mode classifier guards, so they need explicit operator authorization on first write (idempotent `ALREADY` thereafter). **Context-aware self-heal**: idempotency keys on path **and** an effective any-context shape, so a same-path rule that is malformed (literal `*` contexts or backslash path — SAP silently ignores both) or narrow (per-program context) is purged and replaced rather than mistaken for coverage (the bug that made a single stale `*` rule return `ALREADY` forever while the dialog kept appearing). Minimal textual edit before the final `</rules>` — only stale same-path single-name rules are removed; the rest of the file is byte-preserved, UTF-8 **no BOM**, post-write `[xml]` sanity re-parse. Caller backs up `saprules.xml` first. Stdout last line: `GRANTED: id=<n> …` (new) / `HEALED: … removed=<ids>` (stale same-path rule replaced) / `ALREADY: …` (exit 0) / `ERROR: <msg>` (exit 2). Reload caveat: a SAP Logon already running must restart to pick up the externally-written rule (so after GRANTED/HEALED, restart SAP Logon once — permanent thereafter). |
| `shared/scripts/sap_gui_foreground_guard.ps1` | **All GUI-scripting VBS reference scripts that paste via SendKeys (mandatory — `sap-se38`; this is the ONLY skill that still pastes via clipboard+SendKeys today — `sap-se37`/`sap-se24` upload source via `ctxtDY_FILENAME` GUI file-IO and `sap-se91` writes via the `.Text` API, so they need neither the foreground guard nor the paste mutex; any future paste-based skill)** | OS-level foreground forcer. Brings the SAP GUI main window to the front so SendKeys lands in SAP, not in whatever app the user is editing in (Notepad, VS Code, browser, Outlook). Uses the `AttachThreadInput` Win32 trick to bypass Windows 7+'s SetForegroundWindow suppression — which is why `WshShell.AppActivate` alone fails reliably even in a 20-retry loop (it returns success while Windows just flashes the taskbar button). Token: `%%FOREGROUND_GUARD_PS1%%`. Args: `-TargetTitle <window-title-substring> [-TimeoutSeconds 5] [-PollIntervalMs 100] [-LogPath <path>]`. Stdout last line: `FOREGROUND:OK:<hwnd>` (exit 0, safe to SendKeys) / `FOREGROUND:STILL_NOT_FG:<hwnd>` (exit 1) / `FOREGROUND:NO_MATCH` (exit 1) / `FOREGROUND:NO_SAP_GUI` (exit 1) / `FOREGROUND:ERROR:<msg>` (exit 1). Caller convention: run synchronously via `oWshSend.Run(<cmd>, 0, True)` just BEFORE the SendKeys block; on non-zero exit, ABORT the paste with a clear error rather than risking the source landing in the user's editor. Pair with `sap_session_lock.vbs` (which locks SAP-side input but does nothing for OS-level focus). |
| `shared/scripts/sap_gui_security_precheck.ps1` | sap-se38, sap-se37, sap-se24, sap-se11, sap-se16n, sap-sp02, sap-atc, sap-trace (before GUI file IO) | Read-only `saprules.xml` probe — answers `ALLOWED`/`NOT_COVERED`/`ERROR` for a path+access+context BEFORE the action would raise the SAP GUI Security dialog, so skills pre-arm the sidecar only when actually needed. |
| `shared/scripts/sap_se11_post_activate_verify.ps1` | sap-se11 (all create/update templates, via the VBS shim below) | Self-contained RFC verifier for DDIC activation — resolves the pinned connection and queries the per-type catalog (DD01L/DD04L/DD02L/DD25L/DD30L/DD40L) → `ACTIVE`/`INACTIVE`/`MISSING`/`ERROR`; the UPDATE-path gate fails on ANY pending non-'A' version (a naive active-row check false-passes because UPDATE keeps the old 'A'). |
| `shared/scripts/sap_se11_post_activate_verify.vbs` | sap-se11 (included by templates via `%%POST_ACTIVATE_VERIFY_VBS%%`) | VBS shim that shells to the PS1 verifier after Activate and echoes the machine-readable verify marker + matching `WScript.Quit` code. |
| `shared/scripts/sap_se37_post_activate_verify.ps1` | sap-se37 | RFC verifier for FM activation — checks no `DWINACTIV` row remains AND `SAPL<FG>` is active (ENLFDIR/DWINACTIV/PROGDIR), closing the inactive-function-group false-success. |
| `shared/scripts/sap_se38_post_activate_verify.ps1` | sap-se38 | RFC verifier for program activation — direct `PROGDIR` STATE='A' probe, run via 32-bit PowerShell (the 64-bit shell "no destination" false-success was the 2026-06 finding). |
| `shared/scripts/sap_run_with_lock.ps1` | sap-se38 (clipboard-paste path) | Serializes critical GUI sections behind the machine-global named mutex `SapDevGuiPaste_v1` so parallel sessions cannot interleave clipboard+SendKeys pastes (pairs with the foreground guard above). |
| `shared/scripts/sap_dev_artefacts.ps1` | sap-dev-status, sap-dev-clean | Shared RFC status checker for every sap-dev-init artefact (TR, package, function group, wrapper FM, DDIC parameter structure/table type, utility program) via TLIBG/TDEVC/TFDIR/DD02L/DD40L/PROGDIR/E070/TADIR; emits parseable `ARTEFACT:`/`ANCHOR:`/`CONFIG_MISMATCH:` lines — the dev-defaults anchor guard (dev-clean ABORTS on mismatch) keys off these. |
| `shared/scripts/sap_tr_object_entries.ps1` | sap-se01 (remove-objects), sap-se16n, sap-dev-init, sap-dev-clean | RFC join of `E071` object entries to `E070` status — reports which UNRELEASED transport requests still list the given objects (pre-flight for object deletion / package-move blockage). |
| `shared/scripts/sap_rfc_lookup_struct.ps1` | sap-gen-abap (Step 1.5e), sap-docs-check | Fetches DDIC structure field lists (FIELDNAME/ROLLNAME/DOMNAME/DATATYPE/CONVEXIT/REFTABLE/REFFIELD) via `DDIF_FIELDINFO_GET` with per-system disk cache + TTL (std vs Z namespaces) — writes the `_struct_signatures.txt` cache the check skills reuse. |
| `shared/scripts/sap_rfc_lookup_authz.ps1` | sap-gen-abap (Step 1.5b) | Fetches SU21 authorization-object field lists via `RFC_READ_TABLE` on AUTHX with per-system disk cache + TTL — pre-resolves AUTHORITY-CHECK field names so generation never invents them (the invented-field ATC P2 trap). |
| `shared/scripts/sap_rfc_read_source.ps1` | sap-gen-abap-unit, sap-review-abap, sap-explain-object, sap-fix-incident, sap-compare | Dot-source lib reading ABAP source over RFC via `RPY_*` reads (never `RFC_READ_TABLE` on REPOSRC — that dumps; see `sap_rfc_lib.ps1` guard); exposes `Read-SapAbapSource` + `Get-SapIncludeTree` for programs, FMs, and includes. |
| `shared/scripts/sap_rfc_syntax_check.ps1` | sap-check-abap (`syntax` dimension), sap-se38 / sap-se37 / sap-se24 (deploy gate) | **Headless compiler-level ABAP syntax check** — runs `EDITOR_SYNTAX_CHECK` on a source FILE through `Z_GENERIC_RFC_WRAPPER_TBL` (asXML dynamic call; the FM is not remote-enabled, same bridge as `sap_tadir_delete.ps1` — no raw SQL, read-only). `I_TRDIR` carries `UCCHECK='X'`/`FIXPT='X'`/`SUBC` so a **non-existent** program checks in Unicode mode (RS_SYNTAX_CHECK needed an *existing* Unicode program — the 2026-07-01 line-`-2` gotcha); `ALL_ERRORS='X'` + `O_ERROR_TAB`/`O_WARNINGS_TAB` (PTYPENAME `RSYNTMSGS` = STANDARD TABLE OF `RSLINLMSG`) return EVERY finding, not just the first. **Parse gotcha**: the wrapper's output XML carries a leading BOM + `<?xml utf-16?>` prolog and serializes table rows with the row-structure name (`<RSLINLMSG>`, not `<item>`) — strip to `<asx:abap` before `[xml]`, iterate `DATA`'s children. Self-contained programs (`-Subc 1`) check standalone; FM includes (`-Subc F -Wrap`) and class/interface pools (`-Subc K -Wrap`) are not standalone-compilable, so **`-Wrap` mode** (Strategy A, proven live S4D 2026-07-04) re-presents the fragment as a self-contained program to syntax-check the **body** pre-insert with zero SAP writes, **line-mapping findings back to the original file** (class = strip class-pool `PUBLIC` + prepend `REPORT`; FM = synthesize the interface as `DATA` decls + body under `START-OF-SELECTION`). A signature too complex to model (generic/untyped param, uncompilable type) degrades to `COULD_NOT_CHECK` — never a false-fail; the deploy skill's in-context Ctrl+F2 after an inactive insert stays authoritative. Args `-SourceFile -ProgramName -Subc <1\|K\|F\|I\|M> [-Wrap] -Uccheck -Fixpt -AllErrors -OutTsv`. 32-bit PS. Stdout `SYNTAX: ERROR\|WARN LINE=.. COL=.. INC=.. MSG=..` + `STATUS: CLEAN\|FINDINGS errors=<e> warnings=<w>` / `COULD_NOT_CHECK <reason>` / `RFC_ERROR` / `INPUT_ERROR`; exit 0 = ran (incl. COULD_NOT_CHECK), 1 = wrapper/FM fail, 2 = connect/input. Token `%%RFC_SYNTAX_CHECK_PS1%%`. |
| `shared/scripts/sap_rfc_system_info.ps1` | sap-login (profile finalize) | Captures server release identity via `RFC_SYSTEM_INFO` + a `CVERS` read and resolves the canonical `server_release_marker` (e.g. `S4HANA_2022`) stored on the connection profile — the input `sap_select_vbs_variant.ps1` scores against. |
| `shared/scripts/sap_readiness_probe.ps1` | sap-doctor (READINESS_CAP check), sap-migrate:sap-cc-analyze (Step 1.5 preflight) | Read-only RFC probe: can this system run an S/4-readiness ATC check? `Get-SapReadinessCapability` (dot-source) / CLI → `READINESS: verdict=READINESS_CAPABLE\|NO_READINESS_VARIANTS\|RFC_ERROR` from `SCICHKV_HD` variant presence. Only `variants==0` is a reliable pre-signal; `READINESS_CAPABLE` means a run is *possible*, NOT that it will find things (a local S/4-target run plan-errors — observed live on 1909 AND 2022). NOT keyed on `SYCM_*` tables or target-variant richness (both proven false signals, 2026-07-03 harvest); the authoritative catch is `/sap-atc`'s `ATC_PLAN_ERRORS` (COUNT_PLNERR>0). |
| `shared/scripts/sap_select_vbs_variant.ps1` | sap-gui-skill-scaffold (+ any future release-variant skill) | Version-aware VBS variant picker — scores `references/*.vbs` variants against the pinned connection's `server_release_marker` + GUI version with exact / server / kernel-fallback / gui-only / default tiers. |
| `shared/scripts/sap_check_spec_refs.ps1` | sap-docs-check | Offline `(TABLE, FIELD)` reference validator — reads TSV request triples, validates each against the struct-signature cache, appends `ERROR`/`WARNING` rows to the check-result TSV. |
| `shared/scripts/sap_build_kpi.ps1` | sap-log-analyze (KPI enrichment) | Offline first-pass-yield aggregator — clusters JSONL log runs into logical builds and rolls up KPI metrics (first-pass yield, fix-loop counts); no RFC, no SAP session. |
| `shared/rules/settings_lookup.md` | **ALL skills that read or write a userConfig value (mandatory — Rule 7)** | Two-file model — schema in `settings.json` (tracked, blank values), per-developer overrides in `settings.local.json` (gitignored). Reads merge per-key on the `value` field; writes always target the local file. Path resolution from sap-dev-core skills vs. cross-plugin skills. Implementation paths for PowerShell (`sap_settings_lib.ps1`) and Claude-driven Read/Edit-tool flows. |
| `shared/rules/skill_operating_rules.md` | **ALL skills (mandatory)** | Forbids direct SQL writes on SAP standard tables; forbids unsolicited program/report deployment |
| `shared/rules/error_classes.md` | **All skills that emit `status=FAILED` log records** + `/sap-log-analyze` + customer log/alerting consumers | The `error_class` taxonomy — single source of truth for the machine-readable failure vocabulary (`ATC_*`, `AUNIT_*`, `CC_*`, `STMS_*`, generic infra classes). Stable-once-shipped; new classes are added HERE in the same commit that starts emitting them. |
| `shared/rules/tr_resolution.md` | **All deploy skills (mandatory)** + `/sap-transport-request` + `/sap-se01` | Transport request resolution flow — `way_to_get_transport_request` (DEFAULT/ASK/CREATE_NEW), `rule_of_tr_description` (ASK/PATTERN/FIXED/RANDOM), 60-char compression |
| `shared/rules/language_independence_rules.md` | **All GUI-scripting skills (mandatory)** | Make VBS work under any logon language — identify by component ID + DDIC field name, status-bar checks via `MessageType` codes (S/W/E/I/A), VKey instead of menu-text, no branching on `.Text`/`.Tooltip`/window titles |
| `shared/rules/sap_gui_scripting_reference.md` | **GUI-scripting skill authors** — `sap-gui-probe` (`--record` / Mode R), `sap-gui-skill-scaffold`, workbench VBS | SAP GUI component-ID grammar + type-prefix / VKey / toolbar tables + runtime gotchas (AbapEditor status-bar swallow, popup detection). Scripting-API cheat-sheet promoted from the retired `sap-gui-record` skill; used to decode a driven or recorded VBS into findById paths. |
| `shared/rules/sap_session_broker.md` | **All GUI-scripting skills that may run in parallel** — will become broadly mandatory after the Tier 3 attach-helper migration. Today: `sap-gui-skill-scaffold` parallel path + the 4 Phase-3.1 migrated read-only skills. | SAP GUI Session Broker contract (v2, Phase 3.5 — multi-connection aware). Coordinates which AI task drives which SAP GUI session via `acquire` / `release` / `discover` / `gc` / `list` CLI on `sap_session_broker.ps1`. **Connection isolation guaranteed**: a claim resolved against `/app/con[1]` never returns a `/app/con[0]` path; ambiguous acquires (multiple connections, no resolver) are refused loud. Acquire's targeting args (`-SessionPath` / `-ConnectionPath` / `-SystemName -Client -User` / `-PinFile`) determine which connection the session comes from; resolution falls back to sole-connection auto-default for the 99% single-connection case. Cross-process named-mutex (`SapDevSessionBroker_v2`) serialises concurrent callers. Reactive cleanup + identity-reconciliation sweep mirrors live identity onto each block then handles these failure modes — user closes a window, owner process crashes, TTL expires, relogin (incl. a slot reused by a DIFFERENT system, detected by the `(system,client,user)` tuple), entire connection closed — surfaced as `DROP: <path> reason=<...>` lines. Identity caveat: SAP exposes no stable per-session ID on the kernels tested — `SystemSessionId` is **per-workstation, not per-logon** (it does NOT change across a logout+relogin or an A→B system swap on one slot), and `(path, SessionNumber)` recycles together — so the broker keys connection identity on the `(system,client,user)` tuple and uses operational hygiene (Easy-Access verification on every acquire + `findById` re-resolution on every use) instead of a session id. Pairs with `shared/scripts/sap_session_broker.ps1` (PowerShell broker) + `shared/scripts/sap_session_broker_com.vbs` (32-bit cscript COM helper — required because PowerShell 7+/.NET 5+ cannot bind to the SAP GUI Scripting Engine directly). |
| `contributing/parallel_safe_session_attach.md` (repo-level, NOT shipped with the plugin) | **All authors writing new SAP-driving VBS templates (mandatory; enforced by CI gate in `sap-dev/scripts/check-consistency.mjs`)**. Read this BEFORE writing a new operational `.vbs` under `plugins/<plugin>/skills/<skill>/references/`. Lives outside the plugin because it has zero runtime callers — end users installing the plugin from marketplace don't need it. | Architectural contract for the **per-VBS attach pattern** (layer 1) that's complementary to the broker contract above; the doc now also summarizes the other three parallel-safety layers (layer 2 temp buckets, layer 3 per-session dev defaults, layer 4 per-session logs). Every SAP-driving VBS template must: (1) declare `Const SESSION_PATH = "%%SESSION_PATH%%"`, (2) `ExecuteGlobal`-include `%%ATTACH_LIB_VBS%%`, (3) call `Set oSession = AttachSapSession(SESSION_PATH)` — and nothing else for attach. Every wrapping SKILL.md PS block must substitute the two new tokens and set `$env:SAPDEV_SESSION_PATH` via `Get-SapCurrentSessionPath` (Phase 4.2). The rule doc spells out the canonical VBS pattern + the canonical SKILL.md wrapper convention as copy-paste blocks, lists the 7 exempt files (`sap_login.vbs`, `sap_check_gui_login_status.vbs`, `sap_gui_security_warmup.vbs`, `sap_login_capture_active_session.vbs`, `sap_gui_object_details.vbs`, `sap_gui_probe_action.vbs`, `sap_attach_lib.vbs`) and why each is exempt, documents the four common gotchas (`Chr(37)` sentinel idiom, include order with session-lock, helper handles all error paths, `SAPDEV_SESSION_PATH` is read via env var), and ends with the CI verification command. **The CI gate fires on seven conditions** — five for session attach (legacy `For Each` idiom present, `SESSION_PATH` declared without `%%ATTACH_LIB_VBS%%` include, operational VBS with neither token (unmigrated), include without `AttachSapSession(...)` call (dead code), or wrapping SKILL.md missing the substitution when the template needs it) plus two for the run-temp model (a SKILL.md passing `{RUN_TEMP}` to `Get-SapCurrentSessionPath -WorkTemp` — hard error; a SKILL.md writing fixed-named generated scratch under the `{WORK_TEMP}` root instead of `{RUN_TEMP}` — warning). **History tail** at the bottom of the rule doc traces the chronology (3.0 helper → 3.1 read-only → 3.5 multi-conn → 3.2/3/4 bulk → 3.6 CI gate → 2026-06-20 layers 2–4: temp buckets / dev defaults / logs). Read this when joining the project or adding the first new SAP-driving skill. |
| `contributing/golden_screen_baselines.md` (repo-level, NOT shipped with the plugin) | **All authors adding/maintaining a SAP-driving VBS** — defines the screen-fingerprint baseline contract enforced by the coverage gate in `sap-dev/scripts/check-consistency.mjs`. Half 1 (static) of the GUI-robustness harness; half 2 is the `/sap-doctor --screens` live skill (PowerShell orchestrator `sap_screen_check.ps1` + self-resolving probe `sap_screen_check_probe.vbs`). | Per-VBS golden-screen baseline `references/<stem>.screens.json` (schema `sapdev.screenbaseline/1`): `{ schema, vbs, captured_on{release,kernel,date,method}, checkpoints[]{id, reach, identity{program,dynpro}, required_ids[<findById paths>], status} }`. Records the control IDs + screen identity each VBS depends on per checkpoint so drift (a release/locale that moved a control) is caught BEFORE a user hits a silent false-success. **CI gate** (driving VBS = declares `Const SESSION_PATH` / includes `%%ATTACH_LIB_VBS%%` / calls `AttachSapSession` / binds the Scripting engine, minus the Tier-3 exempt set): **WARN** on a missing baseline (ratcheting `screen-baseline coverage N/M`, does not break the build), **HARD error** on a malformed one. `status` ∈ `captured` (identity verified live) \| `pending_live` (static dependency-set seed, identity captured on first `/sap-doctor --screens` run). Coverage is now 120/121 driving VBS (only `sap-stms`'s `sap_stms_import.vbs` unbaselined); most checkpoints remain `pending_live` (static dependency-set seeds), flipping to `captured` as `/sap-doctor --screens` verifies identity live per release. Promote missing→hard-error once coverage hits 100%. |
| `shared/rules/abap_code_quality_rules.md` | sap-gen-abap, sap-check-abap, sap-fix-abap | ABAP code-quality rules — modern syntax, OOP scaffolds, exception classes, performance gates, authz hooks, ABAP Unit, dependency + traceability emission. Driven by the customer brief. |
| `shared/rules/frequently_errors.md` | sap-gen-abap, sap-se38/se37/se24, sap-atc, sap-error-kb | Contract for the **frequently_errors feedback loop** — 3 tiers + precedence, schema, statuses (CONFIRMED/CANDIDATE/MUTE), read path (gen Step 1.5f), write path (deploy/ATC auto-record), curation. The data layer of the trap knowledge in `abap_code_quality_rules.md`. |
| `shared/templates/customer_brief.md` | sap-gen-abap (mandatory), sap-check-abap | One-page Project Profile customer fills once: ABAP release, namespace, packages, message class, reusable utilities, volume bands, authz objects, quality bar. Override at `{custom_url}\customer_brief.md`. |
| `shared/templates/customer_brief_sample.md` | reference | Filled-in example of `customer_brief.md` for project HK / `ZHKMM001R01`. Customers copy-and-edit. |
| `shared/templates/spec_template.xlsx` | sap-docs-extract input shape; sap-docs-layout `bootstrap` source | **Canonical design-spec workbook** — 17 content sheets (Cover, Interface Contract, Selection Screen, Selection Definition, Validation Rules, Processing Flow, Mapping (File In)/(File Out), Supplement, Domains, Data Elements, Tables, Error Messages, Text Elements, Golden Tests, Dependencies, README) + a hidden `(Meta) Layout` sheet that maps each section to its output file. Built by `tools/build_spec_template.py`. Customers copy this and fill in their project. |
| `shared/rules/ddic_excel_layout_rules.md` | sap-docs-extract, sap-docs-check, sap-se11 | 10-rule cheat-sheet for customers writing DDIC specs in Excel. Covers naming-suffix consistency, primitive-type-as-DTEL trap, currency reference, column order, no merged data cells, dropdown advice, self-check formulas, and a 1-page customer checklist. |
| `shared/templates/customer_brief_JA.md` | sap-gen-abap, sap-check-abap | Japanese variant of `customer_brief.md`. Picked up automatically when `userConfig.template_language=JA` (or `userConfig.sap_language=JA` if `template_language` is unset). |
| `shared/templates/customer_brief_sample_JA.md` | reference | Japanese variant of the worked customer-brief example. |
| `shared/templates/spec_template_JA.xlsx` | starting point | **Japanese variant** of `spec_template.xlsx` — Japanese sheet names (`表紙`, `インターフェース契約`, etc.) and field labels. Same `(Meta) Layout` schema; localized `sheet_name`, `source_column_header`, and `anchor_keyword` columns; stable English `key`, `output_file`, and `output_column` columns. Built by `tools/build_spec_template.py --lang JA`. |
| `shared/templates/migration_brief.md` | sap-cc-campaign (`/sap-cc-campaign init`) | One-page **Migration Campaign Brief** — distinct from `customer_brief.md`. Profiles one S/4HANA custom-code migration campaign: source / sandbox / remote-ATC connection profiles, source→target release, in-scope packages, decommission policy, quality gates. Override at `{custom_url}\migration_brief.md`. |
| `shared/templates/migration_brief_sample.md` | reference | Filled-in example of `migration_brief.md` (brownfield `ECC6 EhP8 → S/4HANA 2023`). |
| `plugins/sap-migrate/shared/knowledge/` — `catalog.tsv`, `object_map.tsv`, `field_map.tsv`, `api_replacements.tsv`, `recipes/*.md`, `README.md` | sap-cc-triage, sap-cc-remediate | **Simplification Knowledge Pack** — ships with the **sap-migrate** plugin (NOT sap-dev-core/shared). `catalog.tsv` is the pattern index `/sap-cc-triage` joins findings to (`pattern` / `tier` / `detect_*` / `confidence`); the maps + `recipes/<pattern>.md` drive R2/R3 remediation; `/sap-cc-triage --learn` feeds real `detect_message_ids` back. Customer override at `{custom_url}\knowledge\`; join contract in its `README.md`. |

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

When `<LANG>` resolves to `EN`, tiers 2 and 4 are skipped — the base
(unsuffixed) file IS the EN variant, so no `_EN` files exist or are probed.

Currently shipped variants (all defaults are clean English):

- `customer_brief.md`             — default (EN) + `_JA`
- `customer_brief_sample.md`      — default (EN) + `_JA`
- `customer_brief_sample.xlsx`    — default (EN) only — `_JA` xlsx variant pending
- `spec_template.xlsx`            — default (EN, English sheet names) + `_JA` (Japanese sheet names)
- `migration_brief.md` (+ `_sample`)  — default (EN) only (sap-migrate); `_JA` / `_ZH` pending

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

`/sap-atc <OBJECT_TYPE> <OBJECT_NAME> [--variant=<NAME>] [--max-priority=<n>]`
(batch: `--object-list=<file>`) drives the full ATC pipeline via GUI scripting:
builds an SCI Object Set scoped to the target(s), creates and executes an ATC
Run Series bound to that set, polls the ATC Run Monitor until the run
completes, then reads the Priority 1/2/3 finding counts from Manage Results
(best-effort result-TXT download; on FAIL — or with `--drill` — a Stage-4b
drill exports the per-finding ALV as `<save-to>.findings.tsv`). Gate: any
priority ≤ `--max-priority` (default 2, or the customer brief's
`MAX_PRIORITY`) with count > 0 fails; emits
`PRIORITY_COUNTS: P1=<n> P2=<n> P3=<n>` plus `GATE_VERDICT: PASS|FAIL`.
Fail-loud guards: `COUNT_PLNERR` > 0 fails with `ATC_PLAN_ERRORS` (counts
untrustworthy, never PASS), and a 0/0/0 result only passes when the run
demonstrably checked ≥ 1 object (`ATC_EMPTY_SCOPE` otherwise — a pre-flight
object resolver aborts before any scope is built). Object types: PROGRAM /
CLASS / INTERFACE / FUGR / DDIC / TYPEGROUP / WDYN; `FM` is intentionally
rejected (SCI Object Sets have no per-FM category — pass
`FUGR <function-group-name>` instead). No one-time setup: the per-stage VBS
references are recorded against the S/4HANA 1909 ATC layout — if a stage
fails on a release with different tree-node / grid-column IDs, re-record that
stage via `/sap-gui-probe --record` and patch its VBS.

### Standalone Object Activation

`/sap-activate-object <OBJECT_TYPE> <OBJECT_NAME>` activates an inactive
repository object outside of a deploy flow (e.g. when an object was left
inactive after a failed activation). It routes by type to SE38 / SE37 / SE24
/ SE11, handles the inactive-objects worklist popup (Continue only — the
triggering object arrives pre-selected; Select All is never pressed because
it would co-activate other developers' unrelated inactive objects on a
shared DEV), and verifies via `PROGDIR` (programs / FM includes) and
`DWINACTIV`. The
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

### Standalone frequently_errors Curator

`/sap-error-kb [list [--all] | promote <OBJECT> <KEY> | mute <OBJECT> <KEY> | show <OBJECT>]`
curates the team frequently_errors knowledge base — the per-object store of
recurring FM / class-method / codegen traps that `/sap-gen-abap` reads (Step
1.5f) to steer generation. Deploy skills (`/sap-se38`, `/sap-se37`,
`/sap-se24`) and `/sap-atc` auto-record new FM/METHOD errors here as
`CANDIDATE` rows; this skill lets a human review them, fill in the remedy
(`CORRECT_PATTERN`), and `promote` to `CONFIRMED` (or `mute` the noise). Only
`CONFIRMED` rows reach generation by default. Pure-local — reads/writes
`{custom_url}\frequently_errors\`; no SAP connection. Full contract in
`shared/rules/frequently_errors.md`.

### SAP Development Environment Initialization

When any sap-dev skill is invoked and `sap_dev_transport_request` in sap-dev-core settings is blank or not configured, suggest to the user:
> "The SAP development environment has not been initialized. Run `/sap-dev-init` to set up the transport request, package, function group, and deploy utility programs."

The `sap-dev-init` skill orchestrates:
1. `/sap-transport-request` — creates or validates a modifiable transport request
2. `/sap-se21` — creates or validates a development package
3. `/sap-function-group` — creates or validates a function group
4. `/sap-se38` — deploys `ZCMRUPDATE_ADDON_TABLE.abap` utility program

### Work Directory Configuration

All skills resolve a centralized work directory via `Get-SapWorkDir`
(`sap_connection_lib.ps1`):

| Setting | Default | Purpose |
|---|---|---|
| `work_dir` | `C:\sap_dev_work` | Root working directory |
| `custom_url` | `{work_dir}\custom` | Custom overrides (e.g., `abap_naming_rules.tsv`) |
| `design_docs_url` | `{work_dir}\design_docs` | Design documentation directory |
| `source_code_url` | `{work_dir}\source_code` | Source code repository directory |
| `artifact_dir` | `{work_dir}\artifacts` | Delivery-assurance output root + `index.jsonl` manifest (runtime override: env var `SAPDEV_ARTIFACT_DIR`) |
| `fm_cache_dir` | `{work_dir}\cache\fm_signatures` | FM signature cache (per-system; see "FM Signature Cache" below) |

**`work_dir` resolution order:** env var `SAPDEV_AI_WORK_DIR` →
`settings.local.json` → **`%APPDATA%\sapdev-ai\work_dir.txt`** (durable
out-of-cache pointer) → `settings.json` → default `C:\sap_dev_work`. The env var
and the pointer are the durable, update-proof roots: the plugin cache is
versioned per release (so a custom `work_dir` set only in `settings.local.json`
or hand-written into `settings.json` is lost on update), but neither of these is.
`/sap-login` onboarding (`sap_workdir_setup.ps1 -Action set`) writes **both** —
the env var for external shells / future sessions, and the pointer file for the
**current** session: a freshly-set *User* env var never reaches already-running
processes (this host + every sibling PowerShell it spawns, one per skill call),
so without the pointer the next skill falls back to `C:\sap_dev_work`. The
pointer is read fresh by every subprocess, so a work_dir chosen mid-session
sticks for every later skill. Everything stable under `work_dir` —
`connections.json`, dev defaults, logs, `userconfig.json` — keeps resolving
across updates. `work_dir` is the bootstrap pointer and is therefore NOT read
from `userconfig.json` (which lives under it).

Temp files go to `{work_dir}\temp` (referenced as `{WORK_TEMP}` in SKILL.md files).
Each skill invocation ALSO mints a fresh per-run scratch subdir
`{work_dir}\temp\run_<id>` via `Get-SapRunTemp` (referenced as `{RUN_TEMP}`); the
skill writes its OWN generated wrappers / `_run.json` state / scratch there so
concurrent runs (parallel sub-agents, multi-connection deploys) never collide on
fixed names. `{WORK_TEMP}` stays the **base** dir, used for the session broker and
`Get-SapCurrentSessionPath -WorkTemp` (which derive `{work_dir}\runtime` from its
parent — passing them the run dir would relocate the registry). See
`shared/scripts/sap_connection_lib.ps1` (`Get-SapRunTemp` / `Remove-SapStaleRunTemp`).

**Two-bucket temp model — decide by SCOPE, not by "is it transient".** The
mistake is "everything transient → `{RUN_TEMP}`": some scratch is genuinely
cross-session and MUST stay at a shared, stable path or coordination breaks.
Route every temp file to the bucket that matches *who needs to find it*:

- **Bucket A — cross-session / cross-connection coordination → stable shared
  path** (`{work_dir}\runtime\`): anything a *different* session must locate by
  a *predictable* path — the broker registry (`session_registry.json`),
  `connections.json`, the AI-session pins, the session-path anchor. These are
  the **allowlisted** shared artifacts. `{WORK_TEMP}` (`{work_dir}\temp` root)
  is itself only an *anchor* passed to `Get-SapCurrentSessionPath -WorkTemp` /
  the broker (which derive `{work_dir}\runtime` from its parent) — it is **not**
  a write target for generated scripts.
- **Bucket B — per-run private scratch → `{RUN_TEMP}`** (`{work_dir}\temp\run_<id>`,
  minted by `Get-SapRunTemp`): a skill's generated `*_run.vbs`/`.ps1`, the asXML
  payload it pastes, `_run.json` state, the clipboard/title temp files, an input
  file, AND any ad-hoc orchestrator/agent probe or verify script. Run-isolated so
  concurrent runs — parallel sub-agents, multi-connection deploys, or **two
  sessions of the same build** — never collide on a fixed name.

**Decision rule:** *Will another session/connection ever read this exact file by
a predictable path? Yes → Bucket A (shared coordination state in
`{work_dir}\runtime\`, on the allowlist). No → Bucket B (`{RUN_TEMP}`).* Shipped
helper scripts (`sap_session_broker*.{ps1,vbs}`, `sap_attach_lib.vbs`, …) live in
`shared/scripts/`, never regenerated into temp. A cross-session helper can still
*run* from `{RUN_TEMP}` and just point at the shared **state** by absolute path +
the named mutex (`SapDevSessionBroker_v2`) + the global SAP GUI COM ROT — so even
coordination work does not need its *script* in `{WORK_TEMP}`.

**This applies to agents and ad-hoc orchestration scratch too, not just skills.**
Writing a fixed-named file straight into `{WORK_TEMP}` root (or worse, the repo
root) is the smell that caused the 2026-06-20 cross-session
`sap_se38_update_run.vbs` collision (two concurrent v74 builds clobbered each
other's generated VBS). Enforced two ways: `scripts/check-consistency.mjs` (static,
catches the repo SKILL.md — note it does NOT see the running *cache* copy or
ad-hoc scratch) + the `run-temp` PreToolUse hook in `.claude/settings.local.json`
(runtime, catches the live tool call — cache-lagged skills and agent/orchestrator
scratch included). The shared/allowlisted Bucket-A basenames are codified in both
(`RUN_TEMP_SHARED_ALLOWLIST` in the checker; `SHARED_ALLOWLIST` in the hook).

Every skill includes a **Step 0 — Resolve Work Directory**. It MUST resolve
`work_dir` via `Get-SapWorkDir` (which applies the env-var → settings.local →
settings → default precedence) — **NOT** by reading `settings.json` directly,
which silently ignores `SAPDEV_AI_WORK_DIR` and `userconfig.json`. Canonical
one-liner (parse the `WORK_DIR=` line from stdout):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Then create `{WORK_TEMP}` = `{work_dir}\temp` if needed, and set `{RUN_TEMP}` =
the `RUN_TEMP=` value (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`).
Use `{RUN_TEMP}` for the skill's OWN scratch (generated `*_run.vbs/.ps1`, the
`_run.json` state file, scratch `.txt`); keep `{WORK_TEMP}` (base) only for
`Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'`.

**Custom naming rules override:** Skills that use `abap_naming_rules.tsv` check `{custom_url}\abap_naming_rules.tsv` first. If found, the custom file is used instead of the default in `sap-dev-core/shared/tables/`.

### Transport Request Settings

| Setting | Allowed values | Default | Purpose |
|---|---|---|---|
| `sap_dev_transport_request` | TR number or blank | blank | The default modifiable TR. Read by `/sap-transport-request` under `DEFAULT` mode. |
| `way_to_get_transport_request` | `DEFAULT`, `ASK`, `CREATE_NEW` | `DEFAULT` | TR sourcing policy applied by `/sap-transport-request`. Asked during `/sap-dev-init`. |
| `rule_of_tr_description` | `ASK`, `PATTERN`, `FIXED`, `RANDOM` | `ASK` | How `/sap-se01` builds the description for new TRs. |
| `tr_description_template` | string | blank | Template for `PATTERN` (placeholders) or literal for `FIXED`. Final result truncated to 60 chars. |

**Two-layer dev defaults (per-connection + per-session).** The per-connection dev
keys (`sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group`,
`sap_dev_mode`, `way_to_get_transport_request`, `rule_of_tr_description`,
`tr_description_template`) resolve through **two** layers, highest first:
1. **Session** — `{work_dir}\runtime\session_dev_defaults.json`, keyed per
   `(AI-session × connection)`. A TASK's TR/package lives here, so concurrent
   conversations on the **same** SAP connection never clobber each other (the
   2026-06-20 `069→074→075` thrash). Keyed on the connection too, so a
   `/sap-login --switch` can't carry an `S4DK…` TR onto S4H.
2. **Connection** — `connections.json[<id>].dev_defaults`, the developer's
   **standing** default for that system (the existing Phase 4.4 layer).
Then the global settings file. **Writers:** a task TR/package → **Session** scope
(`Set-SapUserSetting … -Scope Session`, or the CLI `shared/scripts/sap_dev_default.ps1`
whose default is Session) — never a hand-edit of `connections.json`. A deliberate
STANDING default (onboarding: `/sap-dev-init`, `/sap-login`) must pass
**`-Scope Connection`** explicitly — **Session is now the writers' default**, so a
task TR/package is isolated without opting in. Reads go through `Get-SapCurrentDevDefault`
(centralized), so all callers get the layered resolution for free. Session entries
are age-pruned (7 days) — task defaults are ephemeral.

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

### frequently_errors Loop Settings

Read by `sap_error_hints.ps1` + the skills wired into the loop. All optional.

| Setting | Allowed values | Default | Purpose |
|---|---|---|---|
| `frequently_errors_enabled` | `true` / `false` | `true` | Master switch. When `false`, sap-gen-abap skips Step 1.5f and deploy/ATC skills skip auto-record. |
| `frequently_errors_autorecord` | `true` / `false` | `true` | Whether sap-se38/se37/se24 + sap-atc auto-record FM/METHOD errors to `{custom_url}\frequently_errors\<OBJECT>.tsv` as CANDIDATE rows. Best-effort; never changes a deploy/ATC verdict. |
| `frequently_errors_inject_status` | `CONFIRMED` / `ALL` | `CONFIRMED` | Which statuses sap-gen-abap injects into generation. `ALL` also injects un-curated CANDIDATE rows (faster feedback, higher noise). |

Store location: `{custom_url}\frequently_errors\` (per-object files) + `{custom_url}\frequently_errors.tsv` (hand-authored override). System-agnostic and team-shareable — point `custom_url` at a shared drive / git repo. Tier-3 seed ships at `shared/tables/frequently_errors.tsv`. Curate via `/sap-error-kb`; full contract in `shared/rules/frequently_errors.md`.

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
| `log_file_pattern` | template | `sap-dev-{YYYYMMDD}.log` | Filename. Placeholders: `{YYYYMMDD}`, `{YYYYMM}`, `{HHMMSS}`, `{HHMM}`, `{RUN_ID}`, `{SKILL}`, `{USER}`, `{SYSTEM}`, `{AI_SESSION}`, `{SID}`, `{CLIENT}`. Default groups all runs of a day into one file (cheap log analysis); use `sap-dev-{YYYYMMDD}-{HHMMSS}-{SKILL}.log` for one-file-per-invocation (forensic mode — each run gets its own file, easy to diff), or `sap-dev-{YYYYMMDD}-{RUN_ID}.log` for guaranteed uniqueness even when two skills fire in the same second. **For parallel multi-session builds, use `sap-dev-{YYYYMMDD}-{SID}-{CLIENT}-{AI_SESSION}.log`** — one coherent file per *(AI session × SAP connection)* so concurrent builds never interleave, while each JSONL record still carries `run_id`/`skill` for per-skill drill-down within the file. **Placeholder gotchas:** `{SYSTEM}` = the Windows `%COMPUTERNAME%` (workstation), **NOT** the SAP SID — it does not separate parallel builds on one machine; use `{SID}`/`{CLIENT}` (pinned SAP connection) + `{AI_SESSION}` for that. `{AI_SESSION}` = first 8 chars of the conversation id, resolved from `CLAUDE_CODE_SESSION_ID` (stable across a Claude host restart) → `SAPDEV_AI_SESSION_ID` (override) → `Get-SapAiSessionId` (parent-PID fallback, **drifts** on host restart). `{SID}`/`{CLIENT}` come from the pinned connection profile (best-effort: fall back to empty / the default connection if the AI-session pin is orphaned — e.g. after a host-restart id drift); `{AI_SESSION}` alone already guarantees one-file-per-build uniqueness. PowerShell logger resolves all three directly; the (currently unused) VBS logger reads `{AI_SESSION}` from `CLAUDE_CODE_SESSION_ID`/`SAPDEV_AI_SESSION_ID` and `{SID}`/`{CLIENT}` from `SAPDEV_SID`/`SAPDEV_CLIENT` env vars. |
| `log_retention_days` | integer | `30` | Delete `*.log` older than N days (PS1 only, sweep runs ~1-in-50 invocations). `0` = keep forever. |
| `log_format` | `JSONL`, `TSV`, `TEXT` | `JSONL` | On-disk record format. `JSONL` is required for `/sap-log-analyze`. `TSV` writes a header row on first write. `TEXT` is human-readable. |
| `log_console_echo` | `true` / `false` | `false` | Mirror each record to stdout (or stderr for `WARN` / `ERROR`). |
| `log_max_size_mb` | number | `10` | Rotate the active log when it reaches N MB. Rotated files become `{name}.1`, `{name}.2`, ... up to `log_max_backups`. `0` disables size-based rotation. Combines with the daily rotation provided by `{YYYYMMDD}` in `log_file_pattern`. |
| `log_max_backups` | integer | `5` | Number of rotated backups to keep when `log_max_size_mb` triggers. |
| `log_redact_keys` | comma-separated list | `sap_password,password,passwd,pwd,token,secret,api_key` | Param/extra keys whose values are masked as `***` in records (case-insensitive). Recursive into nested hashtables (PS) / param-pair arrays (VBS). |

JSONL records have shape `{ts, run_id, parent_run_id, skill, phase=start|step|end, level, …}`. Errors carry an optional `error_class` enum (e.g. `TR_NOT_MODIFIABLE`, `RFC_LOGON_FAILED`, `GUI_TIMEOUT`) — **the full taxonomy is `shared/rules/error_classes.md`** (single source of truth; pick from it, or add the new class there in the same commit that starts emitting it). End records carry `status` (`SUCCESS` / `FAILED` / `SKIPPED` / `EXISTED` / `ABANDONED`), `exit_code`, and `duration_ms`. Run-id chaining via env vars `SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID` lets analyzers reconstruct parent → child skill call trees (e.g. `/sap-se11` → `/sap-transport-request` → `/sap-se01`).

### Path Placeholders

| Placeholder | Resolves to |
|---|---|
| `<SKILL_DIR>` | Absolute path to the current skill's directory |
| `<SAP_DEV_CORE_SHARED_DIR>` | Absolute path to `sap-dev-core/shared/` — go 3 levels up from `<SKILL_DIR>`, then into `sap-dev-core\shared` |
| `{WORK_TEMP}` | `{work_dir}\temp` (base, shared) — resolved from `work_dir` (default `C:\sap_dev_work\temp`). Use ONLY for the session broker + `Get-SapCurrentSessionPath -WorkTemp` |
| `{RUN_TEMP}` | `{work_dir}\temp\run_<id>` — a fresh per-invocation scratch dir minted + created by `Get-SapRunTemp` (`sap_connection_lib.ps1`). Where each skill writes its OWN generated wrappers / `_run.json` state / scratch, isolating concurrent runs. Swept by `Remove-SapStaleRunTemp` |
| `{custom_url}` | Custom overrides directory — resolved from sap-dev-core `settings.json` |
| `<SAP_LOGIN_SKILL_DIR>` | **Deprecated** — use `<SAP_DEV_CORE_SHARED_DIR>` instead |

### Reference Convention in SKILL.md

Skills using shared resources MUST declare them in a `## Shared Resources` section placed immediately after the YAML frontmatter. The section lists each file, its token name (if injected into VBScript), and its purpose.

Token convention: `%%NAMING_RULES%%` for abap_naming_rules.tsv; `%%TEMP_DIR%%` for work temp directory in VBS; `%%RFC_LIB_PS1%%` for the absolute path of `sap_rfc_lib.ps1` (dot-sourced by every RFC-using PowerShell script); `%%LOG_LIB_PS1%%` and `%%LOG_LIB_VBS%%` for the absolute paths of the JSONL logging libraries; `%%SETTINGS_LIB_PS1%%` for the absolute path of the settings.json + settings.local.json merge helper (mandatory per Rule 7 — every skill that reads or writes a userConfig value must go through it); `%%SESSION_LOCK_VBS%%` for the absolute path of `sap_session_lock.vbs` (dot-included by every GUI-scripting VBS that performs multi-step writes); `%%ACTIVATION_LOG_VBS%%` for the absolute path of `sap_activation_log.vbs` (dot-included by GUI-scripting VBS that calls Activate / Ctrl+F3 and needs to surface SAP-side activation errors); `%%OBJECT_RESOLVER_PS1%%` for the absolute path of `sap_object_resolver.ps1` (dot-sourced for the `Resolve-SapObject` canonical object-identity function, or run as a CLI by the delivery-assurance skills); `%%ARTIFACT_LIB_PS1%%` for the absolute path of `sap_artifact_lib.ps1` (dot-sourced for the artifact-index functions `Register-SapArtifact` / `Find-SapArtifacts` by the delivery-assurance skills); `%%FINDING_LIB_PS1%%` for the absolute path of `sap_finding_lib.ps1` (the reconciled finding model — `New-SapFinding` / `New-SapCheckResult` / `Get-SapVerdict` / `Export-SapFindings*`); `%%GATE_POLICY_PS1%%` for the absolute path of `sap_gate_policy.ps1` (`Get-SapGatePolicy` / `Set-SapFindingGates`, reads the customer-brief Quality bar); `%%SHARED_<UPPERCASE_STEM>%%` for new tokens. **Do NOT introduce any VBS-side helper for the SAP GUI Security dialog** — the SAP GUI Scripting COM API is fully suspended while that dialog is modal (every `findById` returns nothing, even `wnd[0]`), so no VBS pattern can dismiss it. Skills that trigger file IO must launch `shared/scripts/sap_gui_security_sidecar.ps1` as a parallel PowerShell process; see the sidecar's row above and `/sap-dev-init` Step 1b for the coordination pattern.

## Getting Help

General Plugin Development: → Use plugin-dev skills
Issues: → File GitHub issues

</coding_guidelines>
