# sap-translate

**SE63 short-text translation, automated end to end with a mandatory review gate.**
Harvests every translatable short text in a scope, lets Claude propose length-checked
translations for a human to review in a TSV, then writes them back confirm-gated and
verified — turning the end-of-delivery SE63 grind into a reviewed pipeline.

```
/sap-translate harvest <MSGCLASS Z.. | DTEL Z.. | TABLE Z.. | DOMAIN Z..> --to <LANG> [--from <LANG>]
/sap-translate apply <review.tsv> [--overwrite]
```

## What it does

- **harvest** (read-only) — expands a scope (TR/package via
  `sap_object_resolver.ps1 -Expand`, or a single object) and collects message-class
  texts (T100) and DDIC labels (DD04T data-element DDTEXT/REPTEXT/SCRTEXT_S/M/L, DD02T
  table, DD03T direct-type field, DD01T domain, DD07T fixed value) in the from- and
  to-language into `translate_review.tsv`, each row carrying the **hard per-unit
  length limit** (SE63 silently truncates overlong entries) and the current target
  text.
- **Propose + STOP** — Claude fills `proposed_text` under `max_len` (unfittable rows
  are marked `TOO_LONG` and excluded); then the skill STOPS. The review gate is
  mandatory — harvest NEVER auto-applies.
- **apply** (confirm-gated write) — re-validates every length (any overflow →
  `TRANSLATE_LENGTH_OVERFLOW`, never written), diffs against the live target
  (overwriting an existing translation needs `--overwrite`), writes via the SE63
  engine FMs `LXE_OBJ_TEXT_PAIR_READ/WRITE` through `Z_GENERIC_RFC_WRAPPER_TBL` (both
  FMs are FMODE-blank), and **verifies every row by an authoritative RFC re-read** —
  mismatch is `TRANSLATE_VERIFY_MISMATCH`, never trusted from status text.
- A row whose target language equals the object's original language is **refused** and
  routed to the owning workbench skill (`/sap-se91` / `/sap-se38` / `/sap-se11`) —
  translation is not an original-language edit.
- Registers `translation_review` / `translation_apply` artifacts for
  `/sap-evidence-pack`.

## Prerequisites

- Pinned RFC profile via `/sap-login`; SAP NCo 3.1 (32-bit)
- The dev-init wrapper FM (`/sap-dev-init`) — apply only; harvest needs no wrapper
- Pure RFC + wrapper; no new Z object; single code path on ECC 6 + S/4

## Reference files

| File | Purpose |
|---|---|
| `references/sap_translate_harvest.ps1` | Harvest translatable texts → review TSV |
| `references/translate_length_limits.tsv` | Hard per-unit length limits (DDIC-cross-checked live) |

## Safety & limitations (v1)

- **harvest live-verified on S4D (S/4HANA 1909):** dtel MATNR EN→DE returned all 5
  units with length limits; message class 00 returned source + current target + max 73.
- **v1 harvest types:** message class + DDIC (dtel/table/domain). Program text pools
  (text elements + selection texts) land in v1.5.
- **The SE63 GUI fallback is NOT yet shipped.** If the wrapper write fails (or
  `sap_dev_mode=GUI`), apply emits `NEEDS_RECORDING` — no fallback VBS exists yet; it
  is to-be-recorded once per text type via `/sap-gui-probe --record`. Harvest and
  review are unaffected.
- v1 leaves translations untransported (SLXT transport packaging is v1.5). v2: screen
  texts (D020T/CUA), SO10/DOCU long texts, multi-target `--langs`.
