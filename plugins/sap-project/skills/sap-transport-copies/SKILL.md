---
name: sap-transport-copies
description: |
  Builds and verifies Transports of Copies (ToC) headlessly over RFC — for teams that test in
  QA before releasing dev TRs. Creates a type-T request targeted at QA, copies every source TR's
  (and its tasks') object list into it, and makes the E071 union check — ToC contents == union of
  the sources — a HARD GATE before release, which a human in SE01 practically never does. Optional
  `--release` (gated) and `--import` (delegates /sap-stms). Also `verify` (standalone union check),
  `list` (my modifiable ToCs), and `cleanup` (stale ToCs → delegated /sap-se01 delete). Pure RFC:
  reads via RFC_READ_TABLE (E070/E071/E07T), writes via the CTS FMs TR_INSERT_REQUEST_WITH_TASKS /
  TR_COPY_COMM / TR_RELEASE_REQUEST through the dev-init wrapper Z_GENERIC_RFC_WRAPPER_TBL — no GUI,
  no golden-screen recording, one code path on ECC 6 + S/4HANA. Releasing a ToC never closes the
  source TRs, so the risk profile is low. Prerequisites: pinned RFC profile via /sap-login; the
  dev-init wrapper (via /sap-dev-init — never deployed here); SAP NCo 3.1 (32-bit).
argument-hint: "<TR1[,TR2,...]> | --current [--target <SID>] [--desc \"...\"] [--release] [--import] | verify <TOC> --sources <TRs> | list [--user U] | cleanup"
---

# SAP Transport of Copies Skill

You assemble a Transport of Copies from one or more source TRs and **prove the E071 union is
complete before release** — never releasing a ToC whose object list doesn't cover its sources.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_transport_copies_rfc.ps1` | `-Action create\|include\|verify\|list\|release` | ToC build + E071 union + release (RFC + wrapper) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | dot-sourced | NCo 3.1 connect/disconnect |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced | `Read-SapTableRows` (E070/E071/E07T) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | ToC manifest + union-diff registration |
| `/sap-login` · `/sap-dev-init` | sub-skills | Pinned profile · deploys the wrapper (this skill never does) |
| `/sap-se01` · `/sap-stms` | sub-skills | `cleanup` delete · `--import` (their own gates) |

`--current` resolves the session dev-default TR. `--target` falls back to userConfig
`toc_default_target`; blank + no default = hard ERROR (never guess a target).

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner — `sap_connection_lib.ps1` is dot-sourced
there — with `Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))` appended). `{RUN_TEMP}` = the
per-run scratch dir holding the log state file; mint it once here and reuse (re-minting breaks
the `-Action end` state-file lookup). Start logging (`sap_log_helper.ps1`,
state `{RUN_TEMP}\sap_transport_copies_run.json`). Pure RFC — no GUI session.

## Step 1 — Parse & Dispatch

First token = a TR list or `--current` → **build**; else `verify` | `list` | `cleanup`. Resolve
`--target` (arg → `toc_default_target` → hard ERROR). Render the description (`toc_desc_template`,
placeholders `{SOURCES}/{TARGET}/{YYYYMMDD}/{USER}`, 60-char truncate).

## Step 2 — RFC Profile + Sources

Pinned RFC profile required (`/sap-login`) — missing → `RFC_LOGON_FAILED`, STOP. Pre-check each
source over RFC (E070 exists, type K/W, same system); enumerate tasks via `STRKORR`. Any miss →
hard ERROR naming the bad TR. Echo the build plan (sources, task counts, target, desc).

## Step 3 — Build (create → include → verify)

```bash
# create the type-T request
... sap_transport_copies_rfc.ps1 -Action create -Text "<desc>" -Target "<SID>" -SharedDir "..."   # -> TOC:create toc=<TOC>
# copy each source's (and its tasks') object list in
... -Action include -Toc <TOC> -Sources "<TR1,TR2>"
# HARD GATE: E071 union == union of sources+tasks
... -Action verify -Toc <TOC> -Sources "<TR1,TR2>" -OutTsv "<dir>\toc_union_diff.tsv"
```

