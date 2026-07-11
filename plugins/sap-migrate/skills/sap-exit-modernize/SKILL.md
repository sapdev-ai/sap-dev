---
name: sap-exit-modernize
description: |
  Accelerates the canonical clean-core chore of replacing a classic CMOD function exit with a BAdI
  implementation — a human-in-the-loop pipeline (analyze -> translate -> deploy -> verify) that does
  the tedious reads and the genuinely hard AI translation while NEVER auto-deactivating the old CMOD
  project. analyze (RFC, read-only) resolves the exit's identity (MODSAP/MODACT/MODATTR/ENLFDIR),
  reads its source + ZX include, checks whether a containing CMOD project is active, gets ranked
  replacement targets from /sap-enhancement-advisor, and owns the NO_SAFE_TARGET verdict (only
  implicit points / standard-mod left -> refuse to translate). translate AI-maps the exit signature
  to the chosen BAdI method with load-bearing MANUAL markers (an offline classifier flags TABLES /
  COMMON PART globals, SY-* writes, direct standard-table DB writes, MESSAGE...RAISING, PERFORM into
  the standard program, COMMIT WORK — each becomes a commented TODO(MANUAL-n) block) and syntax-checks
  the class with ZERO writes. deploy is confirm-gated (typed confirm when markers exist) and delegates
  ALL writes to /sap-se24 + /sap-se19, with an authoritative BADI_IMPL/SXC_EXIT re-read. verify runs a
  characterization test via /sap-gen-abap-unit (honest UNVERIFIED where logic isn't extractable),
  optional /sap-atc, an evidence-pack dossier, and ends by PRINTING (never running) the
  /sap-cmod deactivate proposal. One exit at a time. No new Z objects. Prerequisites: pinned RFC
  profile via /sap-login; NCo 3.1 (32-bit); a GUI session only for deploy/verify.
argument-hint: "<EXIT_FM> | analyze <EXIT_FM> | translate <EXIT_FM> [--target <BADI>] [--class ZCL_...] | deploy <EXIT_FM> | verify <EXIT_FM> [--skip-unit] [--with-atc]"
---

# SAP Exit-Modernize Skill

You accelerate one function-exit -> BAdI conversion as a gated pipeline: read the exit, translate it
to a BAdI class with honest MANUAL markers, deploy through the workbench skills behind a confirm gate,
and verify equivalence. You NEVER deactivate the old CMOD project — you only print the proposal.

Task: $ARGUMENTS

The exit read + marker classification are scripts; **you** do the exit->BAdI translation (with MANUAL
blocks) and the equivalence narrative.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_exit_read.ps1` | `-Exit <FM>` | analyze RFC reader (identity + source + active check) |
| `<SKILL_DIR>/references/sap_exit_markers.ps1` | `-SourceFile -OutFile` | offline MANUAL-marker classifier |
| `<SKILL_DIR>/references/sap_exit_markers.tests.ps1` | offline | 10-assertion marker corpus |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_syntax_check.ps1` | `-Subc K -Wrap` | zero-write class syntax check |
| `/sap-enhancement-advisor` | sub-skill | ranked BAdI targets (SMOD then PROGRAM mode) |
| `/sap-se24` · `/sap-se19` | sub-skills | class + BAdI-impl deploy (TRs resolved downstream) |
| `/sap-gen-abap-unit` · `/sap-atc` · `/sap-evidence-pack` | sub-skills | verify + dossier |
| `/sap-cmod` | sub-skill | the PRINTED deactivate proposal (user-run, never auto) |

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` + `{RUN_TEMP}`; per-exit stage-persistent folder
`{work_dir}\exit_modernize\<EXIT_FM>\` (so analyze-today + deploy-tomorrow works).

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_exit_modernize_run.json" -Skill sap-exit-modernize -ParamsJson "{}"
```

## Step 1 — Parse Arguments

Modes: full pipeline (default) | `analyze` | `translate` | `deploy` | `verify`. A non-function-exit
component (screen `S`, table `C_*`, menu) -> refuse `EXIT_SCOPE_UNSUPPORTED` (v2). Normalize input to
the `EXIT_*` FM.

## Step 2 — analyze

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_exit_read.ps1" -Exit <EXIT_FM> -OutDir "{WORKDIR}\exit_modernize\<EXIT_FM>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

Parse `EXIT:` (fm/enh/fg/projects/active/zxinclude/zxstatus) + `SRC:` lines. `EXIT_RESOLVE_FAILED`
-> stop. Then delegate `/sap-enhancement-advisor` (SMOD mode on the enhancement; PROGRAM mode on the
calling program if SMOD yields no BAdI). **NO_SAFE_TARGET rule (this skill owns it):** if no candidate
is a released enhancement interface / new BAdI / classic BAdI, the verdict is `EXIT_NO_SAFE_TARGET` and
translate/deploy refuse. Write `exit_analysis.md` + copy the advisor `candidates.tsv`. STOP here in
`analyze` mode. (`active=COULD_NOT_CHECK` when the project status can't be read — never silently active.)

## Step 3 — translate

Run the marker classifier on the ZX include source:

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_exit_markers.ps1" -SourceFile "{WORKDIR}\exit_modernize\<EXIT_FM>\exit_source\<zxinclude>.abap" -OutFile "{WORKDIR}\exit_modernize\<EXIT_FM>\manual_markers.tsv"
```

Then **you** translate: map the exit signature (from the FM source interface) to the chosen BAdI
method; every data flow with a marker (or otherwise no BAdI counterpart) becomes a
`" TODO(MANUAL-<n>)` block preserving the original statements as comments. Emit
`translation\ZCL_<...>.abap`, `mapping.tsv`, `before_after.diff`. Syntax-check with ZERO writes:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_syntax_check.ps1" -SourceFile "...\ZCL_<...>.abap" -ProgramName "ZCL_<...>" -Subc K -Wrap
```

A signature too complex to model -> `COULD_NOT_CHECK`, never a false-fail. STOP in `translate` mode.
Refuse if the analyze verdict was `EXIT_NO_SAFE_TARGET` (`EXIT_TRANSLATE_BLOCKED`).

## Step 4 — deploy (confirm-gated; all writes delegated)

Show the before/after diff, target BAdI, and MANUAL marker count. **Gate:** marker_count=0 -> a normal
yes/no; **marker_count>0 -> TYPED confirmation** `DEPLOY <class>` acknowledging "`<n>` MANUAL sections
ship commented-out / inert". Then `/sap-se24 <class>` + `/sap-se19 create <BADI_DEF|SPOT>` (they resolve
the TR via /sap-transport-request). Authoritative re-read: `BADI_IMPL` / `ENHHEADER` (new) or `SXC_EXIT`
(classic) to confirm the implementation row exists. No answer / wrong typed phrase -> log `SKIPPED`.

## Step 5 — verify

`/sap-gen-abap-unit <class> --type class` for the characterization test where logic is extractable;
where the seam is untestable-without-refactor, the equivalence verdict is **UNVERIFIED** (never
rendered passed). Optional `/sap-atc CLASS <class>`. Register artifacts + `/sap-evidence-pack CLASS
<class>`. **Always** end by PRINTING (never running): "old CMOD project `<P>` remains ACTIVE — after
human sign-off run `/sap-cmod deactivate <P>`".

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_exit_modernize_run.json" -Status SUCCESS -ExitCode 0
```

Classes: `EXIT_RESOLVE_FAILED`, `EXIT_NO_SAFE_TARGET`, `EXIT_TRANSLATE_BLOCKED`,
`EXIT_SCOPE_UNSUPPORTED`, `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **v1 implemented:** analyze (RFC identity + source + active check + advisor targets + NO_SAFE_TARGET),
  translate (AI + offline MANUAL markers + zero-write syntax check), deploy (gated, delegated), verify
  (delegated unit/ATC/dossier + printed deactivate proposal). One exit at a time.
- **Live-verified on S4D (S/4HANA 1909):** analyze on `EXIT_SAPMV45A_920` resolved enhancement
  `OIKICL01`, function group `XOIK`, parsed the ZX customer include name `ZXOIKU55` from the FM source,
  reported it `EMPTY_OR_MISSING` (no customer implementation) and `active=NO` (in no active CMOD
  project) — the full MODSAP->MODACT->MODATTR->ENLFDIR + RPY source chain. The marker classifier passes
  a **10-assertion offline corpus**: each of the 6 marker kinds fires once, a comment mentioning
  `UPDATE VBAK` does NOT fire (comments stripped), and `MODIFY zcust_tab` (Z table) is NOT flagged while
  `UPDATE vbak` (standard table) IS — the Z-namespace allow is load-bearing.
- **Honesty invariants:** `active=COULD_NOT_CHECK` when project status is unreadable (never silently
  active); translate/deploy refuse after NO_SAFE_TARGET; equivalence defaults to UNVERIFIED unless a
  characterization test passes; every MANUAL marker is a finding, never dropped.
- **Deliberately NOT run autonomously:** deploy (SAP writes via /sap-se24 + /sap-se19) and verify (test
  deploy) are confirm-gated and delegated — this session verified the read + marker + syntax-check
  paths, not a live class deploy. The old CMOD project is NEVER auto-deactivated (only the proposal is
  printed).
- **Deferred:** `MODX_FUNCTION_ACTIVE_CHECK` precise per-exit active check via the wrapper (v1.5 — its
  exception result collapses through the wrapper's single OTHERS handler, so v1 uses the reliable
  MODATTR project-status signal); ZX-include-as-input resolution (v1.5); batch `--project` analyze
  (v1.5); screen/table/menu exits (v2). ECC 6 shares the identical read path (all 19 objects probed
  identical); divergence is advisor ranking content (classic vs new BAdI), not tables. EC2 was
  unavailable this session for the ECC re-confirm.
