# SAP Transport Readiness Skill

Runs a **release gate** over an ABAP transport request — answers "is this
transport safe to release?" before it moves to QA / production — and rolls up
to GO / GO_WITH_WARNINGS / NO-GO with the evidence. Read-only: it NEVER
releases the TR; release stays a deliberate, separate `/sap-se01 release` step
the user takes after a GO. First of the delivery-assurance family, built on the
Phase-0 primitives (object resolver, finding model + gate policy, artifact
index).

## Skill Overview

1. Resolve the TR — an explicit number, or `--current` from the per-connection
   dev defaults
2. Optionally run the heavier sub-skills first so their verdicts fold into one
   unified result: `--run-atc` (`/sap-atc`) and `--include-unit-tests`
   (`/sap-run-abap-unit`). Verdicts are never invented — a sub-skill that was
   not run is reported as *not run*, not as passed
3. Run the RFC readiness engine (32-bit PowerShell, pinned profile): builds
   the object inventory from E071, then checks — unreleased child tasks,
   inactive objects, local/`$TMP` objects inside a transportable request, and
   a multi-package note
4. Gate every finding via the customer brief's Quality bar (§6); `--strict`
   promotes warnings to blockers
5. Report the verdict, blocking findings with remediations, warnings, and any
   `COULD_NOT_CHECK` areas (the honesty contract — those are never certified
   clean). Report files (Markdown report, findings TSV/JSON, object
   inventory) are registered for `/sap-evidence-pack <TR>`

Default gates: inactive object, unreleased child task, `$TMP`/local object in
transport → BLOCK; lock-by-other-user, dependency outside TR → WARN (BLOCK
under `--strict`); multi-package note → INFO; could-not-check → WARN, never a
silent pass.

## Auto-Trigger Keywords

- "is <TR> ready / safe to release?", `transport readiness <TR>`
- "release gate", "check the transport before QA"
- "can we import DEVK900123 to production?"

## Usage

```text
/sap-transport-readiness DEVK900123
/sap-transport-readiness --current
/sap-transport-readiness DEVK900123 --strict
/sap-transport-readiness DEVK900123 --run-atc --include-unit-tests
/sap-transport-readiness DEVK900123 --brief C:\path\to\customer_brief.md
```

Engine exit codes: `0` = GO / GO_WITH_WARNINGS · `1` = NO_GO · `2` = TR not
found / RFC failure.

## Prerequisites

- SAP profile saved via `/sap-login` (RFC password; the engine self-connects
  via the pinned profile)
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC — the engine runs under 32-bit
  PowerShell
- `Z_GENERIC_RFC_WRAPPER_TBL` is NOT required — all checks use
  `RFC_READ_TABLE`

## Key Reference Files

| File | Purpose |
|---|---|
| `references/sap_transport_readiness.ps1` | The RFC readiness engine — resolves the TR, builds the E071 inventory, runs the structural checks, applies the gate policy, writes + registers the reports |

The engine dot-sources the shared Phase-0 libraries
(`sap_object_resolver.ps1`, `sap_finding_lib.ps1`, `sap_gate_policy.ps1`,
`sap_artifact_lib.ps1`) from `sap-dev-core/shared/scripts/`.

## Limitations

- **Checks implemented (MVP):** TR existence/status, unreleased child tasks,
  object inventory, inactive objects, `$TMP`/local-in-transport,
  multi-package note, plus folded-in ATC / ABAP-Unit verdicts
- **Phase 2 (not yet):** object locks (ENQUEUE via the wrapper FM),
  dependency completeness, customizing-key client review (E071K),
  transport-sequence analysis, import simulation
- The inactive probe is name-based (DWINACTIV uses its own object-type
  codes); a denied read reports `COULD_NOT_CHECK` rather than guessing
- Read-only — this skill never modifies or releases anything in SAP

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
