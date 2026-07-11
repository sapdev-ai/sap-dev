---
name: sap-config-compare
description: |
  Keyed, row-level RFC diff of ONE customizing table or view across two saved
  connection profiles (or two clients of one system) — the shareable answer to
  "it works in QAS but not in DEV/PRD". Resolves the object on both sides, computes
  the compared-field set (drops the technical client key for client-dependent tables,
  excludes unreadable/too-wide columns honestly), guards against an unbounded read,
  does a chunked offset-based read of each side, and runs the ONE shared keyed-diff
  engine to classify every key LEFT_ONLY / RIGHT_ONLY / CHANGED. Claude then translates
  the raw deltas into functional meaning using DDIC texts. Output is a diffable diff.tsv
  + summary, registered for /sap-evidence-pack. Read-only. Prerequisites: two profiles
  via /sap-login (pinned LEFT + --against RIGHT); SAP NCo 3.1 (32-bit). No GUI, no
  Z-object, no dev-init.
argument-hint: "<TABLE|VIEW> --against <profile-hint> [--where \"F=V,F=A..B\"] [--fields F1,F2] [--keys-only] [--max-rows N]"
---

# SAP Config Compare — Cross-System Customizing Diff

You answer **"why does this work there but not here?"** with a keyed, row-level diff
of one customizing table/view between two systems (or two clients), read-only over
RFC. SCU0/SCMP are GUI-bound and unshareable; two SE16 windows miss rows. This does
the join deterministically and narrates the deltas in functional language.

Task: $ARGUMENTS

**You are read-only against BOTH systems.** No confirm gates, no TR, no GUI. All
output stays local under `{work_dir}`.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — read-only here |
| `<SKILL_DIR>/references/sap_config_compare_read.ps1` | `-Object -Against [-Where -Options -Fields -KeysOnly -MaxRows] -OutDir` | Dual-connect, object resolution, metadata, unbounded guard, chunked offset read |
| `<SKILL_DIR>/references/sap_config_compare_diff.ps1` | `-LeftTsv -RightTsv -MetaJson -OutDir` | Offline keyed diff (dot-sources the shared engine) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_keyed_diff_lib.ps1` | `%%KEYED_DIFF_LIB_PS1%%` | The ONE keyed row-diff engine (shared with /sap-se16n snapshot diff, /sap-compare) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_connection_lib.ps1` / `sap_rfc_lib.ps1` / `sap_dpapi.ps1` | dot-sourced / subprocess | Profile resolution, RFC connect, RIGHT-password decrypt |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | Step 9 | Artifact index for /sap-evidence-pack |

---

## Step 0 — Resolve Work Directory & OUT

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{RUN_TEMP}` via `Get-SapRunTemp`. `{OUT}` = `Get-SapArtifactDir -ScopeKey
CFG_<OBJECT> -Skill sap-config-compare` (manual scope key — the compared object is
a TABL/VIEW).

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_config_compare_run.json" -Skill sap-config-compare -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Positional `<OBJECT>` (table or view, uppercased). Required `--against <hint>` (a
/sap-login profile hint — `<SID>`, `<SID>/<CLIENT>`, description substring). Flags:
`--where "F=V,F2=A..B"` (F=V → EQ, F=A..B → BETWEEN, comma = AND), `--options "<raw
OPTIONS>"` (escape hatch; read-only predicate only — the engine refuses write
keywords), `--fields F1,F2` (restrict compared columns; keys always included),
`--keys-only` (diff key existence only; cap ×5), `--max-rows N` (default 10000,
ceiling 100000). `--client NNN` (cross-client sugar — resolves `<LEFT_SID>/NNN`) and
`preset <name>` are **v1.5/v2 (not implemented)** → say so and STOP.

## Step 2 — Extract Both Sides (RFC)

LEFT = pinned profile; RIGHT = `--against`. The engine self-connects LEFT and
resolves+connects RIGHT (DPAPI decrypt in-process). Identity per side is read LIVE
(RFC_SYSTEM_INFO → SID, USR02 MANDT → logon client) — the profile store can be stale.

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_config_compare_read.ps1" -Object "<OBJECT>" -Against "<hint>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutDir "{OUT}"
```

Add `-Where`, `-Options`, `-Fields`, `-KeysOnly`, `-MaxRows` as parsed. Parse:

```
IDENT: side=<L|R> sid=.. client=.. release=..
OBJECT: kind=<TABLE|VIEW_DB|VIEW_MAINT_BASE> read_target=<tbl> note="<..>"
FIELDS: keys=.. compared=.. excluded=.. only_left=.. only_right=..
READ: side=<L|R> rows=.. capped=<Y|N> groups=..
STATUS: OK | CFG_OBJECT_NOT_FOUND | CFG_NO_COMMON_KEY | CFG_UNBOUNDED_READ | CFG_SAME_IDENTITY | RFC_LOGON_FAILED | RFC_ERROR
```

**Refusals (fail loud, STOP, log the class):**
- `CFG_SAME_IDENTITY` — LEFT and RIGHT are the same SID+client. Nothing to compare.
- `CFG_OBJECT_NOT_FOUND object=.. side=<left|right|both>` — name which side(s) miss it.
- `CFG_NO_COMMON_KEY` — no shared key column (or a single-client-key table → v1.5).
- `CFG_UNBOUNDED_READ .. suggest_filter=<field>` — over `--max-rows` with no filter;
  re-run with `--where <field>=..` (echo the suggestion). Never a partial read.
- `RFC_LOGON_FAILED` (ambiguous/unknown `--against`, RIGHT unreachable, DPAPI) — STOP.

The engine writes `left.tsv`, `right.tsv`, `meta.json`, `texts.tsv` into `{OUT}`.
`kind=VIEW_MAINT_BASE` means a maintenance view was decomposed to its **primary base
table** (RFC_READ_TABLE cannot read a maintenance view) — the `note`/`scope_notes`
list the base tables NOT diffed; carry that caveat into the summary.

## Step 3 — Diff (offline)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_config_compare_diff.ps1" -LeftTsv "{OUT}\left.tsv" -RightTsv "{OUT}\right.tsv" -MetaJson "{OUT}\meta.json" -OutDir "{OUT}"
```

