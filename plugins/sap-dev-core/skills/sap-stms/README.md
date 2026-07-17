# SAP STMS Transport Landscape Skill

Moves a **released** transport request through the landscape (DEV → QAS → PRD)
and reads its import status / return code via STMS. Read-only by default; any
import is opt-in and gated — a production import is the most strongly-guarded
action in the whole toolset. This is the last link of the release chain:
`/sap-transport-readiness` (GO/NO-GO) → `/sap-se01 release` → **`/sap-stms`**.

## Skill Overview

Four modes:

1. **status** (default, READ-ONLY) — scrapes a target system's import queue
   (or walks the TR's route with `--route`) and reports where the TR sits
2. **logs** (READ-ONLY) — navigates into the named target system's queue and
   reads the import **return code**, mapped to a verdict:
   RC 0 = OK · 4 = OK_WITH_WARNINGS · 8 = ERROR · 12 = FATAL.
   **RC 8/12 is a failure even if the queue row looks "done"**
3. **import** (WRITE, gated) — imports one released TR into a target.
   Pre-flight hard stops: TR must be released (`E070-TRSTATUS = R`), not
   already imported, and a `/sap-transport-readiness` NO_GO blocks unless
   `--force`. QA targets need an explicit yes; a **PRODUCTION** target needs
   the user to **type the target SID back** plus a second "yes, import to
   production" — no bypass flag exists. RC is verified afterwards via logs
   mode, never the queue row
4. **import-all** (WRITE, double-gated, off without `--all`) — imports the
   whole queue; recommended only for DEV/QA refresh

Missing import authorization surfaces as `COULD_NOT_IMPORT` — never a faked
success.

## Auto-Trigger Keywords

- `stms`, "import queue", "import <TR> to QAS/PRD"
- "did <TR> import cleanly?", "what's the return code for <TR>?"
- "move the transport to production"

## Usage

```text
/sap-stms                                   (status of the default queue)
/sap-stms status DEVK900123 --route
/sap-stms status --system QAS
/sap-stms logs DEVK900123 --system QAS
/sap-stms import DEVK900123 --to QAS --client 100
/sap-stms import-all --to QAS --all
```

`--to` / `--system` is mandatory for any write — there is no default target.

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- QA/PROD imports need TMS import authorization (frequently Basis-only;
  status/logs work without it)
- Optional `prod_system_ids` setting — a comma-separated allow-list of
  production SIDs used to classify import targets

## Key Reference Files

| File | Purpose |
|---|---|
| `references/sap_stms_queue_read.vbs` (+ `.screens.json`) | Import-queue scrape (read-only) |
| `references/sap_stms_log_read.vbs` (+ `.screens.json`) | Import log + RC scrape (read-only) |
| `references/sap_stms_import.vbs` | Import one TR into a target — gated, recording-calibrated scaffold |

## Limitations / The Import Gate

- **The import VBS is a recording-gated scaffold that fails SAFE.** It ships
  with `PLACEHOLDER_*` control IDs for the destructive Import-Request press
  and the import-options dialog (the STMS queue/tree + dialog IDs vary by
  release and were NOT recorded against a live system), and it carries no
  golden screen baseline yet. On first use per release, run
  `/sap-gui-probe --record` on the `STMS_IMPORT` flow and replace the
  placeholders. Until then it fails loud (`ERROR: import controls not
  calibrated`) rather than clicking anything — a safe no-op, never a
  mis-import. Even calibrated, it only presses Import after positively
  verifying the selected row's TRKORR equals the requested TR on the intended
  target's queue
- `--immediate` / `--leave-in-queue` are **not yet wired** — a truthy value
  fails loud with `STMS_OPTION_UNSUPPORTED` instead of silently importing
  with the queue default
- Verdicts come from the import RC (0/4/8/12), never the queue row's
  appearance
- A broken TMS communication layer (the TMS Alert Viewer instead of the
  queue) surfaces as `STMS_TMS_RFC_DOWN` — a Basis problem
  (`TMSADM@<SID>.DOMAIN_<SID>` destination), not a control-ID recording issue
- No scheduling windows in v1 (immediate / next-run only); the RFC queue read
  (`TMS_MGR_READ_TRANSPORT_QUEUE`) is a documented Phase-2 path
- This skill never releases a TR — release stays a deliberate
  `/sap-se01 release` step

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
