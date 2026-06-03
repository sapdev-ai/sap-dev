---
name: sap-review-abap
description: |
  AI semantic + security code review for an EXISTING ABAP object or a local
  .abap file. Reads the active source (RFC RPY for program/include/FM; SE24 GUI
  download for classes), builds a structure + call/data map, then reasons over
  the code across a fixed dimension checklist — security (dynamic-SQL injection,
  missing/incorrect AUTHORITY-CHECK, client handling), correctness (unchecked
  SY-SUBRC, READ TABLE guards, off-by-one), performance (SELECT-in-LOOP, nested
  loops, FOR ALL ENTRIES guard, SELECT *), robustness/LUW (MESSAGE e in method,
  unhandled exceptions, COMMIT in loop), and maintainability. This is the
  SEMANTIC review that complements — does NOT replace — the deterministic
  /sap-check-abap parser and the in-system /sap-atc rule engine.
  Every finding cites a line + code excerpt and is adversarially re-verified
  before it is emitted, so false positives are dropped rather than shipped.
  Findings are written through the shared finding model (severity + gate +
  verdict) to <NAME>.review.tsv / .review.json and registered for
  /sap-evidence-pack. Read-only: never deploys, activates, or edits.
  Prerequisites: pinned connection (/sap-login) for object-name input; class
  source download and --callers additionally need an active SAP GUI session.
  File input (a .abap path) needs no SAP connection.
argument-hint: "<OBJECT_NAME | path-to.abap> [--type program|include|fm|class|auto] [--dimensions all|security,perf,correctness,robustness,maintainability] [--callers] [--gate advisory|block] [--no-gui]"
---

# SAP Review ABAP Skill

You produce a **semantic, security-aware code review** of an existing ABAP
object (or a local `.abap` file). You read the real source, reason about what it
actually does, and emit prioritized, line-cited findings that a rule engine
cannot derive. You are **read-only** — you never deploy, activate, or edit.

This skill observes `shared/rules/skill_operating_rules.md` (reads only — no SQL
writes, no unsolicited deployment) and
`shared/rules/language_independence_rules.md` (the GUI download / where-used VBS
it reuses identify controls by ID, status by `MessageType`).

Task: $ARGUMENTS

> **Positioning (state this to the user when relevant).** `/sap-review-abap` is
> the *judgment* stage of the quality lane, distinct from its neighbours:
> `gen-abap → check-abap → **review-abap** → atc → fix-abap → deploy`.
> - `/sap-check-abap` — deterministic parse: naming, DDIC types, SQL field
>   existence, unused vars. Cheap, exact, no false judgement.
> - `/sap-atc` — SAP's in-system Code Inspector rule set; the hard gate.
> - `/sap-review-abap` (you) — LLM reasoning over logic, security and
>   performance the other two structurally cannot see. Advisory by default.

---

## Shared Resources

