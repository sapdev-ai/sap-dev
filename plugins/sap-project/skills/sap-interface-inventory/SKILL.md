---
name: sap-interface-inventory
description: |
  Enumerates a SAP system's integration surface over pure read-only RFC and
  correlates it into a named interface register — the "list of all interfaces"
  every upgrade, S/4 migration, or system takeover needs and no SAP system has.
  scan reads six confirmable sources (RFC destinations RFCDES, IDoc/ALE partner
  profiles EDP13/EDP21/EDIFCT/TBD05, Z/Y RFC-enabled FMs via TFDIR, OData services
  via the Gateway hub catalog, ABAP proxies SPROXHDR, and interface-relevant batch
  jobs TBTCO/TBTCP) into per-source TSVs, then Claude clusters them into
  interface_register.tsv with a hard CONFIRMED-vs-INFERRED rule and a mandatory
  Gaps section. doc reverse-engineers one interface into a spec (IDoc segment tree
  via IDOCTYPE_READ_COMPLETE, RFC-FM signature via RPY_FUNCTIONMODULE_READ).
  Read-only — no writes, no GUI, no Z-object dependency. Release divergence
  (S/4-only OData hub, proxy framework) is handled by runtime existence probes,
  never a silently thinner register. Prerequisites: SAP profile via /sap-login
  (RFC); SAP NCo 3.1 (32-bit) in GAC.
argument-hint: "scan [--sources rfc,idoc,zfm,odata,proxy,jobs] [--max-rows N] [--namespace Z,Y] | doc <idoc MESTYP|rfcfm FMNAME|dest RFCDEST> [--format md|docx] | refresh"
---

# SAP Interface Inventory Skill

You enumerate a system's **interface surface** and correlate it into a register,
or reverse-engineer **one interface** into a spec. You are **read-only** — no
writes, no report execution, no GUI, no transports.

Task: $ARGUMENTS

The six source reads are deterministic (`references/sap_interface_scan.ps1`); the
**correlation into named interfaces is yours** (Claude), under a strict
CONFIRMED/INFERRED rule. Per-interface docs come from `references/sap_interface_doc.ps1`.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Read-only operating rules |
| `<SKILL_DIR>/references/sap_interface_scan.ps1` | `-Sources -MaxRows -Namespace -SharedDir -SkillDir [-OutputDir]` | Six-source RFC enumerator |
| `<SKILL_DIR>/references/sap_interface_doc.ps1` | `-Mode idoc\|rfcfm\|dest -Target <x> -SharedDir` | Per-interface spec extractor |
| `<SKILL_DIR>/references/interface_program_map.tsv` | read by the scanner | Batch-job program → technology/direction map (customer-overridable) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced | `Read-SapTableRows`, SID resolution |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | Scope key, artifact dir, `Register-SapArtifact` |
| `/sap-idoc` | sub-skill (soft) | doc-mode IDoc rendering / live example decode when installed |
| `/sap-explain-object` | sub-skill | `doc --deep` handler narration; docx render path |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_interface_inventory_run.json" -Skill sap-interface-inventory -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

Mode dispatch (all read-only, no confirm gates):

- **`scan`** — `--sources` (subset of `rfc,idoc,zfm,odata,proxy,jobs`, default all 6),
  `--max-rows` (default 5000/source), `--namespace` (default `Z,Y` for source 3),
  `--profile <name>` (cross-system inventory via the /sap-login second-profile pattern).
- **`doc`** — target token: `idoc <MESTYP|IDOCTYP>`, `rfcfm <FUNCNAME>`, or `dest <RFCDEST>`;
  `--format md|docx` (default md); `--deep` (chain /sap-explain-object `--spec` on the handler).
- **`refresh`** — v1.5; if requested, say it is not yet implemented and offer `scan`.

## Step 2 — RFC Preflight

A pinned RFC profile is required (`/sap-login`). The readers self-connect from the
pinned (or `--profile`) profile. Connect failure → exit 2, `RFC_LOGON_FAILED` — fail
loud, never present a partial register as complete. **No GUI session needed.**

---

## Step 3 (scan) — Run the Six-Source Enumerator

