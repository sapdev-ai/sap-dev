# sap-vofm

**Diagnose SD condition-technique VOFM routines without the "routine not found at
runtime" guesswork.** A VOFM routine is a three-part trap: the body lives in a
*generated* include, it only runs after **RV80HGEN** rewires the frame include, and the
TFRM/TFRMT registry + include don't travel together in a transport. This proves all
three over RFC — every verdict is an authoritative re-read, never trusted screen text.

```
/sap-vofm list  pricing-req [--customer-only]     # enumerate a group + registration state
/sap-vofm check pricing-req 902 [--tr <TRKORR>]   # prove one routine end-to-end -> GO/NO_GO
/sap-vofm explain cond-value 901                  # read the include source + narrate
```

`type` ∈ `pricing-req` (PBED), `cond-base` (PFRA), `cond-value` (PFRM) — the verified
pricing groups.

## What `check` proves (all RFC, no screen text)

| Signal | Source |
|---|---|
| Routine is registered | `TFRM` row (GRPZE+GRPNO) |
| Include exists + active | `PROGDIR` (STATE='A') via layered name probe (customer `RV61A###` → standard `LV61A###`/`FV61A###`) |
| No pending inactive version | `DWINACTIV` |
| **RV80HGEN wired it in** | frame include (`RV61ANNN`…) source scanned for `INCLUDE <name>` |
| Transport is complete | `E071` (include) + `E071K` (TFRM/TFRMT keys) on the TR — detect-only |

The headline finding is **`registered=N`**: a customer routine (≥600) present in TFRM
but absent from the frame include — RV80HGEN never wired it in (or it's deactivated),
the classic runtime "routine not found". `registered=STD` marks a standard SAP routine
(frame membership N/A); a frame-read failure is `registered=?` → `COULD_NOT_CHECK`,
never a false pass.

## Honest by construction

`NOT_FOUND` (no TFRM row) is distinct from a finding. Unverified VOFM groups
(`copy-req-order` and the billing/delivery/output families) ship flagged `verified=NO`
and are **refused with the valid list** — copy-requirements use a two-level frame
(`FV45CNNN` → nested `RV45CNNN`) with an unverified customer prefix, so they need a live
`/sap-gui-probe` pass first (v1.5), never a guess.

## Scope

Read-only (`list`/`check`/`explain`) is shipped. **`create`/`update`/`regen`** (VOFM
GUI registration + body deploy via `/sap-se38` + `RV80HGEN` via `/sap-run-report` +
post-write verify) are **NEEDS_RECORDING** — they require a `/sap-gui-probe --record`
capture on both releases and are deferred to a dedicated session.

Dual-verified live 2026-07-11 on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) — the read
stack is identical on both, and the ERP scan surfaced a real registration gap
(PBED/983 in TFRM but not in the RV61ANNN frame). Part of the sap-dev-core plugin.
