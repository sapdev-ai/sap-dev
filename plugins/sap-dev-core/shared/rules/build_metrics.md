# Build metrics — first-pass-yield KPIs for generated ABAP

**Status:** schema `sapdev.buildkpi/1` (P0/P1). Read by `sap_build_kpi.ps1`
(the offline aggregator) and surfaced via `/sap-log-analyze --builds`.

This is the contract for measuring **how often generated ABAP clears each
quality gate on the first attempt**, and trending that over time. It is the
yardstick the rest of the quality work is judged against: without it, "did
that prompt change / new KB row / model bump help?" is unanswerable.

The cardinal design rule: **derive, do not instrument.** The KPI ledger is a
*derived* artifact computed after the fact from data the pipeline already
writes to disk. There is **no new per-build write path**, and in particular
**no instrumentation added to `agents/abap-developer.md`**. Doc-instructed
side effects in this repo have silently failed more than once (the 2026-05-11
zero-logging build; the sap-explain-object / sap-compare param drift; the
ZMMRMAT042R01 dropped test file), and the runs a KPI ledger most needs —
STOPs and partial builds — are exactly the ones a "final step: append a row"
instruction skips. So the ledger is reconstructed from two reliable
chokepoints that already fire on every gate:

1. **Structured logs** (`{log_dir}\sap-dev-*.log`, JSONL) — every gate skill
   already emits a `start` and an `end` record through its wired
   `Step 0.5 — Start Logging` / `Final — Log End` blocks (Rule 4). A `start`
   with no matching `end` is itself the signal for an aborted build, so
   STOP/ABANDONED runs are captured for free instead of being censored.
2. **The artifact index** (`{artifact_dir}\index.jsonl`, `sapdev.artifact/1`)
   — where the delivery-assurance skills register the files they write, with
   `coverage` / `verdict` metadata.

Where a KPI needs a number the bare log lacks (ATC P1/P2/P3 counts, ABAP Unit
coverage), that number is added as **extra fields on the gate skill's existing
end record** — a one-line `-MetricsJson` argument inside the skill's own
`Final — Log End` block, not a new call and not an agent-level instruction.
`Stop-SapLog -Extra` already merges arbitrary keys into the JSONL end record;
the helper just passes them through. See "Gate enrichment contract" below.

---

## 1. The derived row — `sapdev.buildkpi/1`

The aggregator writes one JSONL row per reconstructed build to
`{work_dir}\metrics\build_kpi.jsonl`. Schema:

```json
{
  "schema": "sapdev.buildkpi/1",
  "build_id": "20260613_142530_ZMMRMAT058R01",
  "ts_start": "2026-06-13T14:25:30.123+02:00",
  "ts_end":   "2026-06-13T14:51:07.456+02:00",
  "mode": "build",                      // build | fix | deploy | unknown
  "object": "ZMMRMAT058R01",
  "spec_family": "MATUPLOAD",           // suffix-normalised; see §4
  "spec_lang": "CN",                    // EN | JA | CN | ZH | unknown
  "system_id": "s4d_100",               // <SID>_<client>, lowercased (§4)
  "sap_release": "1909",                // best-effort; '' when unknown
  "atc_variant": "DEFAULT",             // DEFAULT | S4HANA_READINESS | ...
  "plugin_version": "0.6.3",            // the RUNNING cache version (§4)
  "outcome": "SUCCESS",                 // SUCCESS | PARTIAL | FAILED | ABORTED
  "gates": {
    "GEN":      { "verdict": "PASS", "attempt": 1, "test_file": "EMITTED", "methods": 4, "hints_injected": 7 },
    "SPEC":     { "verdict": "PASS", "ddic_errors": 0, "process_errors": 0 },
    "CHECK":    { "verdict": "PASS", "attempt": 1, "iterations": 1, "errors": 0, "warnings": 2 },
    "SYNTAX":   { "verdict": "PASS", "syntax_errors": 0 },
    "ACTIVATE": { "verdict": "PASS", "activated": true },
    "TEXT":     { "verdict": "PASS", "applied": true },
    "ATC":      { "verdict": "PASS", "attempt": 1, "p1": 0, "p2": 0, "p3": 0 },
    "AUNIT":    { "verdict": "PASS", "methods": 4, "passed": 4, "failed": 0, "coverage": 78 }
  },
  "incomplete": false                   // true when the build had no terminal
                                        // end record (orphaned start = ABORTED)
}
```

Every gate is **optional**. A gate that did not run for this build (e.g. `TEXT`
for a non-report, `AUNIT` when `MODE_UNIT_TESTS=OFF`) is simply absent — it is
never rendered as a failure. A gate that ran but whose enrichment fields were
not emitted carries only `verdict` (derived from the log `status`); its numeric
sub-fields are absent and roll up to `n/a`, never `0`.

### Gate keys

