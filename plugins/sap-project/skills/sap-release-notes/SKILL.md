---
name: sap-release-notes
description: |
  Generates a business-readable CAB / release pack for a set of ABAP transport
  requests — answers "what does this release change, how risky is it, what test
  evidence exists, and how would we roll back?" for change-approval boards.
  Resolves scope from an explicit TR list or an E070 date range (owner / prefix
  filters), builds the object inventory from E071 (request + child tasks), groups
  changes by business area (package → application component → package text, with a
  customer override map), then folds in EXISTING /sap-transport-readiness GO/NO-GO
  verdicts and /sap-impact-analysis risk bands from the artifact index (running
  them read-only only where missing). Claude then writes cab_pack.md against a
  fixed section template with a hard grounding rule and a mandatory Missing-evidence
  section. Read-only against SAP (no confirm gates); registers its outputs for
  /sap-evidence-pack. Prerequisites: SAP profile via /sap-login (RFC); SAP NCo 3.1
  (32-bit) in GAC. No GUI session, no Z-object dependency.
argument-hint: "<TR1[,TR2,...]> | --from YYYY-MM-DD [--to YYYY-MM-DD] [--user U] [--prefix ZPRJ] [--ticket ID] [--max-impact N] [--refresh] [--docx]"
---

# SAP Release Notes / CAB Pack Skill

You assemble a **change-advisory-board pack** for one or more transport requests:
an inventory of what changes, grouped by business area, folded together with the
risk and test-evidence verdicts the delivery-assurance skills already produced,
and written up in business language. You are **read-only** against SAP.

Task: $ARGUMENTS

This skill is pure composition of proven read-only reads plus AI writing. The
deterministic inventory is built by `references/sap_release_notes_inventory.ps1`;
the verdicts come from the artifact index; **you** write the prose pack from that
data under a strict grounding rule (no claim without a data row or a verdict).

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here, no writes to SAP |
| `<SKILL_DIR>/references/sap_release_notes_inventory.ps1` | `-Trs \| -FromDate/-ToDate [-User -Prefix] -SharedDir -SkillDir [-CustomUrl -Ticket -MaxTrs -OutputDir]` | The RFC change-inventory engine |
| `<SKILL_DIR>/references/sap_release_object_types.tsv` | read by the engine | E071 object-type → human label map (customer-overridable) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced by the engine | `Read-SapTableRows` (E070/E07T/E071/TADIR/TDEVC/TDEVCT/DF14T) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced by the engine + Step 9 | Scope key, artifact dir, `Register-SapArtifact` |
| `/sap-transport-readiness` | sub-skill | Read-only GO/NO-GO verdict per TR (folded in / run when missing) |
| `/sap-impact-analysis` | sub-skill | Read-only risk bands per changed object (folded in / run when missing) |
| `docx` | sub-skill | Optional `.docx` rendering of the finished pack (best-effort) |

---

## Step 0 — Resolve Work Directory and Settings

Resolve `work_dir` via the env-aware helper (never read `settings.json` directly):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Also resolve `{custom_url}` (customer override root) if configured — pass it to the
engine as `-CustomUrl` so `sap_release_object_types.tsv` / `release_area_map.tsv`
overrides are honored.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_release_notes_run.json" -Skill sap-release-notes -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Parse `$ARGUMENTS`:

- **Scope (exactly one):**
  - **Explicit TR list** — one or more TRs, comma/space separated (e.g.
    `S4DK900123,S4DK900456`).
  - **`--from YYYY-MM-DD [--to YYYY-MM-DD]`** — E070 `AS4DATE` range (default `--to`
    = today). Narrow with `--user <owner>` (E070 `AS4USER`) and/or `--prefix <ZPRJ>`
    (E070 `TRKORR LIKE 'ZPRJ%'`).
- **Flags:** `--ticket <id>` (tag the pack + registrations), `--max-impact <n>`
  (cap on impact-analysis fan-out, default 25), `--refresh` (re-run
  readiness/impact even when a verdict already exists), `--output <dir>`,
  `--docx` (render `.docx`).
- **Phase-2 flags** (`--customizing`, `--deep --against <profile>`): parse but tell
  the user they are **not yet implemented** in v1 and continue without them.

Validate: a TR list XOR a `--from` range must be present. If neither, ask the user
for a TR or a date range and STOP.

Convert `--from/--to` from `YYYY-MM-DD` to the `YYYYMMDD` the engine expects.

---

## Step 2 — Ensure the RFC Profile

