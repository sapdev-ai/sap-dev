---
name: sap-transport-sequencer
description: |
  Orders a set of transport requests into a safe import sequence and audits code
  freezes — read-only over RFC, detect-only (never imports, never releases). `sequence`
  reads the TR set from the source system, folds LIMU objects into their R3TR parents,
  builds an object-overlap graph, orders by release timestamp under overlap constraints,
  and flags unreleased TRs, same-object overlaps, still-modifiable overtakers, and
  source-side missing predecessors; with `--target` it cross-checks a second system for
  unimported predecessors and first-time-delivery objects. `freeze-audit` finds TRs
  released or changed inside a freeze window minus policy exceptions, with per-violation
  VRSD change-evidence. Emits a sequence + conflicts report with a ready-to-paste
  `/sap-stms import` command list (never executed). Fills the cross-TR gap
  /sap-transport-readiness explicitly defers. Prerequisites: pinned profile via
  /sap-login (+ a second profile for `--target`); SAP NCo 3.1 (32-bit). No GUI, no
  Z-object, no dev-init.
argument-hint: "sequence <TR1,TR2,…|--file=<path>> [--target=<profile>] [--max=200] [--skip-missing]  |  freeze-audit --from=YYYYMMDD --to=YYYYMMDD [--policy=<path>]"
---

# SAP Transport Sequencer & Freeze Auditor

You turn the release manager's hand-sorted import spreadsheet into a computed,
explained sequence — and turn "the freeze was enforced by email and hope" into an
audit trail. Read-only. **This skill never imports and never releases** — the ordered
`/sap-stms import` lines are text the operator runs.

Task: $ARGUMENTS

**Detect-only by design.** No `import`, `release`, or `enforce` verb exists here.
Execution stays with /sap-stms and its typed production gates (a human decision).

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_seq_read.ps1` | `-Trs -MaxTrs [-SkipMissing] -OutDir` | Source reads: headers/objects (normalized)/reverse-overlap/tasks |
| `<SKILL_DIR>/references/sap_seq_graph.ps1` | `-InDir -OutDir` | **Offline** order + conflict graph |
| `<SKILL_DIR>/references/sap_seq_target.ps1` | `-Against -ObjectsTsv -OverlapsTsv -OutDir` | Target predecessor + first-time-delivery check |
| `<SKILL_DIR>/references/sap_freeze_audit.ps1` | `-From -To -PolicyJson -OutDir` | Freeze-window violation audit |
| `<SKILL_DIR>/references/sap_seq_vrsd.ps1` | dot-source | VRSD materiality (`Get-VrsdInWindow`) |
| `<SKILL_DIR>/references/freeze_policy_template.json` | template | Freeze policy shape; override at `{custom_url}\freeze_policy.json` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` / `sap_rfc_lib.ps1` / `sap_artifact_lib.ps1` | dot-sourced / Step 5 | RFC, profile resolution, artifact index |

---

## Step 0 — Resolve Work Directory & OUT

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('CUSTOM_URL=' + (Get-SapSettingValue 'custom_url' ((Get-SapWorkDir) + '\custom')))"
```

Set `{RUN_TEMP}` via `Get-SapRunTemp`. `{OUT}` = `Get-SapArtifactDir -ScopeKey
TRSET_<8-char hash of sorted TR list> -Skill sap-transport-sequencer` (sequence) or
`FREEZE_<SID>_<from>_<to>` (audit).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_transport_sequencer_run.json" -Skill sap-transport-sequencer -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Mode Dispatch

First token `sequence` | `freeze-audit`; a bare TR list implies `sequence`. Validate:
- **sequence**: TR list non-empty, ≤ `--max` (default 200, hard cap 500) else
  `SEQ_INPUT_INVALID`. `--file=<path>` reads a newline/comma TR list. `--skip-missing`
  demotes an unknown TR from hard error to a WARN finding.
- **freeze-audit**: window both-bounded and ≤ 92 days else `FREEZE_WINDOW_UNBOUNDED`.
- `--keys` (E071K key-level overlap) and `--deep` (TMS queue + VRSD downgrade) are
  **NOT_YET_IMPLEMENTED** (v1.5 / v2) → say so and STOP.

No write modes exist → **no confirm-gate step**.

---

## Step 2 (sequence) — Read → Graph → Target

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_seq_read.ps1" -Trs "<TR1,TR2,...>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_seq_graph.ps1" -InDir "{OUT}" -OutDir "{OUT}"
```

Parse the read's `STATUS:` — `SEQ_TR_NOT_FOUND` (exit 1, unless `--skip-missing`) →
list the `MISSING:` TRs, STOP. The graph writes `sequence.tsv` + `conflicts.tsv` and
emits `SEQ:`/`CONFLICT:`/`STATUS: OK ordered=.. unimportable=.. conflicts=..`.

