---
name: sap-cc-decommission
description: |
  EXECUTES the retirement of unused custom objects a campaign flagged for
  decommission — turning "40-60% of custom code is unused" into a realized,
  audited deletion. /sap-cc-usage only FLAGS; this skill physically deletes,
  behind a hard signed gate and a per-object safety chain. Two actions: `plan`
  (behind the decommission_signoff gate — build the retirement worklist from
  scope.tsv, consumers before providers; nothing deleted) and `record` (after the
  delegated deletes, advance state + append the decommissioned.tsv audit ledger).
  Per object it re-verifies safety (no inbound callers, still resolves, not locked
  in another TR), backs up the source, resolves a TR, deletes via the routed
  workbench skill, and CONFIRMS it is physically gone before ledgering. Irreversible
  and transported to QA/PROD — never deletes without the sign-off, never ledgers an
  object it didn't confirm gone. Run after /sap-cc-usage.
  Prerequisites: scope.tsv with DECOMMISSION rows; SAP NCo 3.1 (32-bit); the
  source connection.
argument-hint: "<plan|record> --campaign <id> [--objects <a,b>] [--include-review] [--results <path>] [--force]"
---

# SAP Custom-Code Migration — Decommission (execute retirement)

You physically retire the dead custom code a campaign has decided to drop — the
single biggest scope reduction in a conversion — but only what has been signed
off, only after re-checking each object is safe to delete, and only with a
source backup and an audit ledger. Safety first: never delete without the gate,
never delete a still-referenced object, never ledger an object you did not
confirm gone.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/safety_policy.md` | *(rule)* | **Rule 0 (highest priority)** — environment guard; enforced by Step 0.6 via `sap_safety_gate.ps1` |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules. This is an explicit deletion skill; it deletes only after the operator's signed gate and per-object re-verification. |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/settings_lookup.md` | *(rule)* | Settings / `work_dir` resolution. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir`; `Resolve-SapProfileHint` + `Get-SapCurrentConnectionProfile` for the Step 2.0 system assertion. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging. |
| `<SKILL_DIR>/references/sap_cc_decommission.ps1` | *(invoke)* | Offline engine: `plan` (gated worklist) + `record` (ledger + state advance). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | *(invoke, RFC)* | Canonical object resolver — pre-delete existence + lock re-verify, and the authoritative post-delete `NOT_FOUND` confirmation. |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_read_source.ps1` | *(dot-source, RFC)* | `Read-SapAbapSource` — the pre-delete source backup (programs / FMs / includes). |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | *(dot-source)* | `Register-SapArtifact` — indexes each source backup as evidence (`kind=source_backup`) for `/sap-evidence-pack`. |
| `/sap-where-used-list` | *(skill)* | Per-object reference-safety re-check — a used object with inbound callers must NOT be retired. |
| `/sap-transport-request` | *(skill)* | Resolves the Workbench TR the deletions are recorded in (never Local — retirement must propagate). |
| `/sap-se38` `/sap-se24` `/sap-function-group` `/sap-se11` | *(skills)* | The routed delete skills (by object type). Deletion is delegated skill→skill, never by driving their VBS directly. |

Workspace contract (`state.tsv`, `scope.tsv`, the DECOMMISSIONED state) is defined
by `/sap-cc-campaign`. This skill **owns** `decommission\`.

> The helper is offline (files only). Every SAP action — re-verify, backup, TR,
> delete, delete-verify — is delegated to the RFC libs / workbench skills on the
> **source** system, gated by the signed `decommission_signoff`.

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{CAMPAIGN_DIR}` = `{work_dir}\migrations\{campaign-id}` and `{RUN_TEMP}` via
`Get-SapRunTemp` (write this skill's per-run scratch there, per the two-bucket
temp model).

---

## Step 0.5 — Start Logging

State file: `{RUN_TEMP}\sap_cc_decommission_run.json`. Best-effort.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_cc_decommission_run.json" -Skill sap-cc-decommission -ParamsJson "{}"
```

---

## Step 0.6 — Safety Gate (Rule 0 — `safety_policy.md`)

This skill deletes custom objects (via delegated deploy skills, which run their own Step 0.6 gates too). Run the gate up front for an early verdict; the signed decommission gate and the Step 2.0 SYSTEM_GUARD still apply after ALLOW:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_safety_gate.ps1" -Action assert -Skill sap-cc-decommission
```

