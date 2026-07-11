---
name: sap-vofm
description: |
  Diagnose SD condition-technique VOFM routines (pricing requirements + condition
  base/value formulas) — the notorious trap where a routine is registered but the
  generated include was never wired in by RV80HGEN, or the include+registry don't
  travel together in a transport, and you burn hours on "routine not found at
  runtime". `list <type>` enumerates a routine group from TFRM joined to PROGDIR
  existence/active state + frame-include membership; `check <type> <nnn>` proves one
  routine end-to-end (TFRM row, include exists+active, RV80HGEN wired it into the
  frame, transport completeness) → findings + GO/NO_GO; `explain <type> <nnn>` reads
  the routine include source over RFC and narrates it. Every verdict is an
  authoritative RFC re-read — screen text is never trusted. Read-only. create/update/
  regen (GUI writes) are NEEDS_RECORDING (deferred to a /sap-gui-probe session).
  Prerequisites: /sap-login pinned profile; SAP NCo 3.1 (32-bit).
argument-hint: "list <type> [--customer-only] [--max N]  |  check <type> <nnn> [--tr <TRKORR>]  |  explain <type> <nnn>   (type: pricing-req | cond-base | cond-value)"
---

# SAP VOFM — SD Condition-Technique Routine Diagnostics

VOFM routines are a three-part trap: the body lives in a *generated* include, the
routine only runs after **RV80HGEN** rewires the `*NNN` frame include, and the
TFRM/TFRMT registry rows + the include don't travel cleanly in a transport without
manual E071/E071K additions. This skill proves all three over RFC — no guessing, no
trusting screen text.

Task: $ARGUMENTS

**Read-only** (`list`/`check`/`explain`). The write modes (`create`/`update`/`regen`)
need a recorded VOFM GUI flow and are **not yet implemented** (see Scope).

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SKILL_DIR>/references/vofm_routine_groups.tsv` | *(read)* | `type_key → GRPZE / frame_include / customer_prefix / standard_prefixes / range / verified` map |
| `<SKILL_DIR>/references/sap_vofm_rfc.ps1` | `-Action list\|check\|resolve` | Read backend (TFRM/PROGDIR/DWINACTIV/E071/E071K + frame-membership scan) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_read_source.ps1` | `Read-SapAbapSource` | `explain`: read the routine include source over RFC (RPY_PROGRAM_READ) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_settings_lib.ps1` + `sap_connection_lib.ps1` | *(dot-source)* | `Get-SapWorkDir` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_log_helper.ps1` | *(invoke)* | Start/step/end JSONL logging |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` / `sap_finding_lib.ps1` | `%%ARTIFACT_LIB_PS1%% %%FINDING_LIB_PS1%%` | Register outputs + tri-state findings/verdict |

> The read backend connects to the **pinned** profile (`/sap-login`). Ships no GUI
> VBS in v1 (the write modes will).

## Step 0 / 0.5 — Work Dir + Logging

Resolve `work_dir`/`{RUN_TEMP}` via `Get-SapWorkDir`/`Get-SapRunTemp` (house one-liner),
then start logging (`sap_log_helper.ps1 -Action start`, state `{RUN_TEMP}\sap_vofm_run.json`).

## Step 1 — Mode Dispatch + Type Resolution

Modes: `list` | `check` | `explain` (read-only, implemented); `create` | `update` |
`regen` (**NEEDS_RECORDING** — see Scope; refuse with that note). Read
`<SKILL_DIR>/references/vofm_routine_groups.tsv` and resolve `<type>` (a friendly
`type_key`, or a raw 4-char GRPZE). **Refuse an unknown type, or a `verified=NO` row,
loudly** with the valid list — never guess a frame/prefix. From the resolved row take
`grpze`, `frame_include`, `customer_prefix`, `standard_prefixes`, `customer_range`.

## Step 1.5 — Range Gate (create/update only, when implemented)

`<nnn>` for a write must lie inside `customer_range` (600–999) — outside → hard refuse
`VOFM_RANGE_VIOLATION` (editing an SAP-numbered routine is a modification, out of
scope). Read modes have no range gate (you may inspect any number).

## Step 2 — Read Backend (list / check / explain)

**list** — enumerate the group:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_vofm_rfc.ps1" -Action list -Grpze <GRPZE> -FrameInclude <FRAME> -CustomerPrefix <PFX> -StandardPrefixes "<p1,p2>" [-CustomerOnly] [-Max <n>] -OutFile "{RUN_TEMP}\vofm_list_<type>.tsv" -WorkDir "<work_dir>"
```

