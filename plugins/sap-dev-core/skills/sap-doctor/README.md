# SAP Environment Doctor Skill

Read-only environment preflight ("doctor") for the sap-dev toolchain — think
`brew doctor` / `flutter doctor`. Diagnoses why skills would fail BEFORE they
run, emits one `CHECK:` line per probe plus an overall verdict (READY /
DEGRADED / BLOCKED), and gives every failure a copy-pasteable FIX. The
default run is pure read-only and fast, so other skills can safely chain it
as a pre-flight.

## Skill Overview

Six default check groups:

1. **gui** — SAP GUI + scripting reachability (`LOGGED_IN` is the
   authoritative proof that client AND server scripting work end-to-end)
2. **cfg** — 32-bit PowerShell, SAP NCo 3.1 in GAC, `work_dir` env/writability,
   `connections.json` present and valid
3. **rfc** — pinned-profile RFC connectivity (`RFC_PING`)
4. **srv** — client modifiability (T000 client option)
5. **devenv** — the `/sap-dev-init` artefacts, folded in from `/sap-dev-status`
   (skipped with `--no-devenv`, or when RFC is already down)
6. **auth** — the pinned user's authorizations vs. the required set
   (`SUSR_USER_AUTH_FOR_OBJ_GET` against `required_authorizations.tsv`); an
   auth FAIL DEGRADES the verdict, never BLOCKS

A probe that can't run reports **SKIP, never a false PASS**. Verdict rules:
any FAIL → BLOCKED; any WARN/SKIP → DEGRADED; all PASS → READY.

**Opt-in seventh group `--screens`** replays the golden-screen baselines
(`references/<stem>.screens.json` across all skills) against the live system
to catch control-ID / screen-identity drift before a GUI skill mis-steps.
Unlike the default groups it **navigates the live session** (OK-code), so it
is off by default and guarded: if the current screen is not an idle screen,
the skill stops and asks before proceeding. This group absorbed the former
`/sap-gui-screen-check` skill.

## Auto-Trigger Keywords

- `sap doctor`, `check my sap environment`, `preflight`
- "why do my sap skills keep failing", "is my setup ready"
- `screen check`, `check for screen drift`

## Usage

```text
/sap-doctor
/sap-doctor --quiet
/sap-doctor --no-devenv
/sap-doctor --screens
/sap-doctor --screens sap_se38_create
/sap-doctor --screens --update-baseline
```

`--quiet` collapses PASS rows. `--update-baseline` (with `--screens`)
promotes `pending_live` baseline checkpoints using the live capture — the
baseline files are edited manually and re-validated, never auto-written.

Exit-code contract (for auto-invocation): `0` = READY or DEGRADED,
`1` = BLOCKED.

## Prerequisites

- SAP GUI installed (gui group); an active session for a full `LOGGED_IN` PASS
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC for the rfc / srv / auth / devenv groups
- A pinned connection profile (`/sap-login`) for the RFC-based groups

## Directory Structure

```
sap-doctor/
├── SKILL.md
├── README.md
└── references/
    ├── sap_doctor_checks.ps1        # cfg + rfc + srv checks (filled + run in 32-bit PS)
    ├── sap_doctor_authz_probe.ps1   # auth group — SUSR_USER_AUTH_FOR_OBJ_GET probe
    ├── sap_screen_check.ps1         # screens group orchestrator (--screens)
    └── sap_screen_check_probe.vbs   # read-only navigate + identity + ID-presence probe
```

## Limitations

- **`CLIENT_MODIFIABLE` reads the client option (T000), not the system-global
  change option (SE06)** — a globally locked system can still pass the client
  check and then fail at activation.
- **`CONNECTIONS` is shallow in v1** — file exists + valid JSON; the pinned
  profile's resolve path is covered empirically by `RFC_PING`.
- **The auth group reads *assigned* authorizations, not a live
  AUTHORITY-CHECK** — a PASS means "has the core grant", not "can never be
  denied"; after a runtime denial, SU53 remains the authoritative cut.
- **`--fix` is not implemented in v1** — all remediations are reported as FIX
  strings; nothing is changed automatically.
- **`--screens` navigates the live session** — never part of the default run;
  a DRIFT result BLOCKS and recommends re-recording the affected VBS via
  `/sap-gui-probe --record`.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