This skill needs an **RFC connection only — no active GUI session**. A SAP profile
must be pinned (`/sap-login`). The engine self-connects via the pinned profile
(no creds on the command line). If no profile is pinned, run `/sap-login` first.

---

## Step 3 — Build the Change Inventory

Run via **32-bit PowerShell** (NCo 3.1 is in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_release_notes_inventory.ps1" -Trs "S4DK900123,S4DK900456" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -SkillDir "<SKILL_DIR>"
```

For a date range, replace `-Trs ...` with `-FromDate 20260101 -ToDate 20260131`
plus optional `-User <owner> -Prefix <ZPRJ>`. Append `-CustomUrl "{custom_url}"`,
`-Ticket "<id>"`, `-MaxTrs 50`, `-OutputDir "<dir>"` as applicable.

The engine prints a parseable summary and writes the inventory files:

```
INVENTORY: trs=<n> objects=<n> areas=<n> unresolved=<n> scope=<key>
CHANGES_TSV: <path>   INVENTORY_JSON: <path>   ARTIFACT_DIR: <path>   SCOPE_KEY: <key>
STATUS: OK | EMPTY_SCOPE | TOO_MANY_TRS | RFC_ERROR
```

Exit / STATUS handling — **abort loud, never write a pack from a failed inventory**:

| STATUS | Exit | Action |
|---|---|---|
| `OK` | 0 | Continue. Note `unresolved` (entries with no resolvable package — deleted objects, customizing `TABU`, exotic sub-objects). |
| `EMPTY_SCOPE` | 3 | No content objects in scope (unknown TR / empty request). Tell the user, log end with `RELNOTES_EMPTY_SCOPE`, STOP. |
| `TOO_MANY_TRS` | 4 | Range matched > 50 TRs. Tell the user to narrow `--from/--to/--user/--prefix`, log end with `RELNOTES_SCOPE_TOO_LARGE`, STOP. |
| `RFC_ERROR` | 2 | Connection / read failed. Suggest `/sap-doctor rfc`, log end with `RFC_LOGON_FAILED`, STOP. |

Read `CHANGES_TSV` (one row per changed object: trkorr, task, owner, date, pgmid,
object, obj_name, package, area, type_label, tr_text) and `INVENTORY_JSON`
(per-TR headers + distinct areas). Keep `ARTIFACT_DIR` and `SCOPE_KEY` for Steps 7 & 9.

> Large multi-TR scopes walk each TR's objects with per-object package lookups
> (cached) — a 50-TR range can take a minute or two. This is expected; it runs
> read-only in the background of the pack build.

---

## Step 4 — Fold In Risk & Test Verdicts (read-only)

For each TR (and its principal changed objects), look for verdicts already in the
artifact index before running anything new. Query the index by scope key:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Find-SapArtifacts -ScopeKey 'TR_S4DK900123' | ConvertTo-Json -Depth 5"
```

- **Readiness** — for each TR with no `readiness_report` artifact (or with `--refresh`),
  run `/sap-transport-readiness <TR>` (its default **read-only** form — do NOT pass
  `--run-atc` / `--include-unit-tests`; this skill only *reuses* heavy verdicts, it
  never triggers them). Record the GO / GO_WITH_WARNINGS / NO_GO verdict.
- **Impact** — for up to `--max-impact` distinct changed objects lacking an impact
  artifact (largest blast-radius first: programs / classes / FMs before texts and
  customizing), run `/sap-impact-analysis <object>` and record the risk band.
- **Anything still uncovered** → list it under **Missing evidence** in the pack.
  A COULD_NOT_CHECK or absent verdict is never rendered as a pass (honesty contract).

Roll the per-TR verdicts up to one pack verdict: **NO_GO** if any TR is NO_GO,
else **GO_WITH_WARNINGS** if any warning / COULD_NOT_CHECK / Missing-evidence row,
else **GO**. Use **NONE** only when no verdict source was available at all.

---

## Step 5 — Customizing decode *(phase 2 — not in v1)*

`--customizing` (E071K TABKEY decode + IMG grouping) is planned for v1.5. If the
user asked for it, state it is not yet implemented and proceed with the v1 pack.

## Step 6 — Deep source diffs *(phase 2 — not in v1)*

`--deep --against <profile>` (per-object unified diffs via `/sap-compare`) is
planned for v2. If asked, state it is not yet implemented and proceed.

---

## Step 7 — Compose the CAB Pack (you write this)

Write `cab_pack.md` into `ARTIFACT_DIR` using this fixed section order. **Grounding
rule: every factual claim must trace to a `changes.tsv` row, an `inventory.json`
field, or a recorded verdict. Never invent object purposes, risk, or history.**

1. **Executive summary** — 2–4 sentences: how many TRs / objects, the pack verdict,
   the headline business areas touched. Plain language, no raw codes.
2. **Changes by business area** — group `changes.tsv` rows by the `area` column.
   Under each area, list the R3TR master objects with their `type_label` and name;
   summarize sub-objects rather than listing every `LIMU` part. Put `(unresolved)`
   entries in a clearly-labeled "Unresolved / customizing" bucket — do not guess
   their area.
3. **Risk** — the folded-in `/sap-impact-analysis` bands and `/sap-transport-readiness`
   verdicts per TR. State the roll-up verdict and why.
4. **Test evidence** — ATC / ABAP-Unit / readiness artifacts found in the index
   (cite their ids). If none, say so plainly.
5. **Rollback approach** — **ADVISORY** template text only: CTS has no true
   rollback; the remediation is a corrective transport / reimport of the prior
   version, coordinated with Basis. Never claim a one-click rollback.
6. **Open items / Missing evidence** — mandatory. Every TR/object with no verdict,
   every `(unresolved)` package, every COULD_NOT_CHECK. This section must never be
   empty when something was not checked.
7. **Technical appendix** — the `changes.tsv` rendered as a table, plus scope
   metadata (system, client, date range / TR list, run id).

Respect `userConfig.template_language` for section headings if set (EN default).

---

## Step 8 — Optional docx render

If `--docx`, delegate the finished `cab_pack.md` to the `docx` skill → `cab_pack.docx`
in `ARTIFACT_DIR`. Best-effort: a docx failure never changes the verdict or blocks
the pack.

---

## Step 9 — Register the Pack

Register `cab_pack.md` (and the docx, if produced) in the artifact index so
`/sap-evidence-pack <scope>` collects it. `change_inventory` was already registered
by the engine; register the pack itself here:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-release-notes' -ScopeKey '<SCOPE_KEY>' -ScopeKind '<TR|TRSET>' -Kind 'release_notes' -Format 'md' -Path '<ARTIFACT_DIR>\cab_pack.md' -Verdict '<GO|GO_WITH_WARNINGS|NO_GO>' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS|COULD_NOT_CHECK>' -Ticket '<id>'"
```

Use `-Coverage COULD_NOT_CHECK` whenever the Missing-evidence section is non-empty.

Echo the final line for the user:

```
PACK: <ARTIFACT_DIR>\cab_pack.md  trs=<n>  objects=<n>  verdict=<GO|GO_WITH_WARNINGS|NO_GO|NONE>
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_release_notes_run.json" -Status SUCCESS -ExitCode 0
```

A pack that builds — even NO_GO — is `SUCCESS -ExitCode 0` (the pack ran fine; NO_GO
is a valid verdict). For the fail-loud STOPs in Step 3 use `-Status FAILED` with the
mapped `-ErrorClass` (`RELNOTES_EMPTY_SCOPE` / `RELNOTES_SCOPE_TOO_LARGE` /
`RFC_LOGON_FAILED`).

---

## Scope & Limitations (v1)

- **v1 implemented:** explicit TR list + `--from/--to` date range (with `--user` /
  `--prefix`), business-area grouping (package → application component → package
  text → customer override map), object-type labels, verdict fold-in from the
  artifact index (readiness + impact, read-only), the AI CAB pack, `--docx`.
- **Phase 2 (not yet):** `--customizing` (E071K TABKEY decode + IMG grouping, v1.5),
  `--deep --against` (per-object source diffs via `/sap-compare`, v2).
- **Grouping is best-effort and honest.** `TABU`/`VDAT` customizing entries and
  deleted objects have no TADIR package and land in `(unresolved)`; `LIMU`
  sub-objects are attributed to their R3TR master where derivable (REPS/REPT/CUAD→PROG,
  FUNC→function group, METH/class-parts→CLAS). Package text may appear in the
  logon language when no English text exists.
- **Read-only.** Never releases, imports, or modifies anything in SAP. It does not
  trigger ATC / ABAP-Unit — it only reuses verdicts other skills already recorded.
- **Scope caps:** ≥1 TR required; a date range matching > 50 TRs is refused
  (`TOO_MANY_TRS`) — narrow it. A scope with no content objects is `EMPTY_SCOPE`.
