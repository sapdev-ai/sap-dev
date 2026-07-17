---
name: sap-translate
description: |
  SE63 short-text translation, automated end to end with a mandatory review gate. harvest expands
  a scope (TR/package/object) and collects every translatable short text — message-class texts
  (T100), DDIC labels (DD04T data-element DDTEXT/REPTEXT/SCRTEXT_S/M/L, DD02T table, DD03T
  direct-type field, DD01T domain, DD07T fixed-value) in the from- and to-language — into a review
  TSV carrying the HARD per-unit length limit (SE63 silently truncates overlong entries) and the
  current target text, then STOPS so Claude can propose length-checked translations for a human to
  review. apply loads the reviewed TSV, re-validates every length (hard refusal on overflow), diffs
  vs the live target, and writes back behind a confirm gate via the SE63 engine FMs
  (LXE_OBJ_TEXT_PAIR_READ/WRITE, through Z_GENERIC_RFC_WRAPPER_TBL since they are FMODE-blank), with
  a recorded SE63 GUI flow as the per-type fallback, verified by an authoritative RFC re-read per
  row. A row whose target equals the object's original language is refused and routed to the owning
  workbench skill (translation != original-language edit). Pure RFC + wrapper (no new Z object; the
  wrapper is dev-init's); single code path ECC6 + S/4 (all FMs/tables identical) — SE63 GUI layout
  is the only release-variant surface. Prerequisites: /sap-dev-init wrapper; pinned /sap-login RFC
  profile; NCo 3.1 (32-bit).
argument-hint: "harvest <MSGCLASS Z.. | DTEL Z.. | TABLE Z.. | DOMAIN Z..> --to <LANG> [--from <LANG>] | apply <review.tsv> [--overwrite]"
---

# SAP Translate Skill

You turn the end-of-delivery SE63 grind into: harvest every translatable short text -> propose
length-checked translations -> human reviews the TSV -> apply writes them back, verified. harvest
is read-only and never chains into apply; apply is confirm-gated and length-enforced.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_translate_harvest.ps1` | `-Object -Type -To` | Harvest translatable texts -> review TSV |
| `<SKILL_DIR>/references/translate_length_limits.tsv` | read by harvest | Hard per-unit length limits (DDIC-cross-checked live) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-source / CLI | TR/package scope expansion (`-Expand`) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` | dot-source | RFC connect |
| `/sap-se91` · `/sap-se38` · `/sap-se11` · `/sap-transport-request` | sub-skills | Original-language edits (routed) / TR if an SE63 flow records one |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_translate_run.json`). Pinned RFC profile via `/sap-login`; wrapper FM from
`/sap-dev-init` (apply only).

## Step 1 — Parse & Dispatch

`harvest` (read) | `apply` (write). `--to` (target LANG) required for harvest; `--from` defaults
to the object's original language (resolver MASTERLANG) or `E`. `--types` default = all v1 types.

## Step 2 — harvest

```bash
... sap_translate_harvest.ps1 -Object <n> -Type msgclass|dtel|table|domain -From E -To <LANG> -OutDir "{RUN_TEMP}\tr"
```

For a TR/PACKAGE scope, first expand via `sap_object_resolver.ps1 -Expand` and harvest each object.
`TR:` lines + `translate_review.tsv` (seq / obj / unit_type / unit_key / src / current_tgt / max_len
/ status NEW|EXISTS). Empty scope -> `TRANSLATE_EMPTY_SCOPE`.

## Step 3 — Propose (you) + STOP

For every NEW row (and EXISTS rows if the operator wants a re-translation), **you** fill
`proposed_text` under `max_len` (shorten-retry; unfittable -> mark `TOO_LONG`, excluded from apply).
Write the reviewed TSV. **STOP** — the review gate is mandatory; harvest NEVER auto-applies. Tell
the operator to review/edit the TSV then run `apply`.

## Step 4 — apply (confirm-gated write)

1. Load the reviewed TSV; re-validate EVERY length (any overflow -> `TRANSLATE_LENGTH_OVERFLOW`,
   listed, never written); diff vs live target (rows overwriting an existing translation need
   `--overwrite` else SKIP); a row whose target == the object's original language -> refuse + route
   to `/sap-se91` (msg) / `/sap-se38` (sel) / `/sap-se11` (DDIC).
2. **CONFIRM gate:** "I will WRITE `<n>` translations (`<counts by type>`) into language `<TL>` on
   `<SID>/<CLIENT>`, overwriting `<k>` existing texts. Proceed? (yes/no)". On no -> `SKIPPED`.
3. Write per type via the SE63 engine FMs `LXE_OBJ_TEXT_PAIR_READ` -> mutate -> `LXE_OBJ_TEXT_PAIR_WRITE`
   through `Z_GENERIC_RFC_WRAPPER_TBL` (FMODE-blank -> the asXML wrapper bridge). On wrapper failure
   or `sap_dev_mode=GUI`, degrade to a recorded SE63 GUI flow — not yet captured (no VBS ships):
   emit `NEEDS_RECORDING` and record it once per text type via `/sap-gui-probe --record`.
4. **Verify:** authoritative RFC re-read per row (T100 / DD04T / DD02T / DD03T / DD01T / DD07T) —
   compare row-for-row; mismatch -> `TRANSLATE_VERIFY_MISMATCH` (never trust GUI status text).

## Step 5 — Register

`Register-SapArtifact` (kind `translation_review` for harvest, `translation_apply` for apply;
coverage + verdict) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `TRANSLATE_EMPTY_SCOPE`,
`TRANSLATE_LENGTH_OVERFLOW`, `TRANSLATE_VERIFY_MISMATCH`, `LXE_WRITE_FAILED`, `TRANSLATE_INPUT`;
reused `RFC_LOGON_FAILED` / `GUI_TIMEOUT` / `NEEDS_RECORDING`.

---

## Scope & Limitations (v1)

- **harvest live-verified on S4D (S/4HANA 1909) 2026-07-11:** dtel MATNR EN->DE returned all 5
  units (DDTEXT "Material Number"->"Materialnummer", REPTEXT, SCRTEXT_S/M/L) with per-field length
  limits + current German text; message class 00 EN->DE returned messages with source + current
  target + max 73. EC2 (ECC 6) was probed in-plan (all FMs/tables + SE63 identical) but unreachable
  at build time; the harvest is one RFC code path (RFC_READ_TABLE on T100 + DD*T).
- **v1 harvest types: message-class + DDIC (dtel/table/domain).** Program **text pool** (text
  elements + selection texts via `RS_TEXTPOOL_READ`) is FMODE-blank -> needs the wrapper asXML
  bridge; it lands in v1.5 (the harvest architecture is unchanged, just an extra unit source).
- **apply is the write path** (confirm-gated, length-enforced, review-gated). The SE63 engine FMs
  `LXE_OBJ_TEXT_PAIR_READ/WRITE` exist on both releases but are FMODE-blank (probed) -> routed
  through the dev-init wrapper; `RS_TEXTPOOL_WRITE` does NOT exist (probed both) so the write pivots
  to LXE. Exact LXE signatures are a documented day-1 build spike (fetched via
  `RPY_FUNCTIONMODULE_READ_NEW`, never guessed); if the FM pair proves unusable, apply falls back to
  a to-be-recorded SE63 GUI flow for that type (`NEEDS_RECORDING` until captured via
  `/sap-gui-probe --record`) — harvest/review are unaffected. Every write is verified
  by an independent RFC re-read; the mandatory review TSV + confirm gate mean nothing is written
  unattended.
- **Never translates the original language:** a row whose target == MASTERLANG is refused and routed
  to the workbench skill (that is an original-language edit, not a translation).
- **v1.5:** program text pool + selection texts (RS_TEXTPOOL_READ); `status` coverage report; SLXT
  transport packaging (v1 leaves translations untransported, documented). **v2:** screen texts
  (D020T/CUA), SO10/DOCU long texts, multi-target `--langs`.
