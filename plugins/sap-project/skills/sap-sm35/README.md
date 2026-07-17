# sap-sm35

**Batch-input (SM35) session operations, headless over RFC** — see every failed session and
its error volume without a screen-by-screen read. `list` and `triage` are read-only;
`process` is confirm-gated because it executes the queued transactions.

```
/sap-sm35 list [<SESSION>] [--status new|error|processed|inprocess|all]
          [--created-by U] [--from YYYYMMDD] [--to YYYYMMDD]
/sap-sm35 process <SESSION>
/sap-sm35 triage <SESSION>
```

## What it does

- **`list` enumerates sessions from APQI** (filter by name / status / creator / date,
  engine: `references/sap_sm35_list.ps1`), decodes QSTATE at runtime (DD07V), joins APQL for
  log presence, and reports the built-in APQI statistics — total vs errored transactions and
  error-message counts — as a table + `sm35_sessions.tsv`. An empty result is normal, never
  an error.
- **`process` runs a named session in background via RSBDCSUB**, delegated to
  `/sap-run-report` behind a single confirm gate that spells out state, creator, and
  transaction count — the queued transactions EXECUTE and may change data. It then
  poll-verifies APQI-QSTATE → `PROCESSED` / `PROCESSED_WITH_ERRORS` / `STILL_RUNNING` /
  `SM35_PROCESS_TIMEOUT` (default wait 300 s).
- **`triage` builds a per-session error summary** + AI narrative from the APQI stats into
  `sm35_triage_<G>.md` (any errored transactions → a HIGH `bdc-error-cluster` finding), and
  registers everything (scope `BDC_<GROUPID>`) for `/sap-evidence-pack`.

## Honest by construction

The message-level log is **not cleanly RFC-readable** — a verified build-time finding:
BDC_OBJECT_READ returns dynpro content, not messages, and the TemSe RSTS chain is non-RFC /
absent on ECC. So the session-level error signal comes from the verified APQI statistics, and
deep MSGID/MSGNO clustering needs the SM35 GUI log scrape — **that VBS is not yet shipped**
(to-be-recorded: the skill emits `NEEDS_RECORDING`; capture it once with `/sap-gui-probe
--record`; deep clustering is v1.5). When neither stats nor a readable log is available,
triage is `COULD_NOT_CHECK` — never an empty-but-green triage.

## Reads

`APQI` (sessions + statistics), `APQL` (log presence), `DD07V` (QSTATE labels) — pure
RFC_READ_TABLE (FMODE=R), single code path ECC6 + S/4 (SAPMSBDC_CC on both). `--max` (default
100) + date filters cap the read; only DATATYP='BDC' queues are listed. v1.5: GUI log scrape
+ message-level clustering; `rerun` (corrected re-run file from a /sap-call-bdc source). v2:
`purge` via RSBDCREO (typed-confirm mass delete).

Read-only except the confirm-gated `process` delegation; no new Z objects, no SQL writes
(mutations happen only inside RSBDCSUB). Prerequisites: pinned /sap-login RFC profile; NCo
3.1 (32-bit); a live GUI session only for the GUI log fallback + the /sap-run-report
execution. Live-verified on S/4HANA 1909 (S4D); EC2 (ECC 6) probed in-plan, release-agnostic
code path.
