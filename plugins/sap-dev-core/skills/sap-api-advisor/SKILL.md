---
name: sap-api-advisor
description: |
  Natural-language SAP API discovery over RFC (no GUI): turn a goal like "create
  a sales order" or "post a goods movement" into a ranked, trap-annotated,
  paste-ready shortlist of BAPIs / function modules / classes — with released
  state (S/4), interface + documentation for the top candidates, the team's known
  traps inlined, and a ready-to-paste CALL FUNCTION snippet. Reads the BAPI
  catalog (BAPI_MONITOR_GETLIST), TFDIR/TFTIT name+text, SEOCLASS, ARS_W_API_STATE
  (S/4 released state), FUPARAREF/FUNCT + DOCU_GET. HARD rule: it never test-calls
  a candidate — snippets are text only. Read-only; deploys nothing.
  Use for: "which BAPI/FM for X", find an API, is this BAPI released, API to
  create/read/post <object>, discover function module, released API S/4.
  `successor` (released→sanctioned replacement) is phase 2; `scan` is phase 3.
  Prerequisites: an RFC-capable connection profile (/sap-login). No dev-init, no GUI.
argument-hint: "discover \"<natural-language goal>\" [--top=N] [--details=N] [--type=fm|bapi|class|any] [--package=<pat>]"
---

# SAP API Advisor — natural-language API discovery (RFC)

You turn a natural-language goal into a ranked, trap-annotated API shortlist,
entirely over RFC (SAP NCo 3.1, 32-bit PowerShell). **No GUI.** **Read-only
(Rule 1).** **You never smoke-call a candidate** — not even a "read-only" one;
the deliverable is metadata + docs + a text snippet, never an executed FM (Rule 5).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules (esp. Rule 1 read-only, Rule 5 no unsolicited execution) |
| `<SKILL_DIR>/references/sap_api_discover.ps1` | `%%RFC_LIB_PS1%%` (only) | RFC backend: `-Action harvest\|released\|detail`. `%%SAP_*%%` stay literal → `Connect-SapRfc` fills them from the pinned profile |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect/disconnect; fills `%%SAP_*%%` from the pinned profile |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lookup_fm.ps1` | *(CLI)* | Cached FM signature (RPY_FUNCTIONMODULE_READ_NEW) for the top candidates — reuse, don't re-implement |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_error_hints.ps1` | *(CLI)* | `-Action resolve` — team `frequently_errors` traps for the top FMs (READ only; curation stays in /sap-error-kb) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `%%ARTIFACT_LIB_PS1%%` | Register the advisory + candidate TSV for /sap-evidence-pack |

