---
name: sap-cc-cloud-readiness
description: |
  Measures each custom (Z/Y) object's DISTANCE FROM ABAP CLOUD — the question
  S4HANA_READINESS (/sap-cc-analyze) does not answer. `scan` downloads source over
  RFC for a campaign's REMEDIATE scope (or an explicit --objects/--packages set),
  matches a versioned forbidden-statement ruleset + a cloudification-repository
  snapshot offline, and classifies every object TIER_1_READY / TIER_2_WRAPPABLE
  (only blockers are unreleased APIs with a successor) / TIER_3_CLASSIC (a
  forbidden statement or an unreleased API with no successor), with a per-blocker
  blockers.tsv and an AI summary of the cheapest wins. Honest by construction: an
  API absent from the pack is 'unknown' (counted, never a blocker), a source that
  can't be read is COULD_NOT_CHECK (never TIER_1), and any dynamic call sets
  dynamic_blindspot=YES. S/4-ONLY (hard-refuses a non-S/4 pinned profile —
  CC_NOT_S4 — pointing to /sap-cc-analyze). Read-only RFC; no writes, no TR, no
  deploy. Prerequisites: /sap-login pinned to the S/4 system; SAP NCo 3.1 (32-bit).
argument-hint: "scan [--campaign <id>] [--objects <TYPE:NAME,...|file>] [--packages <pat,...>] [--limit <n>] [--refresh-source] [--knowledge <dir>]   |   keyuser (v2)"
---

# SAP Custom-Code Cloud-Readiness — ABAP Cloud Distance Scanner

`/sap-cc-analyze` answers "does this code survive the S/4 conversion". This skill
answers a different question: **how far is each object from ABAP Cloud (clean
core)** — which extensibility tier it lands in, and what concretely blocks tier 1.
It downloads source once over RFC and matches a bundled, versioned knowledge pack
offline, so a whole REMEDIATE scope is classified in minutes with per-blocker
evidence.

Task: $ARGUMENTS

**S/4-only.** Cloud distance is meaningful only on the S/4 system where clean core
applies. Step 1.5 hard-refuses a non-S/4 pinned profile (`CC_NOT_S4`) and points to
`/sap-cc-analyze`. **Read-only** — RFC source reads only; no SQL writes, no TR, no
deployment.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`, `Get-SapCurrentConnectionProfile` (S/4 guard) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | `%%OBJECT_RESOLVER_PS1%%` | Standalone scope: expand `--objects`/`--packages` (`-Expand`) |
| `<SKILL_DIR>/references/sap_cc_cloud_download.ps1` | `-ScopeFile -CacheDir -SharedDir` | RFC source download (read-only) → `<TYPE>__<NAME>.abap` + `coverage.tsv` |
| `<SKILL_DIR>/references/sap_cc_cloud_scan.ps1` | `-SourceDir -OutDir` | Offline scanner → `cloud_tier.tsv` + `blockers.tsv` (pure-local, no SAP) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `%%ARTIFACT_LIB_PS1%%` | Register every TSV/MD written |
| `plugins/sap-migrate/shared/knowledge/cloud/` | *(pack)* | `forbidden_statements.tsv` + `cloudification_repository.json` + `kp_meta.json` (+ `{custom_url}\knowledge\cloud\` override, file-by-file) |
| `/sap-cc-campaign` | *(workspace owner)* | Defines `{CAMPAIGN_DIR}\state.tsv`; this skill reads `decision=REMEDIATE` and NEVER advances state (cloud tier is orthogonal to the R1–R4 tiers) |

> Ships **no GUI VBS** — pure RFC + offline. No session broker / attach lib / golden
> screens. The RFC leg connects to the **pinned** S/4 profile.

## Step 0 — Resolve Work Dir + Custom URL

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

`{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}` when `--campaign` is given;
outputs land in `{CAMPAIGN_DIR}\cloud\`. Standalone (no `--campaign`): use
`Get-SapArtifactDir` for the scope key. Set `{RUN_TEMP}` for logging + the download
cache.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cc_cloudread_run.json" -Skill sap-cc-cloud-readiness -ParamsJson "{}"
```

## Step 1 — Mode Dispatch

`scan` (default) | `keyuser` (**v2, not yet implemented** — see Scope). Parse
`--campaign`, `--objects`, `--packages`, `--limit`, `--refresh-source`,
`--knowledge`. Log the resolved mode/flags.

