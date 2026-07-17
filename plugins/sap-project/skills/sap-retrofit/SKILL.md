---
name: sap-retrofit
description: |
  Retrofit maintenance-line fixes into the project line without Solution Manager ChaRM — the
  detect/classify loop that a rotting spreadsheet can't do. `harvest` reads released
  maintenance TRs (E070/E071/E07T over RFC); `classify` diffs each object maint-vs-project via
  /sap-compare and gathers project-line change evidence (VRSD versions + E071 dev-TR hits) to
  label it IN_SYNC / GREEN (project untouched — safe to auto-apply) / YELLOW (project also
  changed — needs a merge) / RED (can't diff reliably); `status` rolls up the persistent
  ledger; `draft` writes a reviewable two-way diff + AI merge draft (never deploys); `apply`
  deploys GREEN objects to the project line behind /sap-transport-request with a post-deploy
  re-compare, confirm-gated. The maintenance system is read-only forever. Prerequisites:
  /sap-login profiles (pinned = project line, --maint hint = maintenance line); SAP NCo 3.1
  (32-bit). No Z-object, no dev-init.
argument-hint: "init --project <id> --maint <hint> [--since YYYYMMDD] [--packages Z*,Y*]  |  harvest  |  classify [--max-objects N]  |  status [--report]  |  draft <OBJ>  |  apply --green-only"
---

# SAP Retrofit — Dual-Track Detect / Classify / Apply (no ChaRM)

Re-apply production (maintenance-line) fixes into the project line as a tracked, evidence-based
loop instead of a rotting spreadsheet. **The maintenance line is read-only forever**; the only
SAP writes are confirm-gated GREEN deploys to the project line, delegated to the workbench
skills.

Task: $ARGUMENTS

**Connection roles:** pinned profile (via /sap-login) = **project line** (the write target).
`--maint <hint>` = **maintenance line** (read-only), resolved like /sap-compare's `--against`.
`apply` **hard-refuses** if a write would resolve to the maintenance profile.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SKILL_DIR>/references/sap_retrofit_ledger.ps1` | `-Action init\|append\|set-state\|watermark\|list` | Local workspace + state-machine ledger |
| `<SKILL_DIR>/references/sap_retrofit_harvest.ps1` | `-MaintHint … [-Since -Packages -MaxTrs]` | Released maintenance TRs → per-object rows (RFC, read-only) |
| `<SKILL_DIR>/references/sap_retrofit_evidence.ps1` | `-Objects "TYPE:NAME,…" -Baseline` | Project-line VRSD/E071/TADIR evidence (RFC, read-only) |
| `/sap-compare` (Skill tool) | `<OBJ> --against <maint-hint>` | The maint-vs-project source/DDIC diff (its class-source limit applies) |
| `/sap-se38` · `/sap-se37` (Skill tool) | deploy | `apply` deploy delegates (TR via /sap-transport-request inside them) |
| `/sap-transport-request` (Skill tool) | TR | Never prompt for a TR — always delegate |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_read_source.ps1` | `Read-SapAbapSource` | `apply` maintenance-source fetch |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_finding_lib.ps1` / `sap_artifact_lib.ps1` | Step 8 | Findings + artifact index |

The workspace `{work_dir}\retrofit\<project>\` is a durable Bucket-A path (a later session must
find the ledger) — never under `{RUN_TEMP}`.

## Step 0 — Resolve Work Dir + Workspace

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

`{WS}` = `{work_dir}\retrofit\<project>`. Set `{RUN_TEMP}` = the `RUN_TEMP=` value printed
above (`Get-SapRunTemp` mints + creates the per-run scratch dir holding the log state file) —
for logging state; mint it once here and reuse (re-minting breaks the `-Action end`
state-file lookup).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_retrofit_run.json" -Skill sap-retrofit -ParamsJson "{}"
```

## Step 1 — Mode Dispatch

`init` | `harvest` | `classify` | `status` | `draft` | `apply`. Except `init`, load
`{WS}\project.json` (absent → `RETRO_LEDGER_IO`). Resolve `--maint` via the profile store.
**For `apply`: if the maintenance profile resolves to the SAME SID+client as the pinned
project profile, hard-refuse** (a retrofit that writes back to maintenance is a bug).

## Step 2 — init

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_retrofit_ledger.ps1" -Action init -Workspace "{WS}" -MaintHint "<hint>" -Packages "<Z*,Y*>" -Since "<YYYYMMDD>"
```

Writes `project.json` (maint hint, packages, watermark=since) + empty `ledger.tsv` + `diffs/`,
`drafts/`, `reports/`.

## Step 3 — harvest (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_retrofit_harvest.ps1" -MaintHint "<hint>" -Since "<watermark>" -Packages "<Z*,Y*>" -MaxTrs 500 -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Parse `TR:` and `OBJ: pgmid=… object=… obj_name=… tr=… released=… devclass=…`; append each
object via the ledger (`-Action append`, dedupes across TRs, latest TR wins, all recorded). On
`STATUS: OK`, advance the watermark (`-Action watermark -Since <today>`); `NO_NEW` → nothing to
do. Never advance the watermark on `RFC_ERROR`.

## Step 4 — classify (read-only)

For each HARVESTED object (cap `--max-objects`, default 50):
1. **Diff** — invoke `/sap-compare <OBJ> --against <maint-hint>` via the **Skill tool**; read
   its `diff.json` + unified diff; copy the bundle into `{WS}\diffs\<OBJ>\`.
2. **Evidence** — run `sap_retrofit_evidence.ps1 -Objects "TYPE:NAME" -Baseline <since>`; parse
   `EVIDENCE: … tadir=… vrsd=… e071=…`.
3. **Verdict** (set via ledger `-Action set-state -Evidence "<string>"`):

   | Signal | State |
   |---|---|
   | /sap-compare: sources+DDIC identical | `IN_SYNC` (retrofit already landed) |
   | TADIR `ABSENT` on project | `GREEN` (create path) |
   | diff non-empty AND `vrsd=CLEAN` AND `e071=CLEAN` | `GREEN` |
   | diff non-empty AND (`vrsd=HIT` OR `e071=HIT`) | `YELLOW` (project also changed) |
   | `vrsd=COULD_NOT_CHECK` (versioning off) but `e071=CLEAN` | cap at `YELLOW` — **never GREEN on partial evidence** |
   | /sap-compare `COULD_NOT_CHECK` (classes / RFC failure) or unsupported PGMID | `RED` (manual) |
   | a DDIC object that would be GREEN | `GREEN_MANUAL` (structural merge risk — excluded from auto-apply) |

   **Classes are RED in v1** (/sap-compare's RFC class-source limit). A mid-run RFC failure →
   leave the row HARVESTED + emit `RETRO_CLASSIFY_INCOMPLETE`; never guess a verdict.

## Step 5 — status

`sap_retrofit_ledger.ps1 -Action list -Rollup` → per-state counts + pending. `--report` renders
`{WS}\reports\retrofit_report.md` (state table, conflict/YELLOW list, oldest pending). Register
artifacts.

## Step 6 — draft (YELLOW only, never deploys)

For one YELLOW object: write `{WS}\drafts\<OBJ>.abap` (AI merge draft) + `<OBJ>.rationale.md`
(which hunks are "theirs" from maintenance, which are suspected "ours", confidence — two-way so
attribution is a suspicion, upgraded to fact by the v2 SVRS three-way). Set state `DRAFTED`.
Print the mandatory-review banner. **This mode has no deploy path — enforced by mode
separation.**

## Step 7 — apply (GREEN, confirm-gated write to the PROJECT line)

1. Select GREEN rows (`--green-only`) or explicit `--objects`. `GREEN_MANUAL`/`YELLOW`/`RED` are
   **refused** (`--approved-draft <OBJ>` for a reviewed YELLOW draft is **v1.5**, typed
   `APPLY <OBJ>` confirmation, requires state `DRAFTED`).
2. **CONFIRM gate**: list every object + source maintenance TR + target SID/client, ask
   `yes/no`. Proceed only on explicit yes.
3. Per object: fetch the maintenance source (`Read-SapAbapSource` against the maint profile) →
   delegate to `/sap-se38` (PROG/REPS) or `/sap-se37` (FUNC) via the **Skill tool** (TR resolved
   inside them by /sap-transport-request — never prompt).
4. **Post-deploy verify**: re-run `/sap-compare <OBJ> --against <maint-hint>` — it must now
   report identical → ledger `VERIFIED`; anything else → `VERIFY_FAILED` +
   `RETRO_APPLY_VERIFY_FAILED` (fail loud, never silently green). Continue the batch on a
   single-object failure; summarize.

## Step 8 — Register & Log End

Register the ledger (kind `retrofit-ledger`, coverage tri-state), diffs/drafts/report, and per
apply run a GO/NO_GO verdict via `Get-SapVerdict`. Echo the mode headline. Then:

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_retrofit_run.json" -Status SUCCESS -ExitCode 0
```

---

## Scope & Limitations

- **v1 implemented:** `init`, `harvest`, `classify`, `status`, `draft` (all read-only toward
  SAP / local), and `apply --green-only` (confirm-gated write to the project line via delegated
  workbench skills + post-deploy re-compare verify). The maintenance line is never written.
- **Single code path on ECC 6 and S/4HANA** — all 13 load-bearing objects are FMODE=R / TRANSP
  on both; either line may be ECC or S/4. Verified live 2026-07-11: harvest read released ERP
  maintenance TRs → object rows with descriptions + dedup; project-line evidence on S4D returned
  the real signals (a Z program with **12 VRSD versions + an S4DK workbench-TR hit → YELLOW**;
  standard programs CLEAN; a support-package TR correctly **not** counted as a project change; an
  absent object → GREEN create path).
- **Honest by construction (never a false GREEN / overwritten fix):** evidence is tri-state per
  source — an unreadable source is `COULD_NOT_CHECK`, and partial evidence (VRSD off) **caps at
  YELLOW**, never GREEN; a /sap-compare `COULD_NOT_CHECK` → RED; the ledger state machine refuses
  APPLIED on any non-GREEN/APPROVED row; a post-deploy re-compare mismatch → `VERIFY_FAILED`.
- **Coverage holes (visible, not hidden):** ABAP **classes are RED in v1** (/sap-compare's RFC
  class-source limit); **DDIC** GREEN objects are `GREEN_MANUAL` (excluded from auto-apply —
  structural merge risk); YELLOW drafts are two-way (attribution is a suspicion until v2).
- **Not yet:** `apply --approved-draft` (deploy a reviewed YELLOW merge, typed confirmation) is
  v1.5; the **SVRS three-way merge** (common-ancestor "theirs vs ours" — both SVRS FMs proved
  remote-enabled on S4D + ERP) is v2 and upgrades GREEN to "project version == ancestor".
