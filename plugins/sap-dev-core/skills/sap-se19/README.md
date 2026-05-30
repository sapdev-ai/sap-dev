# SAP SE19 BAdI Implementation Lifecycle Skill

Full lifecycle for SAP **BAdI implementations** via transaction **SE19 (BAdI
Builder)** using SAP GUI Scripting — for **both Classic and New (Enhancement
Framework) BAdIs**.

## What it does

| Operation | New BAdI | Classic BAdI |
|---|---|---|
| **Create** | Enhancement Implementation + BAdI Implementation + implementing class (you name the class) | Implementation (class auto-named `ZCL_IM_<impl>`) |
| **Display** | open read-only | open read-only |
| **Update** | class source → `/sap-se24`; runtime → activate/deactivate; package → `/sap-change-package` | same |
| **Activate** | activate the enhancement implementation + runtime flag on | toolbar Activate (Ctrl+F3) |
| **Deactivate** | runtime "Implementation is active" off + re-activate | toolbar Deactivate (Ctrl+F4) |
| **Delete** | remove enhancement impl (class survives → optional `/sap-se24` cleanup) | remove impl (+ optional class) |

### Key behaviours

- **Auto type-detection (RFC).** `references/sap_se19_classify.ps1` classifies a
  name as Classic vs New and Definition vs Implementation by reading `SXS_ATTR`,
  `SXC_CLASS`/`SXC_ATTR`, `BADI_IMPL`, and `TADIR`.
- **Ambiguity handling.** *Migrated* BAdIs (e.g. `MB_MIGO_BADI`,
  `ME_PROCESS_PO_CUST`) exist in both worlds — the skill asks the user which to
  use.
- **Definition vs Implementation input.** `create` takes a BAdI **definition /
  enhancement-spot** name; every other operation takes a BAdI **implementation**
  name.
- **Delegation.** Implementing-class work → `/sap-se24` (Rule #4); package moves →
  `/sap-change-package` (Rule #5); transport request → `/sap-transport-request`.
- **Safety (Rule #6).** Never deletes a BAdI definition, and never deletes an
  implementation it did not create this session (session ledger + `TADIR` author
  check; explicit user override required otherwise).
- **Language-independent VBS** (component ID + `MessageType`, no title branching)
  and parallel-safe session attach.

## Auto-Trigger Keywords

SE19, BAdI Builder, BAdI implementation, Business Add-In, Classic BAdI, New BAdI,
Enhancement Framework, Enhancement Implementation, Enhancement Spot, BAdI
definition, implementing class, activate/deactivate BAdI, delete BAdI
implementation, `ME_PROCESS_PO_CUST`, `MB_MIGO_BADI`, `WORKBREAKDOWN_UPDATE`.

## Directory Structure

```
sap-se19/
├── SKILL.md
├── README.md
└── references/
    ├── sap_se19_classify.ps1          # RFC: Classic-vs-New, Definition-vs-Implementation
    ├── sap_se19_new_create.vbs        # New BAdI: create enh-impl + BAdI-impl + class
    ├── sap_se19_new_display.vbs       # New BAdI: display
    ├── sap_se19_new_setactive.vbs     # New BAdI: activate / deactivate (runtime flag)
    ├── sap_se19_new_delete.vbs        # New BAdI: delete (class survives)
    ├── sap_se19_classic_create.vbs    # Classic BAdI: create (class auto-named)
    ├── sap_se19_classic_display.vbs   # Classic BAdI: display
    ├── sap_se19_classic_setactive.vbs # Classic BAdI: activate / deactivate
    └── sap_se19_classic_delete.vbs    # Classic BAdI: delete (+ optional class)
```

## Usage

- "create BAdI implementation for `ME_PROCESS_PO_CUST`" → asks Classic/New (migrated), then creates
- "create classic BAdI implementation `Z_HK_WBS_01` for `WORKBREAKDOWN_UPDATE`"
- "display `ZHK_BADI_PO_007`"
- "deactivate `ZHK_BADI_PO_007`" / "activate `ZHK_BADI_PO_007`"
- "update the implementing class of `ZHK_BADI_PO_007`" → delegates to `/sap-se24`
- "delete `Z_HK_IM_PO_01`" → safety-checked (must be created by this session)

## Prerequisites

- SAP GUI for Windows installed, SAP GUI Scripting enabled (client + server)
- Active SAP GUI session (`/sap-login` first)
- SAP NCo 3.1 (32-bit) for the RFC classifier
- Authorization for SE19, SE24, and object activation

## Probed against

S/4HANA 1909 (S4D), SAP GUI 7.60, EN logon — 2026-05-30. Re-record screen IDs with
`/sap-gui-record` if a different release renumbers a tree/menu node.

## License

GPL-3.0 — see LICENSE in the repository root.
