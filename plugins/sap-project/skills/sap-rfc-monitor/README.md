# sap-rfc-monitor

Diagnose **stuck tRFC / qRFC interface queues** and audit the **SM59 RFC
destination register** — read-only over RFC (no GUI, no Z-object, no dev-init).

```
/sap-rfc-monitor queues       [--dir=trfc|in|out|all] [--dest=D] [--queue=Q] [--top=N] [--save-output PATH]
/sap-rfc-monitor destinations [--type=3|G|H|T|I|L] [--max=N] [--save-output PATH]
/sap-rfc-monitor retry        --dest=D          # tRFC only; confirm-gated
```

## What it does

- **`queues`** — snapshots tRFC (SM58) + inbound/outbound qRFC (SMQ2/SMQ1). Depth
  comes **server-side** from the queue-inspection FMs (`TRFC_QIN/QOUT_GET_CURRENT_QUEUES`)
  — never a table scan — with per-queue state, age, head-blocker error text, and
  the inbound-scheduler registration flag (`QIWKTAB`). Claude clusters the failed
  LUWs by root cause — **target down / auth / data / not-registered** — with one
  recommended action each. One `SYSFAIL` head-blocker stalls everything queued
  behind it; this shows the whole picture at once.
- **`destinations`** — parses `RFCDES` into an auditable register: type, target
  host, logon user, **trust** flag (`l=X`), and **stored-credential presence**
  flag (the `v=` marker) — plus the `RFCSYSACL` trusted-system ACL and an AI risk
  column.
- **`retry`** — re-drives failed tRFC LUWs for one destination via **RSARFCEX**
  (confirm-gated, delegated to `/sap-run-report`), then **authoritatively re-reads**
  the queue to verify CLEARED / REDUCED / UNCHANGED — never the report's own
  status text.

## Two hard security rules

- **RFCDESSECU is never read.** Stored credentials are detected only as the
  *presence* of the `v=` password marker in `RFCOPTIONS` — a flag, never a value.
  The raw options blob is never echoed. No password can leave the skill.
- **LUW / queue deletion and unlock are refused** — manual SM58 / SMQ1 / SMQ2
  only. RSARFCSE's delete flag is never set.

## Reads

`TRFC_QIN_GET_CURRENT_QUEUES` / `TRFC_QOUT_GET_CURRENT_QUEUES` (server-side depth),
`TRFC_GET_QIN_INFO_DETAILS` (head LUWs), `ARFCSSTATE` / `TRFCQSTATE` (tRFC state),
`QIWKTAB` (registration), `RFCDES` / `RFCDOC` / `RFCSYSACL` (register + trust ACL).
All FMODE=R / TRANSP, probed identical on both releases.

Complements `/sap-diagnose`'s lightweight `smq` interface triage (Wave-0 T1-B) as
the standalone deep-dive (destinations register, retry, richer clustering).
Read-only for `queues` / `destinations`; the only write is RSARFCEX (`retry`),
confirm-gated. Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) — one code path.
