---
name: sap-golden-master
description: |
  Golden-master regression testing for SAP report output and table state — answers
  "does this produce the same output after the change?" as one command instead of a
  manual before/after Excel diff. capture stores a deterministic baseline (a report's
  background spool via /sap-run-report + /sap-job + /sap-sp02, or a table dump via
  /sap-se16n), normalizing away volatile tokens (dates, times, timestamps, the capture
  user, page headers). verify re-runs the identical variant, normalizes, diffs, and
  Claude triages each hunk against the TR/spec into EXPECTED vs REGRESSION, emitting a
  GO / REGRESSION / COULD_NOT_VERIFY verdict registered for /sap-evidence-pack. rebase
  replaces the golden after an intended change. Baselines are keyed per (SID, CLIENT) —
  an S4D golden can never silently verify against another system. Pure composition of
  shipped skills — no new Z object, no driving VBS. Ships the sapdev.goldenmaster/1
  manifest for /sap-test-replay to build on. Prerequisites: active SAP GUI session
  (/sap-login) for the delegated capture legs; SAP NCo 3.1 (32-bit) for the RFC meta reads.
argument-hint: "capture <ID> (--report PROG [--variant V] | --table TAB --select F1,F2 [--where ...] [--key ...]) | verify <ID> [--tr TRKORR] [--spec file] | rebase <ID> | list | show <ID> | delete <ID>"
---

# SAP Golden Master Skill

You capture a deterministic **golden baseline** of a report's output or a table's
state, and later **verify** a re-run against it — surfacing real regressions while
normalizing away volatile tokens, and triaging each difference against the TR/spec.

Task: $ARGUMENTS

You own storage, normalization, diff, triage, and verdict. All SAP execution is
**delegated** to shipped skills (their confirm gates are THE gates — never bypass them).

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_gm_manifest.ps1` | `-Action create\|list\|show\|sha1\|path\|delete` | Baseline store layout + skeleton manifest |
| `<SKILL_DIR>/references/sap_gm_meta.ps1` | `-Action identity\|fingerprint\|keys\|trtext` | RFC meta (system identity, VARID fingerprint, DD03L keys, TR text) |
| `<SKILL_DIR>/references/sap_gm_normalize.ps1` | `-InputFile -OutputFile -AppliesTo SPOOL\|TABLE [-CaptureUser -SortKeys -Sort]` | Volatile-token normalizer (offline) |
| `<SKILL_DIR>/references/sap_gm_diff.ps1` | `-GoldenFile -CurrentFile -OutDir [-KeyColumns]` | Golden-vs-current diff (offline; keyed for tables) |
| `<SKILL_DIR>/references/golden_master_normalization_rules.tsv` | read by normalize | Volatile-token rules (customer-overridable via `{custom_url}`) |
| `/sap-run-report` · `/sap-job` · `/sap-sp02` | sub-skills | Report background run + spool download (report legs) |
| `/sap-se16n` | sub-skill | Table dump (table legs) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | Verdict registration for /sap-evidence-pack |

Baseline store: `{golden_master_dir}\<SID>_<CLIENT>\<ID>\` (default `golden_master_dir`
= `{work_dir}\golden_masters`). `manifest.json` (schema `sapdev.goldenmaster/1`) holds
system identity, source legs (kind + replay args + key columns + variant fingerprint),
and golden file hashes; `golden\<leg>.raw.txt` / `.norm.txt`; per-verify `runs\<run_id>\`.

---

## Step 0 — Resolve Directories

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended) and `golden_master_dir` via
`Get-SapSettingValue 'golden_master_dir' "{work_dir}\golden_masters"`. `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging
(`sap_log_helper.ps1`, state `{RUN_TEMP}\sap_golden_master_run.json`).

## Step 1 — Parse Arguments & Dispatch

Modes: `capture` / `add` / `verify` / `rebase` / `list` / `show` / `delete`.
- `list` / `show <ID>` / `delete <ID>` are **local-only** (no SAP): run
  `sap_gm_manifest.ps1 -Action list|show|delete`. `delete` asks a normal yes/no first.
- `capture` needs exactly one of `--report <PROG>` / `--table <TAB>` (`--select` required
  for a table). `verify` / `rebase` need an existing `<ID>` → else `GM_BASELINE_NOT_FOUND`.

## Step 2 — System Identity Gate

Run `sap_gm_meta.ps1 -Action identity` (RFC) → `IDENTITY: sid=<S> client=<C>`. For
`capture`/`add`, this stamps the baseline's `(SID, CLIENT)`. For `verify`/`rebase`,
**assert it matches the manifest's system** → mismatch = `GM_SYSTEM_MISMATCH`, STOP (an
S4D golden never verifies against another system). Requires a pinned RFC profile + (for
the delegated capture legs) an active GUI session (`/sap-login`).

---

## Step 3 (capture / rebase) — Capture the Golden