Each `VOFM: grpno=<nnn> active=<Y|N> include=<name> exists=<Y|N> state=<A|I|-> registered=<Y|N|STD> text="…"` +
`STATUS: OK total=<n> registered=<r> gaps=<g>`. **`registered=N` on a customer routine
(≥600) is the headline finding** — it's in TFRM but RV80HGEN never wired its include
into the frame (or it's deactivated): "routine not found at runtime". `registered=STD`
= a standard SAP routine (frame membership via the customer frame is N/A).

**check** — prove one routine:

```bash
… sap_vofm_rfc.ps1 -Action check -Grpze <GRPZE> -Nnn <nnn> -FrameInclude <FRAME> -CustomerPrefix <PFX> -StandardPrefixes "<p1,p2>" [-Tr <TRKORR>] -WorkDir "<work_dir>"
```

Emits `VOFM_CHECK … tfrm=<PRESENT|ABSENT> active= include= exists= state= inactive_pending= registered= transport=<COMPLETE|GAP:..|NOT_CHECKED>`,
`FINDING …` lines, and `VERDICT: <GO|GO_WITH_WARNINGS|NO_GO|NOT_FOUND>`. With `--tr
<TRKORR>` it also checks transport completeness (E071 for the include + E071K for the
TFRM/TFRMT keys) — a `GAP:` is a WARN with the manual SE01 "include objects" fix (v1 is
detect-only; **never** writes E071/E071K). Map findings via `sap_finding_lib.ps1`
(tri-state — a frame-read failure is `registered=?` → `COULD_NOT_CHECK`, never a pass).

**explain** — narrate a routine:
1. `-Action resolve -Grpze <GRPZE> -Nnn <nnn> -CustomerPrefix <PFX> -StandardPrefixes "<..>"` → the include name (`VOFM_RESOLVE nnn= include= exists= state=`).
2. If it exists, `Read-SapAbapSource -Name <include> -Type include` (shared reader) → read the FORM body.
3. Claude narrates purpose / inputs (KOMK/KOMP/XKOMV communication structures) / side effects; an unreadable include → `COULD_NOT_CHECK`, never invented.

## Step 3 — Register & Log End

Register `vofm_list_<type>.tsv` (kind `vofm_list`), a `vofm_check_<type>_<nnn>.md` +
findings export (kind `vofm_check`, coverage tri-state, verdict), and the explain
dossier (kind `object_dossier`) via `Register-SapArtifact`. Echo the verdict headline.
Then `sap_log_helper.ps1 -Action end` (SUCCESS / SKIPPED+`VOFM_RANGE_VIOLATION` /
FAILED+`RFC_LOGON_FAILED`).

---

## Scope & Limitations

- **v1 implemented (read-only):** `list`, `check`, `explain` for the **verified pricing
  groups** — `pricing-req` (PBED / RV61ANNN / RV61A), `cond-base` (PFRA / RV63ANNN /
  RV63A), `cond-value` (PFRM / RV64ANNN / RV64A). Dual-verified live 2026-07-11 on
  S/4HANA 1909 (S4D) **and** ECC 6 (EC2/ERP): the read stack (TFRM, PROGDIR, DWINACTIV,
  E071/E071K, RPY frame read) is identical on both (TFRM is POOL on ECC vs TRANSP on
  S/4 — transparent to RFC_READ_TABLE). On S4D all 6 PBED customer routines resolved
  registered=Y/active/STATE=A; on ERP the scan **caught a real gap** — PBED/983 present
  in TFRM but absent from the RV61ANNN frame (`registered=N`), exactly the trap the
  skill exists to surface. Layered include resolution proven both ways (customer
  `RV61A902`, standard `LV61A002`).
- **Honest by construction:** `registered=N` is only asserted when the frame source was
  read and the routine's include is absent; a frame-read failure is `registered=?` →
  `COULD_NOT_CHECK`, never a pass. `NOT_FOUND` (no TFRM row) is distinct from a real
  finding. Verdicts are authoritative RFC re-reads (TFRM row + PROGDIR STATE +
  DWINACTIV + frame membership), never screen text.
- **Other VOFM groups** (`copy-req-order` FBED, copy/data-transfer for billing/delivery,
  output, account determination, rebate, …) ship in the TSV flagged **`verified=NO`**
  and are **refused loudly** with the valid list — copy-requirements use a two-level
  frame (`FV45CNNN` → nested `RV45CNNN`) and an unverified customer prefix, so they need
  a `/sap-gui-probe` + live pass before enablement (v1.5), never a guess.
- **Not implemented (NEEDS_RECORDING):** `create` / `update` / `regen` — registering a
  routine via the VOFM dynpro, deploying the body (delegated `/sap-se38`), running
  `RV80HGEN` (delegated `/sap-run-report`), and the authoritative post-write verify all
  require a `/sap-gui-probe --record` capture of the VOFM menu-path + table-control
  insert + SSCR-object-key + TR popups on **both** releases (and a golden-screen
  baseline). This is deferred to a dedicated recording session; the read triad above is
  the shipped value. New error classes reserved for that phase:
  `VOFM_RANGE_VIOLATION`, `VOFM_SSCR_KEY_REQUIRED`, `VOFM_REGEN_STALE`.
- **Transport completeness is detect-only** — a `GAP:` prints the manual SE01 steps; the
  auto-fix (adding E071/E071K entries) is v2 and stays GUI-only (Rule 1: no writes on
  E071/E071K).