Parse `KEYED_DIFF:`, `DIFF: left_only=.. right_only=.. changed=.. identical=.. gaps=..`,
`VERDICT: IDENTICAL | DIFFERENT | IDENTICAL_WITH_GAPS | DIFFERENT_WITH_GAPS`. The
`_WITH_GAPS` verdict is set whenever a column was excluded (STRG/RSTR/too-wide),
present on one side only (release skew), a maintenance-view base table was not diffed,
or a row cap was hit — never rendered as a clean IDENTICAL.

## Step 4 — Summary (you narrate this)

Write `summary.md` into `{OUT}` from `diff.tsv` + `texts.tsv` + `meta.json`. **Grounding
rule: every stated delta traces to a diff.tsv row.** Sections:

1. **Header** — object + DD02T text, LEFT `SID/client (release)` vs RIGHT, the filter.
2. **Verdict** — IDENTICAL / DIFFERENT (+ `_WITH_GAPS`), with counts.
3. **Functional meaning of the deltas** — translate CHANGED rows using the DD04T field
   labels ("condition type PR00: calculation rule (KRECH) differs — C on RIGHT vs A on
   LEFT"); group LEFT_ONLY / RIGHT_ONLY rows ("12 condition types exist only on LEFT").
4. **Release skew** — from the two release markers + any `only_left/right_columns`.
5. **Coverage caveats** — name every excluded column, maintenance-view base table not
   diffed, and row cap. `diff.tsv` row_class is **LEFT_ONLY = pinned side, RIGHT_ONLY =
   --against side, CHANGED = same key, differing value**.

## Step 5 — Register & Log End

Register `diff.tsv` (kind `config-diff`, `-Rows`, Coverage from gaps, Verdict from
Step 3), `summary.md` (kind `summary`), `meta.json` (kind `config-meta`) via
`Register-SapArtifact` under scope `CFG_<OBJECT>`. Echo:

```
CONFIG_COMPARE: object=<o> left=<sid/cl> right=<sid/cl> left_only=<n> right_only=<n> changed=<n> verdict=<..>
```

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_config_compare_run.json" -Status SUCCESS -ExitCode 0
```

A refusal ends `-Status SKIPPED -ErrorClass <CFG_...>`; an infra failure `FAILED`
with `RFC_LOGON_FAILED` / `RFC_ERROR`.

---

## Scope & Limitations

- **v1 implemented:** one table / database-or-projection view / maintenance-view (→
  primary base table) diff across two profiles. `--where`, `--options`, `--fields`,
  `--keys-only`, `--max-rows`. Chunked offset-based read (robust against in-data
  delimiters), numeric normalization by DDIC DECIMALS (so `1.234,56` == `1,234.56`),
  MANDT dropped for client-dependent tables and kept for client-independent ones.
- **Honesty (tri-state):** STRG/RSTR + too-wide columns, one-sided columns, and
  maintenance-view base tables not diffed are listed in `meta.json` + summary and force
  a `*_WITH_GAPS` verdict — never a false IDENTICAL. An unbounded read is refused, never
  silently capped.
- **One diff engine:** the classification is `sap_keyed_diff_lib.ps1` (shared with
  /sap-se16n snapshot diff and /sap-compare `--table-content`); this skill only re-labels
  its ADDED/REMOVED as RIGHT_ONLY/LEFT_ONLY for cross-system clarity.
- **Single code path on ECC 6 and S/4HANA** — every run reads one release on LEFT and
  the other on RIGHT; the DDIC catalog layer (DD02L/DD25L/DD26S/DDIF_FIELDINFO_GET) is
  identical on both. Release differences surface only as data (structural drift).
- **Not yet:** `--client NNN` cross-client sugar and multi-base maintenance-view diff
  (v1.5); `preset <name>` functional-area bundles and `--both-ways-summary` (v2).
  Full DD28S maintenance-view selection-condition application (v1.5).
- **Residual risk:** WRITE-formatted DEC/CURR/QUAN output depends on the two RFC users'
  DCPFM; normalization by DECIMALS covers the common case, exotic formats may false-diff
  (documented in README).
- Verified live S/4HANA 1909 (S4D/100, rel 754) ↔ ECC 6 (ERP/800, rel 731) 2026-07-11:
  T000 (client-independent, DIFFERENT), T685 `--where KAPPL=V` (client-dependent 3-key,
  DIFFERENT_WITH_GAPS), V_T685A (maintenance view → base table + scope note), unbounded
  refusal, same-identity refusal, object-not-found.