**With `--target=<profile>`**, run the target check (a second /sap-login profile,
read-only):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_seq_target.ps1" -Against "<profile>" -ObjectsTsv "{OUT}\objects.tsv" -OverlapsTsv "{OUT}\overlaps.tsv" -OutDir "{OUT}"
```

`SEQ_TARGET_UNREACHABLE` → ask the user: continue source-only (target rows
`COULD_NOT_CHECK`, verdict capped at GO_WITH_WARNINGS) or abort. Never silently degrade.

## Step 3 (sequence) — Narrate the Sequence (you write this)

Write `sequence_narrative.md` into `{OUT}` from `sequence.tsv` + `conflicts.tsv`
(+ `target_check.tsv`). **Grounding rule: every constraint traces to a shared object.**
1. **Ordered import list** — position, TRKORR, release_ts, owner, description,
   `constrained_by`; explain WHY each is placed there ("must follow S4DK902334 because
   both touch ZCL_GOLDEN_TAX").
2. **Conflicts** — severity-sorted: OVERLAP / SAME_TIMESTAMP (date-granularity ambiguity)
   / UNRELEASED (listed TR or open task) / MISSING_PREDECESSOR / OVERTAKER_RISK /
   (with target) UNIMPORTED_PREDECESSOR / FIRST_TIME_DELIVERY.
3. **Handoff block** — the ordered `/sap-stms import <TR> --to <SID>` lines, prefixed
   with an explicit "**run these yourself** — this skill never imports" note. Suggest
   `/sap-transport-readiness <TR>` for each HIGH-conflict TR (do not auto-invoke).
   State that v1 customizing overlap is **table-level** (disjoint E071K keys not yet
   distinguished — conservative, never unsafe).

## Step 2' (freeze-audit) — Audit the Window

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_freeze_audit.ps1" -From <YYYYMMDD> -To <YYYYMMDD> -PolicyJson "<{custom_url}\freeze_policy.json|template>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Policy resolves `--policy` → `{custom_url}\freeze_policy.json` → the template; CLI
`--from/--to` override the window. Parse `FREEZE:`/`VIOLATION:`/`STATUS:`. Write
`freeze_annex.md`: each violation (severity, RELEASED vs CHANGED, user, date, **VRSD
version count** = did the object really change in-window), exceptions applied, and the
honest caveat: "E070 stores no creation date — AS4DATE is last-change/release date;
released-after-window edits are caught by VRSD evidence, not this pass."

## Step 4 — Register & Log End

Register `sequence.tsv` (kind `transport_sequence`), `conflicts.tsv` (kind
`transport_conflicts`, Verdict via `Get-SapVerdict`), `sequence_narrative.md`, or
`violations.tsv` + `freeze_annex.md` (kind `freeze_audit`) via `Register-SapArtifact`.
Echo:

```
SEQ: trs=<n> ordered=<n> unimportable=<n> conflicts=<n> verdict=<..>
FREEZE: window=<from>..<to> violations=<n> verdict=<..>
```

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_transport_sequencer_run.json" -Status SUCCESS -ExitCode 0
```

Refusals end `-Status SKIPPED -ErrorClass <SEQ_*/FREEZE_*>`; infra failures `FAILED`.

---

## Scope & Limitations

- **v1 implemented:** `sequence` (source read + offline overlap graph + order +
  `--target` predecessor/first-time cross-check) and `freeze-audit` (windowed E070 +
  policy exceptions + VRSD materiality). LIMU→R3TR object fold (REPS→PROG, class parts→
  CLAS, FUNC→FUGR via ENLFDIR). Read-only; never imports/releases.
- **Single code path on ECC 6 and S/4HANA** — all E070/E070A/E071/E07T/TADIR/VRSD reads
  are TRANSP/FMODE=R, identical on both (transport is SAP's most release-stable layer).
- **Conflict categories:** OVERLAP, SAME_TIMESTAMP (release timestamp is date+time
  granularity — equal-timestamp overlapping pairs are flagged, not silently ordered),
  UNRELEASED (listed TR or open task under a released header), MISSING_PREDECESSOR,
  OVERTAKER_RISK (a still-modifiable TR touching a listed object), and with `--target`
  UNIMPORTED_PREDECESSOR / FIRST_TIME_DELIVERY.
- **Honesty:** an unknown TR is `SEQ_TR_NOT_FOUND` (hard, unless `--skip-missing`); an
  unreachable target is an explicit continue/abort choice with `COULD_NOT_CHECK` rows;
  row caps surface as `>N`; an empty freeze window states "no violations FOUND in
  <window>" with the E070-creation-date caveat.
- **Not yet:** `--keys` E071K key-level customizing overlap (v1.5 — v1 customizing
  overlap is table-level, conservative); `--deep` TMS import-queue read (wrapper-routed +
  domain-controller-bound) and per-object VRSD downgrade compare (v2);
  `--since-last-run` freeze ledger (v1.5).
- Verified live S/4HANA 1909 (S4D) + ECC 6 (EC2/ERP) 2026-07-11: a 5-TR set with a real
  Golden-Tax overlap chain (S4DK902334→902824→902825) and a REPS/PROG LIMU-fold pair
  (ordered correctly, overlaps + overtakers + missing-predecessors detected);
  freeze-audit over a busy build week with VRSD materiality (322/320/57 versions); window
  cap, target cross-check (mechanical S4D→ERP), and OR-chunked reads on both releases.