No VBS, no golden-screen baseline, no session lock — this skill never drives the GUI.

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('ARTIFACT_DIR=' + (Get-SapSettingValue 'artifact_dir' ((Get-SapWorkDir) + '\artifacts'))); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Set `{RUN_TEMP}` (all generated scratch), `{ARTIFACT}` = the artifact dir.

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_api_advisor_run.json" -Skill sap-api-advisor -ParamsJson "{\"mode\":\"<MODE>\"}"
```

## Step 1 — Parse & dispatch

| Mode | Meaning |
|---|---|
| `discover "<goal>"` (default for a bare quoted string) | ranked API shortlist — **v1**, Steps 2–8 below |
| `successor <NAME>` | **phase 2** — print "successor mode is planned for phase 2 (released-state + sanctioned successor from the knowledge pack); not in v1" and stop |
| `scan <OBJECT>` | **phase 3** — print the same "not in v1" note and stop |

Flags: `--top=N` (ranked rows shown, default 10), `--details=N` (deep-detailed top N, default 3), `--type=fm|bapi|class|any` (default any), `--package=<pat>` (optional grouping hint). Materialize the backend once (substitute only `%%RFC_LIB_PS1%%`, leave `%%SAP_*%%` literal → `Connect-SapRfc` uses the pinned profile):

```powershell
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_api_discover.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
[IO.File]::WriteAllText('{RUN_TEMP}\api_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
Write-Host 'Done'
```

## Step 2 (discover) — Derive the search plan (Claude, local) — and echo it

From the goal derive THREE things and **echo them in one line so the user can
correct course before the harvest**:

1. **Keywords** — EN nouns/verbs from the goal **PLUS the SAP abbreviation forms**,
   because SAP API names concatenate/abbreviate and (critically) on a non-EN logon
   the catalog/TFTIT *texts* are localized so **name matching carries the search**.
   Always add the compressed form: `goods movement` → also `goodsmvt`; `sales order`
   → also `salesorder`, `vbak`; `purchase order` → `po`, `ekko`, `bapi_po`;
   `material` → `matnr`, `mara`. (Live-verified: on a JA system "post goods movement"
   only found `BAPI_GOODSMVT_CREATE` once `goodsmvt` was a keyword.)
2. **FM name patterns** — `BAPI_<NOUN>%` and module-prefix guesses (`BAPI_SALESORDER%`,
   `BAPI_GOODSMVT%`, `MB_%`, `SD_%`). These drive the `TFDIR` name search + the
   name-relevance ranking boost.
3. **Type** — from `--type` (default `any`).

> Searching **create a sales order** → keywords `create, sales, order, salesorder`;
> name patterns `BAPI_SALESORDER%`; type `any`. Harvesting the BAPI catalog + TFDIR
> + TFTIT now…

## Step 3 (discover) — Harvest

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\api_run.ps1" -Action harvest -Keywords "<k1,k2,...>" -NamePatterns "<pat1,pat2>" -Type "<type>" -Max 40 -OutTsv "{RUN_TEMP}\api_candidates.tsv"
```

- `STATUS: NO_MATCH` → tell the user no API matched and suggest reformulating (add
  the object name, or the SAP abbreviation); **never invent a name**; stop (log SUCCESS).
- `STATUS: RFC_LOGON_FAILED` / a `NOTE:`-flagged catalog failure with zero rows →
  `RFC_ERROR`; surface + stop with the /sap-login hint.
- `STATUS: OK n=<k> total=<t> capped=<bool>` → `capped=true` means `total` exceeded
  40; the shortlist is the most-relevant 40 (mention it). Each `CAND:` line has
  `match` (keywords hit), `src` (`catalog`/`name`/`text`), `fmode`, `released`,
  `obsolete`, `comp`, `text`.

## Step 4 (discover) — Released-state enrichment

For the top ~10 candidate FM names, enrich released state (S/4 only):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\api_run.ps1" -Action released -Names "<name1,name2,...>"
```

- `STATUS: NOT_APPLICABLE` → **ECC / any release without the API-release contract**:
  render the released column as `NOT_APPLICABLE (no release contract on this
  release)` for every candidate — never blank, never a false "released".
- `REL: name=… state=… successor=…` → per-candidate release state (`state=NOT_LISTED`
  = the API isn't in `ARS_W_API_STATE`; report as such, not as "not released").

## Step 5 (discover) — Rank (Claude, transparent)

Show a ranked table (top `--top`, default 10) with a **visible score column** and
the rubric, applied by you over the harvest + released data:

**released (S/4) > BAPI-catalog member (non-obsolete) > RFC-enabled (`fmode=R`) >
name-pattern fit (goal words in the API name) > package plausibility > text match.**
Demote `obsolete=X` with the reason printed. Use judgment the raw score can't:
the canonical API for the goal (e.g. `BAPI_SALESORDER_CREATEFROMDAT2`,
`BAPI_GOODSMVT_CREATE`) belongs at/near the top even when a keyword-heavier row
scored higher — say why. **Zero rows survived → `NO_MATCH`; never fabricate.**

## Step 6 (discover) — Detail the top `--details` (default 3)

Signature (cached) + parameter texts + FM docs:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lookup_fm.ps1" -FmName "<FM>" ...   # signature (reuse; do NOT re-implement)
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\api_run.ps1" -Action detail -Names "<FM1,FM2,FM3>" -OutFile "{RUN_TEMP}\api_docs.txt"
```

`DETAIL: fm=… param=… text=…` gives parameter short texts; `doc_lines` + the
`-OutFile` capture the DOCU_GET documentation.

## Step 7 (discover) — Traps

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_error_hints.ps1" -Action resolve -Objects "<FM1,FM2,FM3>" ...
```

Render CONFIRMED rows as a "Known traps" block per detailed candidate (READ only).

## Step 8 (discover) — Render advisory + register

Write `{ARTIFACT}\advisory_<slug>.md`: the system identity (SID / client / release
marker — so the snippet is never mistaken as verified elsewhere), the ranked table
with scores + reasons, and per detailed candidate: interface digest, docs digest,
traps, and a **CALL FUNCTION snippet** with exception handling + a `BAPIRET2` loop
and — for BAPIs — an explicit `BAPI_TRANSACTION_COMMIT` / `ROLLBACK` note. State
plainly in the advisory: **"I did not test-call this; here is the snippet."** Then
register:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1" -Register -Skill sap-api-advisor -Kind api_advisory -Format md -Path "{ARTIFACT}\advisory_<slug>.md" -Coverage <CHECKED|COULD_NOT_CHECK> -Verdict <MATCHED|NO_MATCH>
```

`Coverage=COULD_NOT_CHECK` when released-state was `NOT_APPLICABLE`/unreadable (so a
"use this API" line always carries the caveat). Also register `api_candidates.tsv`
(`-Kind api_candidates`).

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_api_advisor_run.json" -Status <SUCCESS|FAILED> -ExitCode <0|1> [-ErrorClass <CLASS> -ErrorMsg "<short>"]
```

`error_class`: infra `RFC_LOGON_FAILED` / `RFC_ERROR` only (v1 discover adds no new
class; `NO_MATCH` is a normal SUCCESS verdict, not a failure). Phase 2 (successor)
will add `API_KB_MISSING`.

---

## Safety & gates (summary)

- **Read-only (Rule 1)** — only metadata / catalog / doc reads; no writes, no TR.
- **No smoke-call (Rule 5)** — the skill NEVER invokes a candidate FM, not even a
  read one. If asked to "just try it", refuse and hand over the snippet.
- **Fail-loud (Rule 10)** — `NO_MATCH` (never invented names); `RFC_ERROR` on RFC
  failure (never a GUI-fallback claim); released-state unavailable → `NOT_APPLICABLE`
  / `COULD_NOT_CHECK`, which caps any recommendation with an explicit caveat.

## Limitations

- **v1 is `discover` only.** `successor` (released → sanctioned replacement via the
  phase-2 knowledge pack + `ARS_W_API_STATE` `SUCCESSOR_*` columns) and `scan`
  (walk /sap-explain-object edges) are later phases.
- **Ranking is heuristic + Claude judgment**, shown transparently with the score
  column and the inlined traps so a "top" candidate with known landmines is visible.
- **Text search quality** depends on logon language — SAP short texts are often
  localized/terse, so name patterns + the BAPI catalog lead and the SAP-abbreviation
  keywords (Step 2) are load-bearing on non-EN systems.
- **Released state is S/4-only** (`ARS_W_API_STATE` absent on ECC → `NOT_APPLICABLE`).
- Single code path on ECC 6 and S/4HANA (verified S4D 1909 + EC2/ERP ECC 6,
  2026-07-11); the only divergence is the released-state column.
