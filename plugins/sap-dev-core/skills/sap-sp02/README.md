# SAP SP02 — Spool Download Skill

Download a SAP spool request to a local text file via transaction SP02
(Output Controller — own spool requests). Picks the spool by its
SAP-assigned `TSP01-RQIDENT` number, opens it with F2, presses Save
(`tbar[1]/btn[48]`), picks the export format, and writes to the local
path you specify.

## Skill Overview

1. Navigate to SP02 (your own spool requests).
2. Scan the list for the row whose spool-number column matches your
   target. Tick its checkbox.
3. F2 → Display contents.
4. Save (toolbar `btn[48]`) → format radio → directory + filename.
5. Verify the file exists on disk and report the byte count.

## Auto-Trigger Keywords

- `download spool`, `export spool`, `save spool to file`
- `dump SAP list to text file`, `SP02 download`

## Usage

```text
# Default — Unconverted plain text
/sap-sp02 397 C:\Temp\SP02_397.txt

# Spreadsheet (csv) format
/sap-sp02 397 C:\Temp\SP02_397.csv --format=csv

# Bypass the list scan, tick row 3 directly (matches the recording flow)
/sap-sp02 397 C:\Temp\SP02_397.txt --row=3
```

Conversational forms:

- "Download spool 397 to C:\Temp\."
- "Export SAP spool request 397 as CSV."
- "Save the latest spool to a text file."

## Prerequisites

- Active SAP GUI session (run `/sap-login` first).
- The target spool must belong to the logged-in user (or appear in the
  user's default SP02 selection). For other users' spools, switch to
  SP01 first.
- The local output directory must exist (skill or operator creates it
  before running).

## Limitations

- Own-user spools only — does not drive the SP02 selection screen.
- List-style spools only — binary spools (PDF / OTF / PS) need the
  matching format radio (`html` works for some; otherwise use SP01
  binary path).
- Format index mapping (`text=0` / `csv=1` / `rtf=2` / `html=3`)
  is verified on S/4HANA 1909; on other releases, re-record if a
  format radio path fails.
- The list scan defaults to column index `4` — pass `--col=<N>` if
  your SP02 list layout differs.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-09

## License

GPL-3.0 License - See LICENSE file in repository root.
