# Golden-screen baselines

> Architectural contract for screen-fingerprint baselines. Read this before
> authoring a `*.screens.json`. Lives under `contributing/` (repo authors only —
> not shipped to end users). Enforced by the coverage gate in
> `scripts/check-consistency.mjs`.

## Why

Nearly every recurring false-success bug in this repo is the same class: a SAP
release/patch/locale moved a control ID or changed a screen identity, the
driving VBS silently mis-stepped, and a heuristic accepted the result as
SUCCESS (see `feedback_sap_se38_success_misreport`,
`feedback_sap_se38_syntax_check_locale_bound`). The RFC PROGDIR / DWINACTIV
post-deploy verify catches "did the write land?" *after* a run, per object. A
**golden-screen baseline** catches "will the write path even execute?"
*before* runs, per release, across every driving skill — by asserting the exact
control IDs and screen identity each VBS depends on, and failing loudly at the
first missing control instead of accepting a drifted screen.

This is the **static half** of the GUI-robustness harness. The **live half**,
`/sap-gui-screen-check`, replays these baselines against a target release and
reports drift as BLOCKER findings.

## The two halves

1. **Static CI coverage gate** — `scripts/check-consistency.mjs`. For every
   operational SAP-driving `.vbs` under `skills/<skill>/references/` (detected by
   a `GetObject("SAPGUI")` / `GetScriptingEngine` reference, minus the
   `TIER3_EXEMPT_VBS` bootstrap set), it expects a sibling
   `<stem>.screens.json`:
   - **missing** baseline → informational `WARN` (a ratcheting coverage metric,
     `screen-baseline coverage N/M`). Does **not** break the build — pre-existing
     un-baselined VBS are debt, not regressions. Promote to a hard error once
     coverage reaches 100%.
   - **malformed** baseline → **hard error** (fails CI). Safe, because it only
     fires on a baseline that was actually authored.
2. **Live validation skill** — `/sap-gui-screen-check` (built). A PowerShell
   orchestrator (`references/sap_screen_check.ps1`) reads the baselines and, per
   checkpoint, drives the read-only probe (`references/sap_screen_check_probe.vbs`)
   to navigate via `reach.okcode`, read the live screen identity (program +
   dynpro), and test every `required_id` with `findById`. Missing control or
   identity mismatch on a `captured` checkpoint → BLOCKER DRIFT. On a
   `pending_live` checkpoint it emits a `CAPTURE:` line; with `--update-baseline`
   the SKILL.md applies it (identity + `status: captured`). (v1: OK-code
   checkpoints only; new-control INFO diff is future.)

## Schema (`sapdev.screenbaseline/1`)

One baseline per driving VBS, named `<vbs-stem>.screens.json`, beside the VBS in
`references/`.

```json
{
  "schema": "sapdev.screenbaseline/1",
  "vbs": "sap_se38_create.vbs",
  "captured_on": {
    "release": "S/4HANA 1909",
    "kernel": "754",
    "date": "2026-06-03",
    "method": "live"
  },
  "checkpoints": [
    {
      "id": "initial",
      "reach": { "okcode": "/nSE38" },
      "identity": { "program": "SAPMS38M", "dynpro": "1010" },
      "required_ids": [
        "wnd[0]/tbar[0]/okcd",
        "wnd[0]/usr/ctxtRS38M-PROGRAMM",
        "wnd[0]/usr/radRS38M-FUNC_EDIT",
        "wnd[0]/usr/btnNEW"
      ],
      "status": "captured"
    }
  ]
}
```

### Fields

