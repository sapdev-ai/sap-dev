# SAP ST22 Dump Reader Skill

Reads ABAP runtime-error (short dump) evidence from ST22 by driving the
transaction via SAP GUI Scripting — GUI mode, no ADT (SNAP is a cluster table,
so dumps cannot be read over plain RFC). Read-only: it sets the date/user
selection, displays the dump list, and scrapes it into the shared diagnose
evidence contract. Usually invoked as a reader by `/sap-diagnose`, but runs
standalone.

## Skill Overview

1. Resolve the anchor — either `--anchor <path>` from the diagnose
   orchestrator, or built from `--user` / `--date` / `--window` flags
2. Run the reader VBS (32-bit cscript): navigate ST22, set the selection,
   display the dump list, scrape one evidence event per dump
   (date/time/user/program/exception/short-text + a synthetic `dump_key`)
3. With `--deep`, additionally open each in-scope dump and scrape the failing
   source line + snippet into the event's include/line and a `dump_detail`
   object — the input `/sap-fix-incident` consumes to root-cause a dump.
   Deep is opt-in, bounded by `--max-deep` (default 5), scopable to one dump
   via `--dump-key`, and **strictly additive**: a deep failure degrades to
   `partial`/`skipped` and never loses the list-level evidence
4. Fingerprint each dump (SHA1 of `exception|program[|include|line]`) into a
   team-shareable recurrence ledger at
   `{custom_url}\ops_kb\dump_fingerprints.tsv` and report the
   NEW / KNOWN_RECURRING / GONE delta (`--no-fingerprint` opts out;
   best-effort, never changes the verdict)
5. Report: `EVIDENCE: source=ST22 status=ok events=<n> deep=<n>` +
   `evidence_st22.json`, plus the recurrence split

## Auto-Trigger Keywords

- `st22`, "short dumps", "runtime errors", "dump list"
- "any dumps today / for user X?", "why did program Z dump?"
- "is this dump new or recurring?"

## Usage

```text
/sap-st22 --date today
/sap-st22 --user MILLER --date 20260715
/sap-st22 --date today --deep --max-deep 3
/sap-st22 --deep --dump-key 20260715083012ZMYPROG
/sap-st22 --date today --no-fingerprint
```

Full flag list: `[--anchor PATH] [--user U] [--date today|YYYYMMDD]
[--window MIN] [--session PATH] [--out PATH] [--top-n N] [--deep]
[--dump-key KEY] [--max-deep N] [--no-fingerprint]`.

## Prerequisites

- Active SAP GUI session (use `/sap-login` first)
- `RZ11` parameter `sapgui/user_scripting` set to TRUE on the SAP server
- 32-bit `cscript.exe` (SAP GUI Scripting COM is 32-bit)

## Key Reference Files

| File | Purpose |
|---|---|
| `references/sap_st22_read.vbs` | ST22 navigation + dump-list (and deep-detail) scrape → evidence JSON |
| `references/sap_st22_read.screens.json` | Golden screen baseline for the reader |
| `references/sap_st22_fingerprint.ps1` | Dump fingerprint + recurrence ledger; NEW/KNOWN_RECURRING/GONE delta (pure-local, best-effort) |

## Limitations / Release Calibration

- **Recording debt — the component IDs are release-calibrated.** ST22
  selection-field and result-grid IDs vary by release (the shipped candidates
  were captured against S/4HANA 1909). The reader tries its candidate IDs and
  then scans for the grid; when it cannot locate the list it degrades to a
  clean `status=skipped` with a hint to run `/sap-gui-probe --record` on ST22
  and update the candidates in `sap_st22_read.vbs` — it never guesses
- **Deep detail has its own calibration debt.** The dump detail view's text
  container varies by release; the scraper walks `wnd[0]/usr` for
  `GuiTextedit` controls and anchors on the locale-independent `>>>>` marker.
  Releases that render the dump as an HTML viewer return
  `detail_status=partial` (exception/program still captured from the list) —
  never report `partial` as "no defect found". A `/sap-gui-probe --record`
  pass on the dump-detail screen lifts it to `ok`
- Call-stack / chosen-variables parsing in `dump_detail` is a planned deep
  increment; v1 leaves those arrays empty
- The fingerprint ledger is best-effort and workstation-dated
  (`first_seen`/`last_seen` are local bookkeeping, not SAP timestamps); a
  ledger IO error never fails the reader

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