## Step 1.5 — S/4 Release Guard (fail loud on non-S/4)

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; $p = Get-SapCurrentConnectionProfile -PreferGuiActive; Write-Output ('RELEASE_MARKER=' + $p.server_release_marker + ' SID=' + $p.system_name)"
```

If `server_release_marker` does **not** start with `S4` (e.g. an ECC `ECC_*` marker,
or blank) → **STOP** with `CC_NOT_S4`: cloud distance does not apply to a non-S/4
system; point the user to `/sap-cc-analyze` (conversion readiness). Never probe or
scan. (An ECC/EC2 profile is correctly refused here — no EC2 variant exists.)

## Step 2 — Resolve Scope (scan)

- **Campaign** (`--campaign`): read `{CAMPAIGN_DIR}\state.tsv`, take rows with
  `decision=REMEDIATE`. Write a scope TSV (`object_type<TAB>object_name<TAB>package`)
  to `{RUN_TEMP}\cc_scope.tsv`. Apply `--limit` (a first controlled run).
- **Standalone** (`--objects`/`--packages`): resolve/expand via
  `sap_object_resolver.ps1 -Token "…" -Expand` (PACKAGE/TR tokens expand to member
  objects) → same scope TSV shape.
- **Empty scope → STOP `CC_SCOPE_EMPTY`** (never a "clean" result). Point to
  `/sap-cc-inventory` / `/sap-cc-usage` (campaign) or a non-empty `--objects`.

## Step 3 — Knowledge Pack + Staleness (scan)

The scanner resolves the pack (override → shipped) itself; pass `-CustomUrl
{custom_url}` (and `--knowledge <dir>` → `-KnowledgePack <dir>` if the user
overrode it for one run). Watch the scanner's `KP:` line — a `STALE age_days=<n>`
suffix (snapshot older than `stale_after_days`, default 180) is a WARN to surface in
the summary, not a stop. A missing pack → `CC_KP_MISSING`.

## Step 4 — Source Download (scan, read-only RFC)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_cloud_download.ps1" -ScopeFile "{RUN_TEMP}\cc_scope.tsv" -CacheDir "{CAMPAIGN_DIR}\cloud\source_cache" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>\scripts" -WorkDir "<work_dir>"
```

(Standalone: `-CacheDir {artifact_dir}\<scope>\source_cache`.) Add `-Refresh` for
`--refresh-source`. It reads PROG/REPS/INCLUDE (RPY_PROGRAM_READ) and FUNC (TFDIR +
include) over RFC via the shared sanctioned reader, writes each as
`<TYPE>__<NAME>.abap`, and builds `coverage.tsv`. **CLAS/INTF degrade to
`COULD_NOT_CHECK reason=CLASS_SOURCE_OVER_RFC_UNSUPPORTED`** (class source over RFC
is unsupported in v1 — the wrapper-bridged reader is the v1.5 upgrade, see Scope);
FUGR/DDIC → `TYPE_NOT_SOURCE_SCANNABLE_V1`; a missing object → `NOT_FOUND`. All are
recorded, never silently skipped. `STATUS: ERROR msg=CC_SOURCE_READ_FAILED` means
**every scannable** object was unreadable (infra error) — a partial failure stays
per-object COULD_NOT_CHECK and the run continues.

## Step 5 — Offline Scan (scan)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_cloud_scan.ps1" -SourceDir "{CAMPAIGN_DIR}\cloud\source_cache" -OutDir "{CAMPAIGN_DIR}\cloud" -CustomUrl "{custom_url}"
```

Pure-local (no SAP). Reads the download cache + `coverage.tsv`, tokenises each
source (comment/literal-aware statement split), matches the forbidden ruleset,
extracts + classifies API refs against the cloud repo, sets `dynamic_blindspot`, and
writes `cloud_tier.tsv` + `blockers.tsv`. Read the `TIER:` lines + `STATUS: OK
t1=<n> t2=<n> t3=<n> could_not_check=<n>`.

**Tier truth table** (honest by construction):

| Signal | Tier |
|---|---|
| a forbidden statement, OR an unreleased API with **no** successor | `TIER_3_CLASSIC` |
| no forbidden statement; only blockers are unreleased APIs **with** a successor | `TIER_2_WRAPPABLE` |
| no forbidden statement, no unreleased API (refs released or unknown) | `TIER_1_READY` |
| source could not be read (class / not-found / RFC failure) | `COULD_NOT_CHECK` (never TIER_1) |

An API **absent** from the pack is `unknown`: counted in `api_refs_unknown`, **never
a blocker** (a partial pack can't manufacture a false TIER_3) — but a `TIER_1_READY`
object with unknown refs is reported `coverage=PARTIAL`, never a clean `FULL`. Any
dynamic token (`CALL FUNCTION <var>`, dynamic `CREATE OBJECT`, `SELECT … FROM (var)`)
sets `dynamic_blindspot=YES` — the regex scanner is blind to it, disclosed per row.

## Step 6 — `scan --atc` (v1.5, NOT yet implemented)

Not in v1. When built: probe `SCICHKV_HD` for `CHECKVNAME LIKE '%CLOUD%'`; if a cloud
variant exists → per-object `/sap-atc <TYPE> <NAME> --variant=<found>` (delegation),
folding an `atc_verdict` column; if absent (expected on 1909) → `ATC: SKIPPED
reason=NO_CLOUD_VARIANT`, never silently. Until then `atc_verdict` is `-`.

## Step 7 — AI Summary (scan)

Read `cloud_tier.tsv` + `blockers.tsv` and write `{…}\cloud\summary.md`:
- tier counts + the **dominant blocker patterns** (group `blockers.tsv` by
  `rule_id`/`api`);
- **cheapest wins** — TIER_2 objects with ≤2 wrappable blockers, and TIER_1 objects
  that are clean `FULL` coverage;
- **disclosures (mandatory)** — list objects with `dynamic_blindspot=YES` and every
  `COULD_NOT_CHECK` / `PARTIAL` object; **never** restate a COULD_NOT_CHECK or
  PARTIAL object as a confirmed clean TIER_1. Surface the `KP: STALE` WARN if present.

## Step 8 — Register & Log End

Register `cloud_tier.tsv` (kind `cloud_tier`), `blockers.tsv` (`cloud_blockers`),
`summary.md` (`cloud_summary`) via `Register-SapArtifact` with coverage tri-state, so
`/sap-evidence-pack` collects them. Echo the tier headline. Then:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cc_cloudread_run.json" -Status SUCCESS -ExitCode 0
```