| Field | Required | Notes |
|---|---|---|
| `schema` | yes | Must equal `sapdev.screenbaseline/1`. |
| `vbs` | yes | Must equal the paired template filename (`<stem>.vbs`). |
| `captured_on` | yes | Object. `release` / `kernel` / `date` / `method`. **Load-bearing**: fingerprints are release-bound — drift is reported *relative to this release*. `method` ∈ `live` (captured from a system) \| `static` (dependency set extracted from the VBS source, identity not yet captured). |
| `checkpoints[]` | yes | Non-empty. One entry per distinct screen the VBS depends on. Start shallow (just `initial`), deepen over time. |
| `checkpoints[].id` | yes | Stable short name (`initial`, `attributes`, `editor`, `tr_popup`, …). |
| `checkpoints[].reach` | recommended | How `/sap-gui-screen-check` navigates to this state (`{ "okcode": "/nSE38" }`, or a step recipe). Cheapest checkpoints (initial screens) need no data. |
| `checkpoints[].identity` | yes | `{ program, dynpro }` of the screen. May be empty strings **only** when `status` is `pending_live`. |
| `checkpoints[].required_ids[]` | yes | The `findById` control paths the VBS depends on at this checkpoint. Language-stable (IDs + DDIC field names, never `.Text`) per `shared/rules/language_independence_rules.md`. Non-empty unless `status` is `pending_live`. |
| `checkpoints[].status` | yes | `captured` (identity + ids verified on a live system) \| `pending_live` (static seed — identity to be captured on first `/sap-gui-screen-check` run). |

## Authoring a baseline

1. **Extract the dependency set** by reading the VBS and listing the
   `findById("...")` control paths used at each screen — partition by screen
   boundary (a navigating `sendVKey` / button press that moves off the current
   dynpro starts a new checkpoint). Dynamically-built IDs (string concatenation)
   can't be statically partitioned — capture those live.
   - This is read-only static analysis of our own templates — **not** the
     automated skill-refactoring forbidden by CLAUDE.md Directive 2.
2. **Seed `method: static`, `status: pending_live`** with empty `identity` if you
   are not capturing live yet. The gate accepts this; the live skill fills it in.
3. **Capture `identity` live** (when you have a session) with
   `/sap-gui-probe` or `sap_gui_object_details.vbs` at that screen, set
   `method: live` + `status: captured`, and record `release` / `kernel`.
4. **Pilot shallow first.** The `initial` screen of each transaction is the
   cheapest, needs no test data, and already catches a large share of release
   drift. Deepen to `attributes` / `editor` / popups afterwards.

## Seeded baselines

Coverage **120/121** (2026-07-03 seeding wave; the only gap is
`sap_stms_import.vbs`, deliberately unbaselined until its PLACEHOLDER control
IDs are calibrated via `/sap-gui-record` — a baseline would freeze placeholder
text). Every driving VBS now ships a multi-checkpoint seed: `method: static`,
`status: pending_live`, the required-control set extracted per checkpoint from
the VBS's literal `findById` paths (dynamic/concatenated IDs excluded — capture
live), popups as their own checkpoints. Live `identity` is captured and
promoted per checkpoint by `/sap-gui-screen-check --update-baseline`
(v1 captures OK-code-reachable checkpoints; deeper `note`-reach checkpoints
stay `pending_live` until the probe learns step recipes).

Seeding conventions established by the wave (follow these for new baselines):
- Bare window containers (`wnd[0]`, `wnd[1]`, `wnd[0]/usr`) are omitted;
  `wnd[0]/tbar[0]/okcd` only in `initial`; `wnd[0]/sbar` only at its
  first-read checkpoint.
- **Never seed an ABSENCE probe as required** — delete-verify screens and
  "no-usages" popups probe IDs whose absence is the success signal; seeding
  them would manufacture false DRIFT (see `sap_se37_delete.screens.json`
  verify checkpoint's note, and `sap_where_used_list`'s no_usages_popup).
- Either/or release alternatives (e.g. mm01's 1909 vs ECC6 view popup) get
  separate checkpoints per release, never one merged required set.
- Popup chains handled by the shared `sap_delete_popups.vbs` walker have no
  per-VBS literals — such baselines legitimately carry an empty-`required_ids`
  popup checkpoint or none at all.

## Promotion to a hard gate

When `screen-baseline coverage` reaches `M/M`, change the missing-baseline branch
in `check-consistency.mjs` from a `baselineWarnings.push(...)` to an
`errors.push(...)` so a new driving VBS cannot ship without a baseline (the same
fail-closed stance the Tier-3 attach gate already takes).
