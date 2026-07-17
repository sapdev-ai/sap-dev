# SAP SE14 DB Utility Skill

Diagnoses and repairs stuck DDIC tables via SE14 (Database Utility) — the gap
`/sap-se11` names but never implemented. `check` is a read-only RFC snapshot of
DDIC-vs-DB consistency; `adjust` drives SE14 "Activate and adjust database" on
the **save-data path only**; `unlock` recovers a TERMINATED conversion. Both
write modes are confirm-gated, GUI-driven, and post-verified by an
authoritative RFC re-read. No transport request is involved — SE14 adjustment
is a DB-level operation, not a repository change.

## Skill Overview

1. `check <TABLE>` (always runs first, read-only): probes DD02L (active row +
   pending version), DWINACTIV (inactive worklist), TBATG (open conversion /
   DB-utility request), DBDIFF (DDIC/DB diff), `QCM<T>` / `QCM8<T>` shadow
   tables, and the DDPRH log header → verdict `CONSISTENT` / `ADJUST_NEEDED` /
   `CONVERSION_RUNNING` / `CONVERSION_TERMINATED` / `NOT_FOUND`
2. Write-mode guards: non-TRANSP tables refused
   (`SE14_UNSUPPORTED_TABCLASS`); `CONVERSION_RUNNING` refuses both write
   modes; `unlock` requires verdict `CONVERSION_TERMINATED`
3. **CONFIRM gate** (mandatory yes/no naming the table and SID/client), then
   the recorded SAPMSGTB driver runs via 32-bit cscript
4. Post-verify: `check` is re-run over RFC — only a clean re-read yields
   SUCCESS; the GUI status bar alone never does. The result is registered for
   `/sap-evidence-pack`

`/sap-se11` auto-chains `/sap-se14 check <TABLE>` after a failed table
activation and surfaces the verdict; the user still triggers any write.

## Auto-Trigger Keywords

- `se14 <table>`, "database utility", "activate and adjust <table>"
- "table <X> is stuck / inconsistent", "DDIC and database out of sync"
- "conversion terminated for <table>"

## Usage

```text
/sap-se14 check ZMYTABLE
/sap-se14 adjust ZMYTABLE
/sap-se14 unlock ZMYTABLE
/sap-se14 unlock ZMYTABLE continue
```

Conversational forms:

- "Check whether ZMYTABLE is consistent with the database"
- "Table ZMYTABLE won't activate — adjust it, keeping the data"

## Prerequisites

- Pinned RFC profile via `/sap-login` for `check`; a live SAP GUI session for
  `adjust` / `unlock`
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC
- The DB-existence probes degrade to `COULD_NOT_CHECK` without the optional
  dev-init wrapper FM (never auto-deployed)

## Key Reference Files

| File | Purpose |
|---|---|
| `references/sap_se14_check_rfc.ps1` | RFC consistency battery + verdict (also the write-mode post-verify) |
| `references/sap_se14_adjust.vbs` | SAPMSGTB save-data-only adjust driver — recorded + live-verified end-to-end on S4D (S/4HANA 1909) 2026-07-12 |
| `references/sap_se14_adjust.screens.json` | Golden screen baseline for the adjust driver |
| `references/sap_se14_unlock.vbs` | Conversion-recovery driver — `NEEDS_RECORDING` until captured |

## Limitations / Safety

- **The delete-data path is structurally unreachable, not merely gated:** no
  VBS code path selects that radio (`radRSGTB-DDATA` is only ever READ, to
  assert it is not selected), and the save-data radio (`radRSGTB-SDATA`) is
  asserted present AND `.Selected` by component ID before the adjust press.
  An unconfirmable save-data rail refuses with `SE14_SDATA_NOT_DEFAULT`
  (adjust never pressed); any wording asking for the delete-data variant is
  refused immediately (`SE14_DELETE_PATH_REFUSED`, no v1 override)
- **`unlock` stays `NEEDS_RECORDING`:** its recovery controls only
  materialize in a genuine `CONVERSION_TERMINATED` state, which cannot be
  safely manufactured on a shared dev system. Running the driver echoes
  `SE14: NEEDS_RECORDING` and exits — never a guessed click.
  `unlock release-lock` additionally requires the QCM-data guard to prove no
  data is stranded (`SE14_QCM_DATA_AT_RISK` otherwise, refused in v1)
- The adjust driver was live-verified against a CONSISTENT scratch table (a
  no-op re-conversion); the control contract is state-independent, and
  SUCCESS is still gated by the RFC re-read, never the status bar alone
- `--background` (TBATG), the full RADPROTA log, and index/storage verbs are
  roadmap (v1.5 / v2)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
