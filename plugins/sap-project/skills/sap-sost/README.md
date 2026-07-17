# sap-sost

**SAPconnect outbound-queue triage (SOST/SCOT) over RFC** — the step past where application
output diagnosis stops: cluster the failures, trace one message's timeline, and check whether
the SAPconnect pipe itself is healthy. v1 is entirely read-only.

```
/sap-sost list [--status error|wait|sent|all] [--type INT|FAX|PAG] [--from YYYYMMDD] [--cluster]
/sap-sost trace --recipient <addr>
/sap-sost config-check
```

## What it does

- **`list` snapshots the SOST status log** filtered by date / transmission method (INT/FAX/
  PAG) / status → `queue_snapshot.tsv`; with `--cluster` it groups failures by (MSGID, MSGNO)
  with the T100 error text into top root causes ("N messages failed with <text>").
- **`trace` shows a per-message status timeline** (created → attempts → final), grouped by
  the SOST object id (`--recipient <addr>` or `--sender U`). Zero matches → the
  `NOT_IN_SAPCONNECT` verdict: the message never reached SAPconnect — back to the app layer
  / `/sap-output-diagnose`.
- **`config-check` validates the SCOT pipe read-only:** SAPconnect nodes (SXNODES active),
  the RSCONN01 send job (TBTCP→TBTCO), stuck-queue age — each a tri-state check rolled up to
  GO / GO_WITH_WARNINGS / NO_GO, designed to be pulled into `/sap-health-check` and
  `/sap-refresh-verify`. The classic "node up, nothing sends" pattern (no send job + a stuck
  queue) is surfaced explicitly.
- **Registers** snapshots, clusters, traces, and check results (scope `SYS_<SID>`) for
  `/sap-evidence-pack`.

## Honest by construction

A table that fails to read is COULD_NOT_CHECK, never a silent pass. Recipient matching in
`trace` is best-effort on the MSGV message variables (the exact recipient address lives in
SOOS/address objects — a v1.5 join). **`resend` has no RFC path** (the resend FMs exist on
neither release, probed): it is planned as a v1.5 confirm-gated GUI drive of SOST verified by
an authoritative re-read, with typed confirmation for >25 messages or a production client —
the VBS (`sap_sost_resend.vbs`) is **not yet shipped** (to-be-recorded: the skill emits
`NEEDS_RECORDING`; capture it once with `/sap-gui-probe --record`).

## Reads

`SOST` (a real transparent status-log table on both releases — one row per send-attempt
carrying MSGID/MSGTY/MSGNO/MSGV1-4; status maps to MSGTY: E,A=error, W=wait, S,I=sent),
`SXNODES`, `TBTCP`/`TBTCO`, `T100` — driven by `references/sap_sost_read.ps1`, pure
RFC_READ_TABLE, single code path ECC6 + S/4 (SAPLSBCS_OUT on both). SOST grows unbounded, so
a default 7-day window + `--max` cap (500) + narrow field lists bound the read. v1.5: resend
GUI capture; `trace --body` (SO_DOCUMENT_READ_API1). v2: BCST_SR (BCS) linkage; SOSG
auth-scoped variant; health-snapshot diffing.

Read-only; no wrapper FM, no dev-init, no Z objects. Prerequisites: pinned /sap-login RFC
profile; NCo 3.1 (32-bit). Live-verified on S/4HANA 1909 (S4D): `list --cluster` grouped 11
XS-816 failures into one T100 root cause, and `config-check` returned a coherent NO_GO — SMTP
node active, no RSCONN01 send job scheduled, 17 error/wait messages stuck.
