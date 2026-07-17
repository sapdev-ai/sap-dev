# sap-transport-copies

**Builds and verifies Transports of Copies (ToC) headlessly over RFC** — for teams
that test in QA before releasing dev TRs. Creates a type-T request targeted at QA,
copies every source TR's (and its tasks') object list into it, and makes the E071
union check — ToC contents == union of the sources — a **hard gate before release**,
which a human in SE01 practically never does.

```
/sap-transport-copies <TR1[,TR2,...]> | --current [--target <SID>] [--desc "..."] [--release] [--import]
/sap-transport-copies verify <TOC> --sources <TRs>
/sap-transport-copies list [--user U]
/sap-transport-copies cleanup
```

## What it does

- **build** — `create` (type-T request via `TR_INSERT_REQUEST_WITH_TASKS`, new TRKORR
  parsed and E070-confirmed) → `include` (each source's whole object list via
  `TR_COPY_COMM`, run once into a fresh ToC — the FM appends, so re-including
  duplicates E071 rows) → `verify` (set-diff of `(PGMID,OBJECT,OBJ_NAME)`; any missing
  object → `TOC_UNION_MISMATCH` and STOP before release).
- **--release** (gated) — only after a clean union verify; releases via
  `TR_RELEASE_REQUEST` and re-reads E070 `TRSTATUS='R'`. Releasing a ToC never closes
  the source TRs, so the risk profile is low. **--import** delegates to `/sap-stms`
  (its own gates).
- **verify** — the standalone union check on any existing ToC.
- **list** — my modifiable ToCs (E070 `TRFUNCTION='T'` + description + live E071
  object count).
- **cleanup** — stale modifiable ToCs (default older than 14 days), per-request
  confirm, deletion delegated to `/sap-se01` (which re-confirms and verifies removal).
- Writes `toc_manifest.tsv` + `toc_union_diff.tsv` to the artifact dir and registers
  them for `/sap-evidence-pack`.

## Prerequisites

- Pinned RFC profile via `/sap-login`; SAP NCo 3.1 (32-bit)
- The dev-init wrapper `Z_GENERIC_RFC_WRAPPER_TBL` (via `/sap-dev-init` — never
  deployed here); all CTS write FMs are FMODE-blank and reached through it
- `--target` resolves arg → userConfig `toc_default_target` → hard ERROR (a target is
  never guessed)

## Reference files

| File | Purpose |
|---|---|
| `references/sap_transport_copies_rfc.ps1` | ToC build + E071 union + release (`-Action create\|include\|verify\|list\|release`) |

## Safety & limitations (v1)

- Pure RFC — no GUI, no golden-screen recording, one code path on ECC 6 + S/4HANA.
  Reads via RFC_READ_TABLE (E070/E071/E07T); mutations only via SAP CTS APIs, no SQL
  writes.
- **Release is the only irreversible action**: single confirm gate, refused unless the
  union verified clean (`--force` + explicit yes overrides). `cleanup` hard-refuses
  any request with `TRFUNCTION≠'T'`, so a real workbench TR can never be deleted from
  here.
- Live-verified on S4D (S/4HANA 1909): create, include (61-object list), verify both
  ways, list. `release` is wired from its verified signature but not run autonomously —
  it executes only under the confirm gate.
- Source objects locked in another *modifiable* request cannot be copied (SAP
  constraint) — prefer released sources, exactly the QA-drop use case. An object
  `TR_COPY_COMM` doesn't carry shows honestly as a verify MISSING, never a silent pass.
