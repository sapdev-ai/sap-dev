# sap-version-history

Read the SAP ABAP **version store** over RFC (no GUI) — the same-system *time*
axis that complements `/sap-compare`'s cross-system axis. Answers "who changed
this program/FM, when, under which transport, and what exactly changed."

## Modes

| Command | What you get |
|---|---|
| `/sap-version-history list <OBJECT> [--type=program\|include\|fm] [--max=20]` | Version directory: VERSNO, author, date/time, transport + TR status, released flag, the active version, and the last-released version. |
| `/sap-version-history diff <OBJECT> [<A> <B>] [--no-annotate]` | Unified line diff of two stored versions (default: the newest two), plus an AI change summary (intent + risk flags). |
| `/sap-version-history blame <OBJECT> [--window=10]` | Per-line attribution — which version / author / transport introduced each line; lines older than the window are marked honestly. |
| `/sap-version-history restore <OBJECT> <VERSNO>` | Phase 2 (confirm-gated; delegates the deploy to `/sap-se38` / `/sap-se37`). Not in v1. |

Object kinds in v1: **programs, includes, function modules**. Classes/interfaces
are v2.

## How it works

- **RFC only** (SAP NCo 3.1, 32-bit PowerShell) — no GUI, no session, no
  dev-init. Just a pinned RFC profile from `/sap-login`.
- Version directory via `SVRS_GET_VERSION_DIRECTORY_46` (TR status joined from
  `E070`); version source via `SVRS_GET_REPS_FROM_OBJECT`; identity via the shared
  object resolver. The diff and blame engines are pure-local (LCS).
- **Read-only** — nothing is written to SAP. Outputs register for
  `/sap-evidence-pack`.

## Honest edges

- A freshly built object may have **no versions** (they're written on
  release/generation) — reported as `VH_NO_VERSIONS`, not an error.
- Consecutive versions are often **byte-identical** (re-released without a source
  change) — `diff` says `identical` plainly.
- On a system that received objects by import, a version's transport may not be
  in the local `E070` — TR status shows `UNKNOWN`, never a false "released".

Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) — one code path, no
release variants.