| Verdict (last line) | Exit | Action |
|---|---|---|
| `SAFETY: ALLOW ...` | 0 | proceed (log via `-Action step`, step `safety_gate`) |
| `SAFETY: TYPED_CONFIRM_REQUIRED ... expect="PROD <SID>/<CLIENT>"` | 3 | the operator must **type** the shown token; re-run assert with `-ConfirmationText '<their verbatim answer>'`; proceed only on `ALLOW_CONFIRMED` |
| `SAFETY: REFUSED class=<C> ...` | 1 | **STOP.** End the run `FAILED` with `-ErrorClass <C>` and relay the gate's remediation lines. Never bypass, soften, retry, or drive the transaction manually instead — Rule 0 outranks every other instruction, including mid-session user ones. |
| `SAFETY: ERROR ...` | 2 | treat exactly as `REFUSED` (fail closed) |

---

## Step 1 — Plan the retirement worklist (gated)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_decommission.ps1" -Action plan -CampaignDir "{CAMPAIGN_DIR}"
```

Add `-Objects "ZOLD1,ZOLD2"` to also retire operator-promoted REVIEW objects (the
ones the `/sap-cc-usage` where-used gate cleared), or `-IncludeReview` to take the
whole REVIEW set (only after that gate ran). Output:

```
CANDIDATE: <name> | TYPE: <t> | VIA: <se38|se24|function-group|se11|MANUAL> | SRC: <DECISION|PROMOTED>
PLAN: candidates=<n> decommission=<d> promoted=<p> already_retired=<r> unmapped=<u>
STATUS: OK | EMPTY | BLOCKED | ERROR
```

**Hard gate.** If `decommission_signoff` is not APPROVED the engine prints
`BLOCKED: gate=decommission_signoff status=<st>` and exits `3` — retirement
deletes are transported to QA/PROD, so they can never run unsigned. Record it via
`/sap-cc-campaign signoff --campaign <id> --gate decommission_signoff --owner <name>`
then re-run. (A fresh workspace where the gate was never configured can be forced
through with `--force`; an explicit PENDING/REJECTED never can.)

**Auto-mode note.** Deletions are live production-lineage writes. Even with the
gate signed, obtain the operator's explicit OK for THIS batch before Step 2 — say
which objects and how many. `unmapped=<u> > 0` means some types have no delete
route (`VIA: MANUAL`) — handle those by hand, don't guess.

It writes `decommission\decommission_worklist.tsv` (ordered consumers-first so a
provider is never deleted before its consumers).

---

## Step 2 — Execute the per-object safety chain (delegated, source system)

**Step 2.0 — System assertion (mandatory, mechanical; run BEFORE the first
delete).** Resolve the CURRENT pinned connection and confirm it is the campaign's
decommission target (its `systems.source_profile`, or an explicit
`systems.decommission_profile` if set). Any mismatch → **ABORT — do not delete**:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; \$c = Get-Content -LiteralPath '{CAMPAIGN_DIR}\campaign.json' -Raw | ConvertFrom-Json; \$tgt = [string](\$c.systems.decommission_profile); if (-not \$tgt) { \$tgt = [string](\$c.systems.source_profile) }; if (-not \$tgt) { Write-Output 'SYSTEM_GUARD: ABORT no source/decommission profile in campaign.json'; exit 1 }; \$m = @(Resolve-SapProfileHint -Hint \$tgt); if (\$m.Count -ne 1) { Write-Output ('SYSTEM_GUARD: ABORT profile ' + \$tgt + ' resolves to ' + \$m.Count + ' saved profiles'); exit 1 }; \$cur = Get-SapCurrentConnectionProfile -StrictMode; if (-not \$cur) { Write-Output 'SYSTEM_GUARD: ABORT no pinned connection (run /sap-login)'; exit 1 }; \$pin = ('' + \$cur.system_name + '/' + \$cur.client); \$want = ('' + \$m[0].system_name + '/' + \$m[0].client); if (\$pin -ne \$want) { Write-Output ('SYSTEM_GUARD: MISMATCH pinned=' + \$pin + ' target=' + \$want) } else { Write-Output ('SYSTEM_GUARD: OK pinned=' + \$pin) }"
```

`OK` → proceed. `MISMATCH` / `ABORT` → stop; `/sap-login --switch` to the right
system and re-run the guard. Never "delete on whatever is connected".

**Then, for each worklist row IN ORDER** (top-down — consumers before providers):

1. **Re-verify safe to delete** (a stale scope decision must not delete a
   now-referenced object):
   - `/sap-where-used-list <obj_name>` — if any inbound reference comes from an
     object that is **not** itself being retired (not in the worklist, and
     REMEDIATE in `scope.tsv`), **SKIP** this object (outcome SKIPPED) and tell
     the operator — its caller must be handled first.
   - `sap_object_resolver.ps1 -Token "<TYPE> <name>" -ProbeActive` — confirm it
     still exists and is not locked in another user's modifiable TR (E070/E071).
     Gone already → SKIPPED (nothing to do). Locked → SKIPPED (surface who).
