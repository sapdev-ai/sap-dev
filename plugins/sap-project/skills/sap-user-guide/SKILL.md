---
name: sap-user-guide
description: |
  Turns a recorded transaction walkthrough into an end-user training guide + UAT script — the
  unfunded rollout mandate everyone hand-makes from screenshots pasted into Word — composed from
  ground truth the suite already owns: /sap-gui-probe drives/records the transaction step by step
  with full screen identity, DDIC carries the authoritative field labels and F1 documentation, and
  the docx skill renders Word. guide harvests a /sap-gui-probe run folder into a business-language
  step-by-step guide (Markdown + docx, per-step screenshots with --with-screens, field tables with
  DDIC labels + F1 long text), in any target language; pack batches guides into a curriculum with
  exercises and test-data prerequisites (mapped to /sap-bp//sap-mm01//sap-va01 as SUGGESTIONS). The
  same assets double as a UAT script (--uat: per-step expected result + sign-off columns). Read-only
  except --with-screens, which REPLAYS the recorded actions on the live GUI to capture screenshots
  and is confirm-gated with every write action enumerated; a replay whose live screen diverges from
  the recording stops REPLAY_DIVERGED (never a wrong-screen action). All DDIC text is over RFC
  (TSTCT/DDIF_FIELDINFO_GET/DOCU_GET — no RFC_READ_TABLE on DOKTL which is CLUSTER on ECC6). No new Z
  objects. Prerequisites: a /sap-gui-probe run folder (or a scenario to drive); /sap-login session for
  --with-screens; NCo 3.1 (32-bit).
argument-hint: "guide <probe-run-folder | \"TXN: scenario\"> [--with-screens] [--lang EN|JA|ZH] [--docx] [--uat] [--no-writes] [--output <dir>] | pack <pack.tsv> [--lang ..] [--docx]"
---

# SAP User-Guide Skill

You compose an end-user guide (and UAT script) from a recorded walkthrough: harvest the probe folder,
resolve DDIC labels + F1 docs over RFC, optionally replay to capture screenshots (confirm-gated —
replay executes the transaction), and write business-language step prose over the assembled skeleton.

Task: $ARGUMENTS

The harvest, DDIC texts, and skeleton are scripts; **you** write the business-language step text and
narrate; the interpreter replays one action at a time.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_guide_compose.ps1` | `-Action harvest\|compose` | Parse probe folder + assemble guide skeleton (local) |
| `<SKILL_DIR>/references/sap_guide_ddic_texts.ps1` | `-Tcode -Fields` | DDIC labels + F1 docs over RFC |
| `<SKILL_DIR>/references/sap_guide_replay.vbs` | via 32-bit cscript | Single-action replay + screen-identity verify (GUI) |
| `<SKILL_DIR>/references/sap_guide_replay.screens.json` | baseline | Golden-screen baseline (generic deps only) |
| `/sap-gui-probe` · `/sap-gui-inspect` | sub-skills | fresh capture / screenshot per step |
| `docx` | sub-skill | `--docx` rendering |
| `/sap-login` | sub-skill | Session (only for `--with-screens`) |

---

## Step 0 — Resolve Work Directory + Logging

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Then `sap_log_helper.ps1 -Action start -StateFile {RUN_TEMP}\sap_user_guide_run.json`.

`{OUT}` = `Get-SapArtifactDir -ScopeKey TCODE_<TXN> -Skill sap-user-guide` (from
`sap_artifact_lib.ps1`; creates the dir) — the artifact output dir Steps 3–6 write to and
Step 7 registers.

## Step 1 — Parse Args + Resolve Input

`guide` | `pack`. A `guide <folder>`: validate it has `sap_gui_probe_run.json` + >=1
`step_NN_action.json` (else `GUIDE_INPUT_INVALID`). A `guide "TXN: scenario"` with no folder ->
delegate `/sap-gui-probe drive` first (its gates apply), then compose from the fresh folder.

## Step 2.5 — CONFIRM gate (only `--with-screens`)

Replay EXECUTES the transaction. Classify every recorded action READ/WRITE (verb + VKeys 11/14/27/28/33,
same classifier as /sap-gui-probe); present tcode, step count, and the explicit **write-action list**
for `<SID>/<CLIENT>`; proceed only on `yes` (typed `<SID>` on a non-DEV/production-grade client).
`--no-writes` truncates before the first write instead of gating.

## Step 3 — Harvest

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_guide_compose.ps1" -Action harvest -RunFolder "<folder>" -OutDir "{OUT}"
```

-> `steps.tsv` + `fields_request.tsv` (the (table,field) tokens from the findById paths).

## Step 4 — DDIC texts

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_guide_ddic_texts.ps1" -Tcode <TXN> -FieldsFile "{OUT}\fields_request.tsv" -Lang <L> -OutDir "{OUT}" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

-> `guide_meta.tsv` (tcode title/program/dynpro) + `guide_fields.tsv` (label, rollname, F1 doc excerpt;
a field whose text can't be fetched is `COULD_NOT_CHECK`, never dropped). The wrapper-based full-dynpro
enrichment (RPY_DYNPRO_READ) is v1.5 and SKIPs when the wrapper is absent.

## Step 5 — Replay + capture (only `--with-screens`)

Per step: run `sap_guide_replay.vbs` (32-bit cscript, `%%SESSION_PATH%%`/`%%ATTACH_LIB_VBS%%`/
`%%RUN_FOLDER%%`/`%%STEP_INDEX%%` substituted) — it does ONE action then verifies live vs recorded
(program,dynpro); `REPLAY_DIVERGED` -> stop, keep partial captures, honesty note. On PASS, delegate
`/sap-gui-inspect screenshot topmost` -> `{OUT}\screenshots\step_NN.png`. `/n` cleanup at the end.

## Step 6 — Compose

```bash
powershell -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_guide_compose.ps1" -Action compose -Tcode <TXN> -Lang <L> -FieldsTsv "{OUT}\guide_fields.tsv" -ScreensDir "{OUT}\screenshots" [-Uat] -OutDir "{OUT}"
```

Then **you** write the business-language step prose (the `TODO` lines) from the recorded notes + screen
identities + field labels. `--docx` -> hand `guide_<TXN>_<LANG>.md` to the `docx` skill. `pack` iterates
`pack.tsv` rows through `guide` then composes `curriculum.md` (TOC, exercises, test-data prerequisite
SUGGESTIONS -> /sap-bp//sap-mm01//sap-va01).

## Step 7 — Register + Summarize

Register `guide` / `uat_script` / `curriculum` artifacts (coverage CHECKED when all touched fields
resolved, COULD_NOT_CHECK otherwise). Print steps, fields resolved/COULD_NOT_CHECK, screenshots, paths.

## Final — Log End

`sap_log_helper.ps1 -Action end` with status + error_class: `GUIDE_INPUT_INVALID`, `REPLAY_DIVERGED`,
`NO_SESSION`, `RFC_LOGON_FAILED`, `USER_ABORTED`.

---

## Scope & Limitations (v1)

- **v1 implemented:** `guide` (harvest -> DDIC texts -> optional replay+screens -> compose, md/docx,
  `--uat`, `--no-writes`, `--lang`), `pack` (curriculum + test-data suggestions).
- **Live-verified on S4D (S/4HANA 1909):** the DDIC-text engine resolved **VA01 title 'Create Sales
  Orders'** (SAPMV45A/0101) + field labels (VBAK-VBELN 'Sales document', MARA-MATNR 'Material',
  VBAK-AUART 'Sales Document Type') and real **F1 long docs via DOCU_GET** (MATNR: "Alphanumeric key
  uniquely identifying the material.") — the CLUSTER-safe path (no RFC_READ_TABLE on DOKTL). The
  harvest parsed a probe-folder fixture (2 steps, extracted MARA-MATNR + VBAK-AUART from the findById
  paths) and compose produced the guide skeleton with the resolved labels inlined + a UAT TSV whose
  expected result is derived from the recorded status-bar message type.
- **Deliberately NOT run autonomously (the GUI leg):** `--with-screens` replays recorded actions on a
  live session (executes the transaction) — confirm-gated with write actions enumerated, so this
  session verified the harvest / DDIC / compose paths, not a live replay. The replay VBS ships correct
  (attach-lib, control-ID dispatch, recorded-vs-live screen-identity verify -> REPLAY_DIVERGED) with a
  golden-screen baseline for its generic deps.
- **Honesty invariants:** a field whose label/doc can't be fetched -> COULD_NOT_CHECK (never dropped);
  replay divergence -> REPLAY_DIVERGED + partial-capture note (never a false-complete guide, never a
  wrong-screen action); the guide header records the SID/client/release the guide was produced on.
- **Deferred:** `--uat` full expected-result engine (v1.5); wrapper-based full-dynpro field inventory
  (v1.5); `pack --create-data` invoking the tcd skills (v2). ECC 6 shares the identical RFC path
  (DOCU_GET standardised for DOKTL-CLUSTER); EC2 was unavailable this session for the ECC re-confirm.