| File / token | Path | Purpose |
|---|---|---|
| `sap_settings_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1` | `Get-SapSettingValue`, settings merge |
| `sap_connection_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1` | `Get-SapWorkDir`, `Get-SapCurrentSessionPath` |
| `sap_rfc_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1` | `Connect-SapRfc` |
| `sap_object_resolver.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1` | `Resolve-SapObject` — type + TADIR object code + scope identity |
| `sap_rfc_read_source.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1` | `Read-SapAbapSource` (RPY source + include tree) |
| `sap_explain_parse.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-explain-object\references\sap_explain_parse.ps1` | offline source → `map.json` (units / externals / db reads+writes) |
| `sap_finding_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_finding_lib.ps1` | `New-SapFinding` / `Export-SapFindings*` / `Get-SapVerdict` |
| `sap_gate_policy.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gate_policy.ps1` | `Get-SapGatePolicy` / `Set-SapFindingGates` (reads the brief's Quality bar) |
| `sap_artifact_lib.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1` | `New-SapScopeKey` / `Register-SapArtifact` (best-effort) |
| `sap_attach_lib.vbs` (`%%ATTACH_LIB_VBS%%`) | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs` | `AttachSapSession` (class download / where-used) |
| SE24 download VBS | `<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-se24\references\sap_se24_check_and_download.vbs` | class source (GUI) |
| where-used VBS | `<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-where-used-list\references\sap_where_used_list.vbs` | callers (GUI, `--callers`) |
| `abap_code_quality_rules.md` | `<SAP_DEV_CORE_SHARED_DIR>\rules\abap_code_quality_rules.md` | The §-numbered quality rules the dimension checklist anchors to |
| `customer_brief.md` | `{custom_url}\customer_brief.md` → `<SAP_DEV_CORE_SHARED_DIR>\templates\customer_brief.md` | Release / `MODE_*` / Quality bar — drives gating |
| `sap_log_helper.ps1` | `<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1` | structured logging |

`<SAP_DEV_CORE_SHARED_DIR>` resolves to `plugins/sap-dev-core/shared` — from this
skill, go **3 levels up** from `<SKILL_DIR>` (skill → `skills/` → plugin dir →
`plugins/`), then into `sap-dev-core\shared`.

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` via the env-aware helper — do NOT read `settings.json`
directly (that ignores `SAPDEV_AI_WORK_DIR` / `userconfig.json`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Settings reads/writes follow `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md`.

| Setting | Default if blank |
|---|---|
| `work_dir` | `C:\sap_dev_work` |
| `custom_url` | `{work_dir}\custom` |

Set `{WORK_TEMP}` = `{work_dir}\temp` and `{OUT}` = `{WORK_TEMP}\review\{OBJECT}`
(for file input use the file stem as `{OBJECT}`). Ensure `{OUT}` exists:

```bash
cmd /c if not exist "{OUT}" mkdir "{OUT}"
```

---

## Step 0.5 — Start Logging (best-effort)

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_review_abap_run.json" -Skill sap-review-abap -ParamsJson "{\"target\":\"<OBJECT>\"}"
```

---

## Step 1 — Parse Arguments

| Arg | Default | Notes |
|---|---|---|
| positional | — | **Object name** (uppercase) OR a path to a `.abap` file. If it resolves to an existing file path → **FILE mode**; otherwise → **OBJECT mode**. |
| `--type` | `auto` | `program` / `include` / `fm` / `class` / `auto`. Honoured in OBJECT mode; in FILE mode the type is inferred from the source (`REPORT`/`CLASS … DEFINITION`/`FUNCTION`). |
| `--dimensions` | `all` | Comma list to restrict the review (e.g. `security,perf`). |
| `--callers` | false | Pull where-used to weight blast radius (OBJECT mode, GUI session). |
| `--gate` | `advisory` | `advisory` = report only; `block` = compute a blocking verdict (passes `-Strict` to the gate policy). |
| `--no-gui` | false | RFC-only. Class bodies degrade to signature-only; `--callers` is ignored. |

If the positional is missing, ask for it and stop.

---

## Step 2 — Resolve Type + Acquire Source

### 2a. FILE mode
Read the file directly into `{OUT}\source.txt`. Infer `{TYPE}` and the top-level
name (`{OBJECT}`) from the first `REPORT`/`PROGRAM`/`FUNCTION`/`CLASS … DEFINITION`
line. Set a synthetic object record: `{PGMID}=R3TR`, `{TADIR_OBJ}` = `PROG`
(report/include) / `CLAS` (class) / `FUGR` (FM). No SAP connection needed — skip
to Step 3.

### 2b. OBJECT mode — resolve identity (RFC, 32-bit)
Use the canonical resolver to get the object's TADIR code, package, and
active-state in one call (creds fall back to the pinned profile):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1" -Token "{OBJECT}"
```

Read the `OBJECT:` line (`pgmid` / `object` / `obj_name` / `kind` / `active`) and
the `STATUS:` line. Map `kind` → `{TYPE}` (PROG→program, FUGR/FUNC→fm, CLAS→class,
…). Capture `{PGMID}` and `{TADIR_OBJ}` (the `object` code) for finding
attribution. If `STATUS: NOT_FOUND` → `ERROR: {OBJECT} not found.` and stop;
`AMBIGUOUS` → ask the user to pass `--type`.

> If the resolved object is **inactive**, say so — you are reviewing the *active*
> version; an inactive version may differ. Suggest `/sap-activate-object` or a
> FILE-mode review of the working copy if they want the in-flight code.

### 2c. OBJECT mode — acquire source
**Program / include / FM (RFC, preferred — no GUI):**
```powershell
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_read_source.ps1'
$r = Read-SapAbapSource -Name '{OBJECT}' -Type '{TYPE}' -OutDir '{OUT}' -WithIncludes -Depth 3
# $r.Status in OK | NOT_FOUND | UNSUPPORTED | ERROR ; $r.SourceFile = {OUT}\source.txt
```

**Class / interface (GUI download; skip if `--no-gui`):** reuse the SE24
download VBS exactly as `/sap-explain-object` does — substitute
`%%CLASS_NAME%% %%OUTPUT_FILE%% %%SESSION_PATH%% %%ATTACH_LIB_VBS%%`, set
`$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'`,
write UTF-16, and run via 32-bit cscript:
```bash
"C:/Windows/SysWOW64/cscript.exe" //NoLogo "{WORK_TEMP}\review_dl.vbs"
```
If `--no-gui` and `{TYPE}=class`: skip the body, note "class body not acquired
(--no-gui) — reviewed signature only", and run only the dimensions that work on
the signature.

> **Caveat to carry into the report:** the GUI class download is the
> pretty-printed *display* view (local `TYPES` may surface at outer scope).
> Adequate for review; flag it in `review.md` (same caveat `/sap-explain-object`
> documents).

---

## Step 3 — Build the Call/Data Map + Load Context

**Map** (offline, any PowerShell) — gives you units, external calls, and the
read/write table sets that sharpen the security + performance dimensions:
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\..\skills\sap-explain-object\references\sap_explain_parse.ps1" -SourceDir "{OUT}" -OutFile "{OUT}\map.json"
```

**Customer brief** — resolve per the Template Language chain
(`{custom_url}\customer_brief.md` → built-in template). Record the ABAP
**release**, `MODE_*` flags (esp. `MODE_MAX_METHOD_LINES`), and the **Quality
bar** (drives gating in Step 6). Detect the empty-template case and treat the bar
as "defaults".

**Quality rules** — read `abap_code_quality_rules.md`; the dimension categories
in Step 4 anchor to its §-numbers so a review finding and the matching
`check-abap` / `gen-abap` rule speak the same language.

**Live signature caches (optional honesty input)** — if
`{dir-of-source}\_struct_signatures.txt` or `_authz_signatures.txt` exist (left
by `/sap-gen-abap` when RFC was available), load them. They let the security
dimension confirm `AUTHORITY-CHECK` object/field shapes against SU21 instead of
guessing. **If absent, security findings about auth objects must carry
`coverage=COULD_NOT_CHECK`** (see Step 5) — never assert what you could not verify.

---

## Step 4 — Semantic Review Across Dimensions (the core)

Review `{OUT}\source.txt` against the **fixed checklist below**, restricted to
`--dimensions`. The checklist makes the review reproducible — it is the agenda,
not a limit; genuine issues outside it still count (use category `OTHER`).

For **every** candidate issue you must be able to point at a **specific line and
quote the offending code**. No excerpt ⇒ not a finding.

| Dimension | Category (→ §rule) | What to look for |
|---|---|---|
| **security** | `SQL_INJECTION_DYNAMIC` (§13) | dynamic `WHERE`/`FROM`/`SET` built from input without a whitelist / `CL_ABAP_DYN_PRG` |
| | `MISSING_AUTHZ_CHECK` (§14) | persistence or sensitive read with no preceding `AUTHORITY-CHECK` |
| | `WRONG_AUTHZ_OBJECT` (§14) | object/field/activity mismatch vs the SU21 cache (only if cache loaded) |
| | `MISSING_CLIENT_HANDLING` | `CLIENT SPECIFIED` / cross-client read without justification |
| | `HARDCODED_SECRET` | literal user/password/RFC dest/credential |
| **correctness** | `UNCHECKED_SY_SUBRC` | `SELECT`/`READ TABLE`/`CALL FUNCTION` whose `SY-SUBRC` is never tested before using the result |
| | `READ_TABLE_NO_GUARD` | `READ TABLE … INTO wa` then `wa-…` used on the `SY-SUBRC<>0` path |
| | `OFF_BY_ONE` / `LOGIC_ERROR` | boundary / inverted-condition / wrong-operator reasoning |
| | `UNINITIALIZED_USE` | variable read before it is set on some path |
| **perf** | `SELECT_IN_LOOP` (§12) | `SELECT` inside `LOOP` — pre-select / `FOR ALL ENTRIES` instead |
| | `NESTED_LOOP` (§12) | `LOOP` within `LOOP` over internal tables without a sorted/hashed key |
| | `FOR_ALL_ENTRIES_NO_GUARD` (§12) | `FOR ALL ENTRIES` without `IF lt IS NOT INITIAL` (empty driver reads all) |
| | `SELECT_STAR` (§13) | `SELECT *` where only a few fields are used |
| | `MISSING_INDEX_FIELDS` | WHERE that can't use an index (leading fields absent) |
| **robustness** | `MESSAGE_E_IN_METHOD` (§11) | `MESSAGE e/a/x` inside a method → `UNCAUGHT_EXCEPTION` dump |
| | `UNHANDLED_EXCEPTION` | `CATCH`-less call that can `RAISE`; swallowed `CX_ROOT` |
| | `COMMIT_IN_LOOP` / `NO_ROLLBACK` | LUW hygiene — commit per row, no rollback on error |
| | `MISSING_LOCK` | update without `ENQUEUE` where concurrency matters |
| **maintainability** | `METHOD_TOO_LONG` (§18) | unit longer than `MODE_MAX_METHOD_LINES` (default 50) |
| | `DEAD_CODE` / `MAGIC_NUMBER` / `DEEP_NESTING` | unreachable code, unnamed constants, >4 nesting levels |

**Use `map.json`** to ground the perf/security dimensions: its `db_reads` /
`db_writes` / `externals` tell you which loops touch the DB and which writes lack
a preceding auth check; its `units` give the method-length signal.

Assign each candidate an intrinsic **severity** (`BLOCKER`/`HIGH`/`MEDIUM`/`LOW`/
`INFO`) and a **confidence** (`HIGH`/`MEDIUM`/`LOW`). Suggested floors: SQLi /
unguarded auth on a write path → `HIGH`+; `MESSAGE_E_IN_METHOD`, `SELECT_IN_LOOP`
→ `HIGH`/`MEDIUM`; style → `LOW`/`INFO`. The brief's Quality bar — not these
floors — decides what actually blocks (Step 6).

---

## Step 4b — Adversarial Self-Verification (precision guard)

Before emitting, make a **second pass that tries to refute each candidate.** This
is mandatory — it is what keeps the review trustworthy and answers the known
`check-abap` false-positive pain. For each candidate:

1. Re-read the cited lines **and their surrounding context** (the guard you think
   is missing may exist a few lines up, in `setup`, or in a called unit).
2. Ask: *would this actually fire at runtime / is it actually exploitable?* If you
   cannot defend it with the excerpt, **drop it or downgrade confidence to LOW**.
3. Keep only candidates you can stand behind. Default to dropping when uncertain —
   a missed nit is cheaper than a wrong accusation.

Survivors must each have: `severity`, `category`, `location` (line/unit),
`evidence` (the quoted code), `remediation` (a concrete fix), `confidence`, and
`coverage` (`CHECKED`, or `COULD_NOT_CHECK` for auth findings without the SU21
cache).

---

## Step 5 — Write Candidate Findings JSON

Write the survivors to `{OUT}\candidate_findings.json` — a flat array; the emitter
in Step 6 turns these into proper finding records, gates them, and exports.

```json
[
  {
    "severity": "HIGH",
    "category": "SELECT_IN_LOOP",
    "location": "FORM get_prices, line 214",
    "detail": "SELECT on MARA executed once per LOOP AT lt_items iteration (~N round-trips).",
    "evidence": "LOOP AT lt_items INTO ls_item.\n  SELECT SINGLE matnr FROM mara WHERE matnr = ls_item-matnr ...",
    "remediation": "Pre-select all matnr into a hashed table before the loop, or use FOR ALL ENTRIES with an emptiness guard.",
    "confidence": "HIGH",
    "coverage": "CHECKED"
  }
]
```

If there are **zero** survivors, still write `[]` — a clean review is a result,
not a no-op.

---

## Step 6 — Emit: Gate + Verdict + Export + Register

Run this block (pure file I/O — any PowerShell; no SAP/RFC). It is the only
deterministic plumbing: the *judgement* was yours, the *gate* is the brief's.

```powershell
$shared = '<SAP_DEV_CORE_SHARED_DIR>\scripts'
. "$shared\sap_finding_lib.ps1"
. "$shared\sap_gate_policy.ps1"

# NOTE: ConvertFrom-Json emits a multi-element array as ONE pipeline object, so
# `@(... | ConvertFrom-Json)` wraps (not unrolls) it — the loop would then bind
# $c to the whole array and $c.severity would be an array. Assign first, then
# normalize to an array. (Live-test bug, S4D 2026-06-03.)
$cands = Get-Content '{OUT}\candidate_findings.json' -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $cands) { $cands = @() } elseif ($cands -isnot [System.Array]) { $cands = @($cands) }
$obj   = [pscustomobject]@{ pgmid = '{PGMID}'; object = '{TADIR_OBJ}'; obj_name = '{OBJECT}' }

$findings = @()
foreach ($c in $cands) {
  $cov = if ("$($c.coverage)") { "$($c.coverage)" } else { 'CHECKED' }
  $findings += New-SapFinding -Severity $c.severity -Category $c.category -Detail "$($c.detail)" `
      -Object $obj -Location "$($c.location)" -Evidence "$($c.evidence)" `
      -Remediation "$($c.remediation)" -Confidence $c.confidence -Source 'REVIEW-ABAP' -Coverage $cov
}

# Gate via the customer brief's Quality bar (Sec6). --gate block => -Strict.
$policy  = Get-SapGatePolicy -BriefPath '{BRIEF_PATH}' -Strict:{STRICT}
Set-SapFindingGates -Findings $findings -Policy $policy
$verdict = Get-SapVerdict -Findings $findings

# Scope key (best-effort; falls back to a plain string if artifact lib unavailable)
$scope = '{TADIR_OBJ}_{OBJECT}'
try { . "$shared\sap_artifact_lib.ps1"; $scope = New-SapScopeKey -Resolved $obj } catch {}

$tsv = Export-SapFindingsTsv  -Findings $findings -Path '{OUT}\{OBJECT}.review.tsv'  -Scope $scope -Verdict $verdict
$jsn = Export-SapFindingsJson -Findings $findings -Path '{OUT}\{OBJECT}.review.json' -Scope $scope -Verdict $verdict
Write-Output "REVIEW_VERDICT: $verdict  FINDINGS: $(@($findings).Count)"
Write-Output "REVIEW_TSV: $tsv"
Write-Output "REVIEW_JSON: $jsn"

# Register for /sap-evidence-pack (best-effort — never fail the review on this)
try {
  Register-SapArtifact -Skill 'sap-review-abap' -ScopeKey $scope -Kind 'code-review' -Format 'tsv'  -Path $tsv -Object '{OBJECT}' -Verdict $verdict | Out-Null
  Register-SapArtifact -Skill 'sap-review-abap' -ScopeKey $scope -Kind 'code-review' -Format 'json' -Path $jsn -Object '{OBJECT}' -Verdict $verdict | Out-Null
} catch { Write-Output "WARN: artifact registration skipped ($($_.Exception.Message))" }
```

Token substitution before running: `{OUT}`, `{OBJECT}`, `{PGMID}`, `{TADIR_OBJ}`,
`{BRIEF_PATH}` (the resolved brief path), and `{STRICT}` = `$true` when
`--gate block`, else `$false`.

**Verdict semantics** (`Get-SapVerdict`): `NO_GO` if any finding gated `BLOCK`,
else `GO_WITH_WARNINGS` if any `WARN` **or** any `COULD_NOT_CHECK`, else `GO`. In
`--gate advisory` (default) this verdict is *informational* — present it, do not
treat it as a hard stop. In `--gate block` it is a real pre-deploy gate.

---

## Step 7 — Synthesize `review.md`

Read `{OUT}\{OBJECT}.review.tsv` + `map.json` and write `{OUT}\review.md`:

1. **Verdict banner** — `GO` / `GO_WITH_WARNINGS` / `NO_GO`, with BLOCK/WARN/INFO
   counts and the gate mode (advisory vs block).
2. **Findings**, grouped severity-desc, each: location · category · the **code
   excerpt** · why it matters · the concrete fix · confidence. If `--callers`,
   annotate high-severity items with blast radius (how many callers).
3. **Not checked (honesty section)** — macros / generated code not reasoned over,
   dynamic dispatch (`CALL FUNCTION lv_`, `CALL METHOD (lv_)`) not traced, and —
   if the SU21 cache was absent — that auth-object findings are `COULD_NOT_CHECK`.
   Mirror the `/sap-explain-object` and `/sap-impact-analysis` honesty contract:
   say what you did **not** verify.
4. **Suggested next steps** — `/sap-fix-abap` for mechanical items, `/sap-atc` for
   the hard gate, `/sap-gen-abap-unit` if coverage on the risky paths is thin.

---

## Step 8 — Report & Clean Up

Print the `{OUT}` path and a ≤6-line summary: object/type, verdict, finding counts
by severity, and the single highest-priority item. Leave `{OUT}` artifacts in
place (they are the deliverable and are registered for `/sap-evidence-pack`).
Remove only scratch files:

```bash
cmd /c del "{WORK_TEMP}\review_dl.vbs" 2>nul
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_review_abap_run.json" -Status SUCCESS -ExitCode 0
```

| Outcome | Status / ExitCode / ErrorClass |
|---|---|
| Review completed (any verdict) | `-Status SUCCESS -ExitCode 0` |
| `--gate block` and verdict `NO_GO` | `-Status SUCCESS -ExitCode 1 -ErrorClass REVIEW_GATE_BLOCKED -ErrorMsg "<n> BLOCK"` |
| Object not found | `-Status FAILED -ExitCode 1 -ErrorClass OBJECT_NOT_FOUND` |
| Source could not be acquired | `-Status FAILED -ExitCode 2 -ErrorClass REVIEW_SOURCE_UNAVAILABLE` |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: no RFC connection` | not logged in / RFC creds missing | run `/sap-login` |
| class source missing / `--no-gui` set | no GUI session for SE24 download | drop `--no-gui` and ensure a session, or accept signature-only review |
| every auth finding shows `COULD_NOT_CHECK` | no `_authz_signatures.txt` cache | run `/sap-gen-abap` (or a future SU21 prefetch) on the work folder first; expected and disclosed |
| `Get-SapGatePolicy` falls back to defaults | brief is the empty template | fill `{custom_url}\customer_brief.md` §6 Quality bar to control gating |

---

## Limitations

- **Judgement, not proof.** Findings are reasoned, not theorem-proved. Step 4b +
  mandatory evidence keep precision high, but treat MEDIUM/LOW-confidence items as
  prompts for a human, not verdicts. Advisory by default for exactly this reason.
- **Active version only** in OBJECT mode (use FILE mode for an in-flight copy).
- **Class source is the display view** (pretty-printed) — flagged in the report.
- **Dynamic dispatch and macros are not traced** — always disclosed in §3 of
  `review.md`.
- **Single object per invocation** (like `/sap-atc`, `/sap-run-abap-unit`). For a
  TR or package, resolve+expand the inventory and call once per object, logging
  what you skip — never silently truncate.
- **Read-only.** Never deploys, activates, or edits. `/sap-fix-abap` applies fixes.

---

## Pipeline Integration

```
sap-gen-abap → sap-check-abap → [ sap-review-abap ] → sap-atc → sap-fix-abap → deploy
                (deterministic)     (semantic, you)    (gate)     (apply)
```

The `.review.tsv` / `.review.json` use the shared finding schema, so the verdict
composes directly into `/sap-transport-readiness` and the artifacts are collected
by `/sap-evidence-pack` under this object's scope.