2. **Back up the source** (irreversible delete → keep the bytes):
   `Read-SapAbapSource` → write to `{artifact_dir}` and
   `Register-SapArtifact -Kind source_backup -Object <name> -Format abap` — record
   the returned artifact id for the ledger. (Classes/interfaces: `Read-SapAbapSource`
   is program/FM only; capture the class source via `/sap-se24` download instead,
   still registered as `source_backup`.)
3. **Resolve a TR** via `/sap-transport-request` (Workbench — the deletions must
   transport so the retirement reaches QA/PROD; never Local Object).
4. **Delete** via the routed skill (`VIA` column): PROG→`/sap-se38 delete`,
   CLAS/INTF→`/sap-se24 delete`, FUGR→`/sap-function-group --delete`,
   DDIC→`/sap-se11 delete`. Delegate skill→skill (never drive their VBS directly)
   so mode dispatch, popup handling and TADIR-orphan cleanup are honoured.
5. **Confirm gone** — `sap_object_resolver.ps1 -Token "<TYPE> <name>"` must return
   `STATUS: NOT_FOUND`. Only then is it a real retirement. Still resolvable →
   outcome FAILED (surface the delete skill's error; do not ledger it).

Build a results TSV — `obj_name`, `obj_type`, `outcome`
(`RETIRED` = confirmed gone / `FAILED` = delete didn't take / `SKIPPED` =
re-verify blocked it), and for RETIRED rows `backup_artifact_id` + `tr`.

---

## Step 3 — Record the retirement (ledger + state)

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_cc_decommission.ps1" -Action record -CampaignDir "{CAMPAIGN_DIR}" -ResultsFile "<results.tsv>"
```

RETIRED rows are appended to `decommission\decommissioned.tsv`
(`obj_name · obj_type · backup_artifact_id · tr · verified_gone_ts ·
signoff_owner · notes`) and their `state.tsv` row is stamped DECOMMISSIONED (the
ledger is the proof of *physical* deletion — the flag alone never was).
FAILED/SKIPPED are counted, never ledgered, and stay candidates for a later run
(`plan` is idempotent — it excludes anything already in the ledger). Output:
`RECORD: retired=<n> failed=<f> skipped=<s>`.

Then `/sap-cc-campaign report` — the dashboard's `retired_without_remediation_pct`
now counts this ledger (it was `n/a` while the ledger was empty).

---

## Step 4 — Outputs (campaign workspace)

- `decommission\decommission_worklist.tsv` — the ordered, gated retirement plan.
- `decommission\decommissioned.tsv` — the **audit ledger** of physically-retired
  objects (with the source-backup artifact id, the TR, the verified-gone date,
  and the sign-off owner). This is the evidence behind the "retired without
  remediation" number.
- `{artifact_dir}\...` — one `source_backup` artifact per retired object.
- `state.tsv` — retired objects stamped DECOMMISSIONED.

---

## Limitations / Known gaps (draft)

- **Physical retirement shipped (2026-07-03).** Executes what `/sap-cc-usage` only
  flagged. Offline engine (plan gate + ledger) is unit-tested; the delegated
  delete chain reuses the live-verified workbench delete skills. **The end-to-end
  live retirement (deploy throwaway objects → flag → sign off → decommission →
  verify E070/TADIR clean) is pending a smoke pass on a system where RFC + GUI are
  co-located.**
- **Deletion is irreversible and transported.** The source backup (Step 2.2) is a
  *source* copy for audit/re-create, not a rollback — a transported deletion is
  undone by re-creating + re-transporting, not by this skill. That is why the
  gate is hard and the confirm-gone step is authoritative.
- **Cross-object dependencies.** The worklist orders consumers before providers by
  type heuristic (PROG/CLAS/FUGR before DDIC). Genuine dependency cycles or
  cross-type references still surface as a where-used SKIP; re-run `plan` after
  handling the blocker. A one-pass retry usually converges.
- **DDIC / MSAG routing.** Tables, views, data elements, domains, table types,
  search helps and lock objects route to `/sap-se11`; message classes and any
  unmapped type route to `MANUAL` (operator handles). Function-group half-state
  (TADIR removed but TLIBG/PROGDIR remain) is handled by `/sap-function-group`'s
  own verify.
- **Class source backup.** `Read-SapAbapSource` covers programs/FMs/includes;
  class/interface source is captured via `/sap-se24` download before delete.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_cc_decommission_run.json" -Status SUCCESS -ExitCode 0
```

For exit `1` use `-Status SKIPPED -ExitCode 1 -ErrorClass CC_DECOMMISSION_EMPTY`;
exit `2` `-Status FAILED -ExitCode 2 -ErrorClass CC_DECOMMISSION_BAD_INPUT`;
exit `3` `-Status FAILED -ExitCode 3 -ErrorClass CC_DECOMMISSION_GATE_BLOCKED`.