`create` uses `TR_INSERT_REQUEST_WITH_TASKS` (IV_TYPE='T') via the wrapper, parses the new TRKORR
from `ES_REQUEST_HEADER`, and re-reads E070 (`TRFUNCTION='T'`) to confirm — else `TOC_CREATE_FAILED`.
`include` copies each source via `TR_COPY_COMM` (whole object list, scalar TRKORR→TRKORR) — run it
ONCE into a fresh ToC (TR_COPY_COMM appends, so re-including duplicates E071 rows). `verify`
set-diffs `(PGMID,OBJECT,OBJ_NAME)`: `MISSING>0` → report every missing object + `TOC_UNION_MISMATCH`
and STOP before release.

## Step 4 — Release (`--release` only, gated)

Only when Step 3 verify = UNION_OK. **Confirm gate:**

> I will release ToC `<TOC>` targeting `<SID>` (source TRs stay open). This is a real transport
> release. Proceed? (yes/no)

Then `-Action release -Toc <TOC>` (`TR_RELEASE_REQUEST` via wrapper) → re-read E070 `TRSTATUS='R'`.
Verify not clean → `TOC_RELEASE_BLOCKED`. Skipped/failed verify blocks release (override:
`--force` + explicit yes). `--import` → delegate `/sap-stms import <TOC> --to <SID>` (its gates).

## Step 5 — Manifest + Register

Write `toc_manifest.tsv` + `toc_union_diff.tsv` into the artifact dir
(`Get-SapArtifactDir -ScopeKey TR_<TOC>`); register (`Register-SapArtifact -Kind toc_manifest` /
`toc_union_diff`, coverage tri-state, verdict PASS/FAIL). Print
`TOC: <TOC> target=<SID> sources=<k> union=<verdict> released=<y/n>`.

## verify / list / cleanup modes

- **verify** — Steps 0–2 then `-Action verify` standalone on `<TOC>` + `--sources`.
- **list** — `-Action list [-User <U>] [-IncludeReleased]` → E070 `TRFUNCTION='T'` + E07T text +
  live E071 object count per ToC.
- **cleanup** — `list` the stale modifiable ToCs (older than `--older-than`, default 14d) →
  per-request confirm → delegate `/sap-se01 delete <TOC>` (it re-confirms + verifies removal).
  Refuses any request with `TRFUNCTION≠'T'`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class): `TOC_CREATE_FAILED` / `TOC_INCLUDE_FAILED` /
`TOC_UNION_MISMATCH` / `TOC_RELEASE_BLOCKED` / `TOC_TARGET_INVALID` / `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **RFC-first (not the plan's GUI-first v1).** Because `Z_GENERIC_RFC_WRAPPER_TBL` is now a proven
  write bridge, the ToC build runs entirely over RFC — no SE01 golden-screen recording, one code
  path on ECC 6 + S/4HANA. Every CTS write FM (TR_INSERT_REQUEST_WITH_TASKS / TR_COPY_COMM /
  TR_RELEASE_REQUEST) is FMODE-blank and reached through the wrapper (asXML PARAMETER-TABLE); the
  RFC boundary's implicit COMMIT persists the write.
- **Live-verified on S4D (S/4HANA 1909):** `create` (made a real type-T request, E070-confirmed),
  `include` (TR_COPY_COMM copied a 61-object list into the ToC), `verify` BOTH ways (empty ToC →
  all-MISSING `TOC_UNION_MISMATCH`; populated ToC → union computed over source+tasks), and `list`
  (with live per-ToC object counts). `release` is wired from its verified signature + the proven
  wrapper write pattern but is **not run autonomously** (a transport release is irreversible) —
  it executes under the Step 4 confirm gate. `--import` is fully delegated to `/sap-stms`.
- **ECC 6 parity:** E070/E071/E07T + the CTS FMs + the wrapper are all present per the plan's
  probe; SE01 is `RDDM0001` on both but this skill needs no GUI. One code path.
- **TR_COPY_COMM semantics:** copies the FROM request's whole comm-object list and APPENDS (not
  idempotent) — the skill includes once into a fresh ToC; a source object TR_COPY_COMM doesn't
  carry (e.g. a merged/documentation entry) shows honestly as a `verify` MISSING rather than a
  silent pass. Source objects locked in another *modifiable* request cannot be copied (SAP
  constraint) — prefer released sources, exactly the QA-drop use case.
- **Safety:** release is the only irreversible action (single confirm gate; refused unless the
  union verified clean — `--force` + explicit yes overrides). `cleanup` delete is delegated to
  `/sap-se01` (re-confirms), hard-refuses any `TRFUNCTION≠'T'` so a real workbench TR can never be
  deleted from here. No SQL writes; mutations only via SAP CTS APIs. Read modes are unconfirmed
  (house precedent).
