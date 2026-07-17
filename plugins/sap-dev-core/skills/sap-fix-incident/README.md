# SAP Fix Incident Skill

Closes the loop from a `/sap-diagnose` root cause to a **deployed,
test-verified fix** — conservatively and test-first. It is the **gated,
write-capable companion to the read-only `/sap-diagnose`**: diagnose finds the
root cause and writes nothing; this skill takes a custom-code-defect
hypothesis, reproduces it as a RED ABAP Unit test, applies a minimal patch,
deploys it to a modifiable DEV system behind a transport, and proves the test
GREEN. A fix is only reported `FIXED` on an observed RED→GREEN transition.

`/sap-diagnose --fix` is the intended entry sugar — it presents hypotheses,
then chains here on a custom-code-defect top hypothesis; diagnose itself stays
read-only.

## Skill Overview

1. Load the incident: `--incident <diagnose.json>` (preferred), `--dump <KEY>`
   (runs `/sap-st22 --deep` itself), or a direct `<type> <name>` target; pick
   the hypothesis (`--hypothesis N`, default rank 1)
2. Route away non-code categories — `config-missing` / `data-defect` get
   read-only pointers; `lock-contention` (SM12) and `stuck-update` (SM13) are
   **manual** remediation, never automated
3. Acquire the failing source context: dump detail, object identity
   (`Resolve-SapObject`), comprehension map (`/sap-explain-object`)
4. **Guard rails (hard stops)** — see Safety Gates below
5. Reproduce the defect as a RED test (`/sap-gen-abap-unit` +
   `/sap-run-abap-unit`); `COULD_NOT_REPRODUCE` forces PROPOSE-only
6. Patch offline (minimal edit, no opportunistic refactor), re-check with
   `/sap-check-abap`, build a unified diff
7. **Confirm gate (Rule 2)**: default is PROPOSE the diff and wait for an
   explicit "yes"; deploy via `/sap-se38` / `/sap-se37` / `/sap-se24` +
   `/sap-activate-object` behind a `/sap-transport-request` TR
8. Verify GREEN (`/sap-run-abap-unit --with-coverage`, optional `/sap-atc`),
   register artifacts, and hand off the transport chain — this skill releases
   nothing and imports nothing

## Safety Gates

- **Custom code only.** A root cause in SAP standard (not `Z*/Y*`) is a hard
  STOP — analysis only ("SAP Note / enhancement matter"), never a patch.
- **DEV only, behind a transport.** A production / non-modifiable incident
  system is re-routed to DEV (`--dev-connection`); the change reaches the
  incident system later via transport, never by a direct write.
- **No guess-patching.** LOW-confidence hypotheses, or no failing line and no
  clear defect, STOP with a request for a tighter `/sap-diagnose` anchor.
- **Propose-and-confirm by default.** `--apply` skips the confirmation only
  for a `Z*/Y*` object on a modifiable DEV system — never for standard objects
  or non-DEV targets.
- **Never auto-release, never auto-import.** The handoff prints the deliberate
  chain: `/sap-transport-readiness` → `/sap-se01 release` → `/sap-stms`.
- **Bounded loop.** If GREEN is not reached within `--max-rounds` (default 2),
  the skill stops honestly with `MANUAL_REVIEW` and the best diff.

## Auto-Trigger Keywords

- `fix the incident`, `fix this dump`, `fix the root cause`
- `apply the fix diagnose found`, `patch the failing FM`

## Usage

```text
/sap-fix-incident --incident {out}\diagnose.json
/sap-fix-incident --incident {out}\diagnose.json --hypothesis 2
/sap-fix-incident --dump <yyyymmdd+hhmmss+program>
/sap-fix-incident FM Z_HK_POST
/sap-fix-incident --incident {out}\diagnose.json --apply --max-rounds 2
```

Conversational forms:

- "Fix the incident /sap-diagnose just root-caused"
- "That dump in ZHKR001 — reproduce it and fix it in DEV"

## Prerequisites

- A `/sap-diagnose` deliverable JSON or a dump key (or a direct object target)
- Pinned DEV `/sap-login` profile + active SAP GUI session
- SAP NCo 3.1 (32-bit, .NET 4.0) in GAC for the RFC legs

## Directory Structure

```text
sap-fix-incident/
└── SKILL.md      # Skill definition (single source of truth)
```

No `references/` scripts of its own — the acquire / test / deploy / activate /
verify half is orchestrated skills-first (`/sap-st22`, `/sap-explain-object`,
`/sap-gen-abap-unit`, `/sap-run-abap-unit`, `/sap-check-abap`, `/sap-se38`,
`/sap-se37`, `/sap-se24`, `/sap-activate-object`, `/sap-transport-request`,
`/sap-transport-readiness`, `/sap-se01`, `/sap-stms`).

## Limitations

- The patch is reasoned, not guaranteed correct on the first round — that is
  why the reproduce-then-verify loop and `--max-rounds` exist; anything short
  of RED→GREEN stays `PROPOSED` / `MANUAL_REVIEW`.
- Single root cause per invocation — re-invoke per distinct hypothesis.
- `--no-test` skips the reproduce/verify loop and downgrades the result to
  PROPOSE-only (discouraged).
- Depends on `/sap-st22 --deep` calibration for the failing line on
  HTML-rendered dumps; without a line the skill stays PROPOSE-only when the
  line is essential.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
