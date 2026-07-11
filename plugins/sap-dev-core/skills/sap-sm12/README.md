# SAP SM12 — Enqueue Lock List & Safe Release

List and safely release SAP enqueue locks (transaction SM12) over RFC — no GUI.
Automates the risky part of the daily "clear a stuck lock" op: it **proves the
lock owner has no session on any application server** before it will touch the
lock, hard-refuses when that can't be proven, requires the operator to type the
owner's name, and leaves an audit trail. Safer than the manual SM12 delete, not
just faster.

## Skill Overview

- **`list`** (read-only) — `ENQUEUE_READ` dump with a computed lock **AGE** and a
  best-effort **owner-liveness** column (LIVE / GONE / UNKNOWN). Filter by user,
  table, lock argument, client, and age.
- **`release`** (destructive, gated) — re-read the target locks → **liveness
  gate** (owner absent on every app server: `TH_SERVER_LIST` + `TH_USER_LIST`,
  and `TH_SYSTEMWIDE_USER_LIST` on multi-instance systems) → show evidence →
  **typed confirmation** (type the owner's user name) → `ENQUE_DELETE` → verify
  by authoritative re-read → append an audit line. No `--force` exists.

## Auto-Trigger Keywords

- `stale lock`, `stuck enqueue lock`, `release SM12 lock`, `delete lock entry`
- `object is locked by user`, `lock entry held by`, `SM12`

## Usage

```text
# List my current locks with age + liveness
/sap-sm12 list --user=BDDEV

# All locks on a table older than 2 hours, save to TSV
/sap-sm12 list --table=MARA --older-than=2h --save-output=C:\Temp\locks.tsv

# Release a stale lock (liveness gate + typed confirm required)
/sap-sm12 release --user=BATCHUSER --table=VBAK
```

Conversational forms:

- "Show the enqueue locks held by BDDEV."
- "There's a stuck lock on VBAK from BATCHUSER — is the owner still logged on,
  and if not, release it."

## Prerequisites

- An RFC-capable connection profile — run `/sap-login` first.
- `release` also needs the generic wrapper `Z_GENERIC_RFC_WRAPPER_TBL` (deploy
  via `/sap-dev-init`) for the `ENQUE_DELETE` call and the multi-instance
  liveness leg. `list` works without it. Installs with a PRD-only profile get
  `list`; `release` refuses with a `/sap-dev-init` pointer.

## Safety

- The liveness gate refuses on a **live** owner *and* on any **unverifiable**
  result (a "couldn't check" is treated as unsafe — never released).
- `release` is destructive → **typed** confirmation (the owner's user name),
  shown only after the gate passes.
- Update-task-owned locks are refused in v1 (deleting one can corrupt an
  in-flight update — clear it in SM13 first).
- Every attempted release — including refusals — appends a line to
  `{log_dir}\sm12_release_audit.tsv`.

## Limitations

- RFC-only in v1 (no GUI fallback). On a system where `ENQUEUE_READ` is not
  remote-enabled, list locks via `/sap-rfc-wrapper fm ENQUEUE_READ`.
- The multi-instance liveness leg is verified against single-instance test
  systems (S/4HANA 1909, ECC 6); on a genuine multi-instance system the
  refuse-by-default posture keeps it fail-safe.
- Liveness is user-presence-based (owner has any session), matching the manual
  SM04 / AL08 check.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-11

## License

GPL-3.0 License — See LICENSE file in repository root.