| Gate | Produced by | `verdict` source | Enrichment fields |
|---|---|---|---|
| `GEN` | `sap-gen-abap` | TEST_FILE marker / end status | `test_file`, `methods`, `hints_injected` |
| `SPEC` | `sap-docs-check-ddic` + `-process` | end status | `ddic_errors`, `process_errors` |
| `CHECK` | `sap-check-abap` (+`-fm`) | end status | `iterations`, `errors`, `warnings` |
| `SYNTAX` | `sap-se38/37/24` | `SYNTAX_ERRORS:` marker | `syntax_errors` |
| `ACTIVATE` | `sap-se38/37/24` | activation verify | `activated` |
| `TEXT` | `sap-se38` | `TEXT_ELEMENTS:` marker | `applied` |
| `ATC` | `sap-atc` | `GATE_VERDICT:` line | `p1`, `p2`, `p3` |
| `AUNIT` | `sap-run-abap-unit` | `AUNIT_VERDICT:` line | `methods`, `passed`, `failed`, `coverage` |

`attempt` is **derived** by the aggregator (the Nth time that gate's skill ran
within the build cluster), not a logged field.

The deploy skills (`sap-se38/37/24`) emit a **single** end record per deploy and
therefore a **single** `-MetricsJson` payload with `gate:"DEPLOY"` carrying
`{syntax_errors, activated, text_elements}`. The aggregator fans that one
payload out into the `SYNTAX`, `ACTIVATE`, and `TEXT` build gates (verdict of
each derived from the corresponding field: `syntax_errors==0`, `activated`,
`text_elements=="APPLIED"`). `text_elements` is absent for FMs/classes and for
non-report programs, so the `TEXT` gate is simply not created for those builds.

---

## 2. KPI definitions

All KPIs follow the `sap-cc-campaign` honesty convention: an integer percentage,
or **`-1` meaning "not applicable / not yet measured"**, rendered as `n/a`
(never `0%`) in the dashboard. A KPI is `-1` whenever its denominator is zero
(no build produced the gate it measures).

| KPI | Definition |
|---|---|
| `builds_total` | count of reconstructed builds in scope |
| `gen_first_pass_pct` | builds where `CHECK.attempt==1 AND CHECK.errors==0` AND (`GEN.test_file==EMITTED` when unit tests were mandated) ÷ builds |
| `fix_iters_avg` | mean of `CHECK.iterations` across builds that ran CHECK (×100, integer) |
| `syntax_first_pass_pct` | builds with `SYNTAX.syntax_errors==0` on first deploy ÷ builds that deployed |
| `activation_first_pass_pct` | builds with `ACTIVATE.activated==true` first try ÷ builds that deployed |
| `text_elements_applied_pct` | report builds with `TEXT.applied==true` ÷ report builds that emitted text elements |
| `atc_first_pass_pct` | builds with `ATC.attempt==1 AND p1==0 AND p2==0` ÷ builds that ran ATC |
| `atc_p1_first_run_avg` / `_p2_` / `_p3_` | mean first-run priority counts (×100, integer) |
| `aunit_first_pass_pct` | builds with `AUNIT.failed==0` first run ÷ builds that ran ABAP Unit |
| `aunit_coverage_avg` | mean `AUNIT.coverage` across builds that measured it |
| `e2e_success_pct` | builds with `outcome==SUCCESS` ÷ builds_total |
| `hints_injected_avg` | mean `GEN.hints_injected` (×100, integer) — correlates KB growth with yield |

`*_avg` KPIs are emitted ×100 as integers so they share the single integer
`METRIC:` grammar (e.g. `fix_iters_avg = 130` → 1.30 iterations).

### Grouping

KPIs are reported three ways, because a single blended number hides drift:

* **by ISO week** (`ts_start`) — the trend line;
* **by `spec_family`** — which specs the generator is good/bad at;
* **by `(system_id, atc_variant)`** — ATC counts from S4D-1909-DEFAULT are
  **not comparable** to a 2022 system or a readiness variant; never blend them.

---

## 3. METRIC grammar (stable — mirrors `sap_cc_campaign.ps1`)

The aggregator emits these lines to stdout. The grammar is shared with the
migration dashboard so `/sap-log-analyze` and any downstream parser read one
convention:

```
BUILD:   <build_id> | OUTCOME: <SUCCESS|PARTIAL|FAILED|ABORTED>   (report only)
GROUP:   <dimension>=<value> | BUILDS: <n>                        (report only)
METRIC:  <name> | VALUE: <int>          (-1 = n/a)
         [optional]  GROUP: <dimension>=<value>
```

`VALUE` is always an integer (a percentage, a ×100 average, or a raw count).
`-1` is the only sentinel and always renders as `n/a`. There is no second
sentinel and no floating-point in the grammar.

The dashboard is written to `{work_dir}\metrics\dashboard.md` (UTF-8, no BOM),
structured like the migration dashboard: a header band, the headline KPI table,
a by-week trend table, a by-spec-family table, and a per-(system,variant) table.