Announce the plan first (e.g. "I will run <PROG> variant <V> in background to capture
baseline <ID>"). Create the store: `sap_gm_manifest.ps1 -Action create -Id <ID> -Sid <S>
-Client <C>`. Then per leg:

**Report leg (`--report`):**
1. `sap_gm_meta.ps1 -Action fingerprint -Report <PROG> -Variant <V>` → record
   `FINGERPRINT: version/changed_by/changed_on` (the drift guard).
2. Delegate `/sap-run-report <PROG> --variant=<V> --background` — **its Rule-5 confirm is
   THE execution gate; never re-implement or suppress it.** Poll `/sap-job status <JOB>
   <COUNT>`, get the spool via `/sap-job spool <JOB> <COUNT>`, download unconverted text
   via `/sap-sp02 <SPOOLNO> "<golden\report.raw.txt>" --format=text`.
3. Normalize: `sap_gm_normalize.ps1 -InputFile golden\report.raw.txt -OutputFile
   golden\report.norm.txt -AppliesTo SPOOL -CaptureUser <the run user>`.

**Table leg (`--table`):**
1. Key columns: `--key`, else `sap_gm_meta.ps1 -Action keys -Table <TAB>` → `KEYS: cols=...`.
2. Delegate `/sap-se16n <TAB> [--where ...] select=<F1,F2,...>` → download to
   `golden\<TAB>.raw.txt` (record the exact filters + select as the replay args).
3. Normalize: `sap_gm_normalize.ps1 -AppliesTo TABLE -SortKeys <keys> -HasHeader` (key-sort
   canonicalizes row order).

Then **write the leg into `manifest.json`** (you author the JSON — the manifest `legs`
array): one object per leg with `{leg, kind, report/table, variant/select/where, keys,
fingerprint}`, and set `golden_hashes[<leg>]` = `sap_gm_manifest.ps1 -Action sha1 -LegFile
golden\<leg>.norm.txt`. `rebase` requires an explicit "replace the golden copy of <ID>?
(yes/no)" before overwriting. On any leg failure → fail loud, no partial golden.

---

## Step 4 (verify) — Re-capture, Diff, Triage, Verdict

1. **Variant-drift guard** (report legs): re-run `-Action fingerprint`; if version/change
   stamp differs from the manifest → `GM_VARIANT_DRIFT`, refuse unless `--accept-variant-drift`.
2. **Re-capture** every leg exactly as Step 3 with the manifest's replay args, into
   `runs\<run_id>\<leg>.raw.txt`; normalize with the same rules → `.norm.txt`. A missing
   spool / aborted job / SE16N no-values-where-golden-had-rows → `GM_CAPTURE_INCOMPLETE`,
   verdict `COULD_NOT_VERIFY` (never GO).
3. **Diff**: `sap_gm_diff.ps1 -GoldenFile golden\<leg>.norm.txt -CurrentFile
   runs\<run_id>\<leg>.norm.txt -OutDir runs\<run_id>` (add `-KeyColumns <keys>` for table
   legs) → `DIFF: hunks=<n> ...` + `diff_hunks.tsv`.
4. **AI triage** (you): read the TR text (`sap_gm_meta.ps1 -Action trtext -Tr <TRKORR>`)
   and/or `--spec` file. Classify each hunk **EXPECTED** (must cite the TR/spec text that
   predicts it), **REGRESSION**, or **UNEXPLAINED**. UNEXPLAINED and any hunk-cap overflow
   count as REGRESSION (conservative). Write `triage.md`.
5. **Verdict**: 0 hunks or all EXPECTED → `GO`; any REGRESSION → `REGRESSION`; capture
   failure / missing leg → `COULD_NOT_VERIFY`. Register via `Register-SapArtifact`
   (`-Kind golden_master_verify -Verdict <v> -Coverage CHECKED|COULD_NOT_CHECK -Ticket <TRKORR>`
   scope `PROG_<name>` / `TAB_<name>`). Print the verdict block with per-leg hunk counts.

---

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class); echo artifact paths + the verdict.
A verify that ran (even REGRESSION) is `SUCCESS`. Refusals map to `GM_BASELINE_NOT_FOUND`
/ `GM_SYSTEM_MISMATCH` / `GM_VARIANT_DRIFT` / `GM_CAPTURE_INCOMPLETE`. Answering "no" at a
delegated confirm gate → `SKIPPED`, no partial golden.

---

## Scope & Limitations (v1)

- **v1:** capture/verify/rebase for report (background spool) and table legs; `add` a
  second leg; `list`/`show`/`delete`; deterministic normalization (dates/times/timestamps/
  capture-user/page-headers) + key-sort; keyed table diff / line spool diff; AI triage +
  GO/REGRESSION/COULD_NOT_VERIFY verdict.
- **Phase 2:** `--headless-spool` (RFC spool read, v1.5); ALV interactive capture; scheduled
  drift monitor. Variant *contents* snapshot (RS_VARIANT_CONTENTS* via the wrapper) is a
  v1.5 enhancer — v1 uses the wrapper-free VARID change stamp for drift, so the guard works
  without dev-init; wrapper absence → variant-contents coverage COULD_NOT_CHECK (downgrades
  a clean GO, never a plain GO).
- **Honesty:** COULD_NOT_VERIFY is never GO; UNEXPLAINED hunks count as REGRESSION; EXPECTED
  classifications must cite TR/spec text. Non-deterministic report bodies beyond the token
  classes (unsorted ALV) → `--sort=lines` / key-sort; genuinely order-dependent output is
  diff-noisy (documented; rebase + custom rules are the escape hatch).
- **Read-only toward SAP data**; the only executions are the delegated report runs (their
  Rule-5 gates apply). Baselines keyed per (SID, CLIENT) — no cross-system verify.