For `CC_NOT_S4` / `CC_SCOPE_EMPTY` use `-Status SKIPPED -ExitCode 1 -ErrorClass <cls>`;
for `CC_KP_MISSING` / `CC_SOURCE_READ_FAILED` / `RFC_LOGON_FAILED` use `-Status FAILED
-ExitCode 2 -ErrorClass <cls>`.

---

## Scope & Limitations

- **v1 implemented:** `scan` — read-only RFC source download for **PROG / REPS /
  INCLUDE / FUNC** + the offline scanner (forbidden ruleset + cloudification repo →
  tiers + blockers + AI summary). Verified live on S/4HANA 1909 (S4D) 2026-07-11:
  a real classic add-on program → `TIER_3_CLASSIC` (28 blockers: 25 WRITE-list, a
  SUBMIT, 3 frontend-file APIs) with zero false positives on 806 lines; the generic
  RFC wrapper FM → `TIER_1_READY` but honestly `blindspot=Y` + `PARTIAL` (it
  dispatches dynamically); a class → `COULD_NOT_CHECK`; a missing object →
  `COULD_NOT_CHECK`. The offline engine is fixture-tested (comment/literal stripping,
  `WRITE … TO` assignment not flagged, tier truth table, dynamic blind-spot).
- **Honest by construction (never a false TIER_1):** unknown APIs are counted, never
  blockers; a partial pack can't manufacture a false TIER_3; a TIER_1 with unknown
  refs is `PARTIAL`, not clean; unreadable source is `COULD_NOT_CHECK`, never TIER_1;
  dynamic calls are disclosed per object. A regex scanner is triage input, **not a
  certification** — the `--atc` path (v1.5) is the upgrade where a cloud variant
  exists.
- **Coverage holes (visible, not hidden):** ABAP **classes/interfaces are
  `COULD_NOT_CHECK` in v1** (class source over RFC is unsupported by the shared
  reader; the wrapper-bridged `SEO_METHOD_GET_SOURCE` reader — same asXML bridge as
  `sap_rfc_syntax_check.ps1`, wrapper probed present on S4D — is the **v1.5**
  upgrade); **FUGR/DDIC** objects are out of the source scan; **string-template
  periods** and **colon-list without a slash** are known tokenizer blind spots.
- **`--atc` (v1.5)** and **`keyuser` (v2)** are not implemented. `keyuser` will
  inventory key-user extensibility (`CFD_L_RT*`/`CFD_W_BUS_CTXT`/`CFD_W_BADI`, all
  probed present on 1909) joined to `YY1_*` artifacts, with per-table probe-gating
  and honest 0-row reporting.
- **Knowledge pack is a curated PARTIAL seed** (`kp_version=2026.07-seed`). Drop a
  full export of SAP's public cloudification repository at
  `{custom_url}\knowledge\cloud\cloudification_repository.json` to raise coverage
  (override wins file-by-file); the skill never fetches from the network. See
  `plugins/sap-migrate/shared/knowledge/cloud/README.md`.
- **S/4-only** — `CC_NOT_S4` on a non-S/4 pinned profile; no ECC/EC2 path exists.
- **Owns only `cloud\*`** — never advances the campaign `state.tsv` (cloud tier is
  orthogonal to the R1–R4 remediation tiers owned by `/sap-cc-triage`).