---

## 4. Dimension stamping (do this before the first row)

Without these, a KPI trend is unattributable — the MaterialUpload series alone
spans EN/JA/CN specs, suffix-bumped object families, and more than one system.

* **`plugin_version`** — stamp the **running cache version**, read at execution
  time from the plugin manifest that is actually loaded, NOT the repo version.
  In the live-dev loop the repo is edited while builds run from the marketplace
  cache; the two diverge, and a repo-version stamp would mis-attribute results.
  The helper reads it from the `plugin.json` two levels up from
  `shared/scripts/`. Absent → `''` (rendered `unknown`).
* **`spec_family`** — normalise away the numeric suffix bump so `ZMMRMAT036R01`,
  `…050R01`, `…058R01` roll up to one family. Rule: strip a trailing run of
  digits before the final `R<nn>`/`_TEST`/version token; the aggregator applies
  a configurable regex (default: collapse `\d{2,}` runs in the object stem). A
  build's family also comes from the spec file name when available.
* **`system_id`** — `<SID>_<client>`, lowercased. Stamped into every start
  record by `sap_log_helper.ps1` (reusing the connection banner's cached
  profile — no extra lookup), so it is present whenever a connection is pinned.
  Absent → `unknown`.
* **`sap_release`** / **`atc_variant`** — best-effort from the ATC enrichment
  and connection banner; absent → `''` / `DEFAULT`.
* **`mode`** — build / fix / deploy, from which gate skills appear in the
  cluster (a fix-mode build has no `GEN`).

Redaction reuses `log_redact_keys` (the aggregator never re-derives secrets; it
only reads already-redacted log records, and never copies `params` verbatim
into a KPI row — only the whitelisted dimension fields above).

---

## 5. Build reconstruction (how the aggregator clusters runs)

The aggregator does **not** rely on a build id being logged. It reconstructs a
build cluster from the run-id forest:

1. Group `end` (and orphaned `start`) records by **root run** — walk
   `parent_run_id` to the run whose parent is empty; all descendants are one
   logical invocation tree.
2. Within a root, the **object** is taken from the deepest gate skills' start
   `params` (`object_name`) — these agree across a build.
3. A root with no terminal `end` for its top run, or whose top run ended
   non-SUCCESS, yields an `incomplete` / non-SUCCESS build row — it is **kept**,
   not dropped. Optimistic bias (only counting builds that reached Step 5) is
   the failure mode this explicitly avoids.
4. If the agent exported `SAPDEV_BUILD_ID` (optional, best-effort), the
   aggregator uses it to label and disambiguate clusters; when absent it falls
   back to `<ts_start>_<object>`. The build id is never *required*.

`stale_state==true` end records (the >12h orphan-eviction demotions from
`Stop-SapLog`) are excluded from duration and first-pass math — their
`duration_ms` is a hang interval, not work.

---

## 6. Gate enrichment contract (the one-line skill change)

Each gate skill's existing `## Final — Log End` block gains a `-MetricsJson`
argument carrying its verdict payload as a compact JSON object. Example, for
`sap-atc` on a passing gate:

```bash
powershell ... sap_log_helper.ps1 -Action end -StateFile "...\sap_atc_run.json" \
  -Status SUCCESS -ExitCode 0 \
  -MetricsJson '{"gate":"ATC","verdict":"PASS","p1":0,"p2":0,"p3":0}'
```

The helper parses `-MetricsJson` to a hashtable and passes it to
`Stop-SapLog -Extra`, which merges the keys into the JSONL end record. The
aggregator keys on the `gate` field to slot the payload into the right gate of
the build row. Rules:

* `gate` is mandatory in the JSON; it is the only required key.
* `verdict` ∈ `PASS | FAIL | WARN | SKIPPED`; if omitted the aggregator derives
  it from the log `status`.
* Numeric fields are optional; absent → the KPI that needs them is `n/a` for
  that build, never `0`.
* Best-effort: a malformed or absent `-MetricsJson` never changes the gate's
  own verdict or the skill's exit code. The build row simply carries less
  detail.

This is enforced statically: `scripts/check-consistency.mjs` warns when a
gate skill's `Final — Log End` block lacks a `-MetricsJson` argument
(ratcheting, mirroring the screen-baseline gate). The presence of the block
itself is already guaranteed by Rule 4.

---

## 7. What this is NOT

* Not a logic-correctness check. A build can be `SUCCESS` here and still have
  generated subtly wrong ABAP — the KPI says it cleared the *gates*, not that
  it implements the spec. Logic fidelity is the regression suite's job
  (contract lint + traceability-skeleton diff + live ABAP Unit), tracked
  separately.
* Not a live-system probe. The aggregator is pure offline file math; it asserts
  nothing about the SAP system, only about what the gates reported.
* Not authoritative across systems. Always read KPIs within a
  `(system_id, atc_variant)` group, never blended.