Run via **32-bit PowerShell**:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_interface_scan.ps1" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -SkillDir "<SKILL_DIR>"
```

Append `-Sources ...`, `-MaxRows N`, `-Namespace Z,Y`, `-CustomUrl "{custom_url}"` as
applicable. The scanner writes per-source TSVs into a system-scoped artifact dir
(`SID_<SID>_<CLIENT>`), registers each, and prints:

```
SRC: <source> rows=<n|">cap"> coverage=<CHECKED|COULD_NOT_CHECK|NOT_APPLICABLE> file=<tsv>
SCOPE_KEY: SID_<SID>_<CLIENT>   ARTIFACT_DIR: <dir>   STATUS: OK|PARTIAL|RFC_ERROR
```

**Immediately echo every `COULD_NOT_CHECK` / `NOT_APPLICABLE` source to the user** —
these become Gaps rows, not silent omissions. `rows=">N"` means the cap was hit (at
least N; raise `--max-rows` for exact). `RFC_ERROR` (exit 2) → stop, `RFC_LOGON_FAILED`.

## Step 4 (scan) — Correlate into the Register (you write this)

Read the per-source TSVs from `ARTIFACT_DIR` and cluster them into named logical
interfaces. Write `interface_register.tsv` with columns:

```
IFACE_ID · NAME · TECHNOLOGY(RFC|IDOC|ODATA|PROXY|HTTP|FILE) · DIRECTION(IN|OUT|BIDIR|UNKNOWN) ·
STATUS(CONFIRMED|INFERRED) · PARTNER_OR_DEST · MESSAGE_OR_SERVICE · HANDLER · JOBNAME ·
EVIDENCE(source:key;…) · NOTE
```

**Hard rule — CONFIRMED vs INFERRED:** a row is **CONFIRMED** only when a direct
config chain links its evidence (e.g. an `EDP21` inbound row + its `EDIFCT` handler;
an `RFCDES` destination row). Any name-similarity or job-heuristic link stays
**INFERRED**. Never upgrade past INFERRED without a config chain. Fill `EVIDENCE`
with the concrete source rows (e.g. `we20:LS/INVOIC;edifct:INVOIC->IDOC_INPUT_INVOIC`).

Then write `interface_register.md`: the register grouped by technology, plus a
**mandatory Gaps section** listing (a) every COULD_NOT_CHECK / NOT_APPLICABLE source
of this run and (b) the v2-deferred sources not scanned (Z-source `CALL FUNCTION …
DESTINATION` scan, SOAMANAGER runtime config). The register never pretends coverage
it does not have.

## Step 5 (scan) — Register + Summarize

Register the correlated outputs (the per-source TSVs were already registered by the
scanner):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-interface-inventory' -ScopeKey '<SCOPE_KEY>' -ScopeKind 'SYSTEM' -Kind 'interface_register' -Format 'tsv' -Path '<ARTIFACT_DIR>\interface_register.tsv' -Coverage '<CHECKED_CLEAN|COULD_NOT_CHECK>' -System '<SID>' -Client '<CLIENT>'"
```

Use `COULD_NOT_CHECK` coverage whenever any source was COULD_NOT_CHECK/NOT_APPLICABLE.
Print a summary table: counts per technology + direction, and coverage per source.

---

## Step 3D (doc) — Resolve the Target

- A register `IFACE_ID` → look up its row via `Find-SapArtifacts -Kind interface_register`
  (newest) and map to an `idoc`/`rfcfm`/`dest` token.
- A direct token (`idoc <MESTYP>` / `rfcfm <FM>` / `dest <RFCDEST>`) → use as-is.
- **Refuse** OData / proxy targets in v1 (spec flavor is v2) — the register row remains
  the evidence.

## Step 4D (doc) — Extract + Render

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_interface_doc.ps1" -Mode idoc -Target INVOIC01 -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Reads `DOC:` + `JSON:` + `STATUS: OK|NOT_FOUND|RFC_ERROR`. The JSON holds the raw
segment tree (`PT_SEGMENTS` with parent `PARSEG`, `MUSTFL`, `OCCMIN/OCCMAX`, `HLEVEL`)
+ fields (idoc), or the FM signature tables (rfcfm). Then **you** render a Markdown
spec, marking each section CONFIRMED (read live) vs INFERRED (your narration):

- **IDoc**: message type, basic/extension type, the segment hierarchy, per-segment
  fields with DDIC texts, partner/port config from the scan's `source_we20.tsv`, and
  the handler FM. When `/sap-idoc` is installed, delegate segment rendering + a live
  example decode to it; otherwise the JSON above is the dependency-free fallback.
- **RFC-FM**: signature (import/export/changing/tables params) with DDIC texts and the
  short text; `--deep` → `/sap-explain-object <FM> --spec` for handler narration.

`--format docx` → render via the `docx` skill (best-effort). Register the spec:
`Register-SapArtifact … -Kind interface_spec -Format md|docx`.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_interface_inventory_run.json" -Status SUCCESS -ExitCode 0
```

Connect failure → `-Status FAILED -ErrorClass RFC_LOGON_FAILED`; every requested
source unavailable → `-Status FAILED -ErrorClass IFACE_SOURCE_UNAVAILABLE`.

---

## Scope & Limitations (v1)

- **v1 implemented:** `scan` (all 6 sources) + `doc` (IDoc + RFC-FM flavors, docx).
- **Phase 2 (not yet):** `refresh` NEW/GONE/CHANGED delta (v1.5); Z-source
  `CALL FUNCTION … DESTINATION` scan via RS_ABAP_SOURCE_SCAN (confirm-gated report,
  /sap-run-report); SOAMANAGER runtime reconstruction; OData/proxy `doc` flavors.
- **Correlation is heuristic by design** — mitigated by the hard CONFIRMED/INFERRED
  rule, the EVIDENCE column, and keeping every raw source TSV beside the register.
- **Honest coverage:** a missing source table (e.g. `/IWFND/I_MED_SRH` on ECC →
  Gateway not installed; `SPROXHDR` on a proxy-less release) becomes a
  NOT_APPLICABLE / COULD_NOT_CHECK row + a Gaps entry, never a thinner register.
  `rows=">N"` is honest ("at least N") — RFC_READ_TABLE cannot aggregate.
- **Data sensitivity:** the `RFCOPTIONS` parser masks credential-shaped tokens before
  anything reaches the TSV/logs. RFCDES read authority is often restricted — a denied
  table surfaces as COULD_NOT_CHECK with the auth object named.
- **Read-only.** No writes, no report execution, no GUI, no transports in any v1 mode.
