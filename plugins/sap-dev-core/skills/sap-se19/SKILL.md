---
name: sap-se19
description: |
  Full lifecycle for SAP BAdI implementations via SE19 (BAdI Builder) using SAP
  GUI Scripting: Create, Update, Display, Delete, Activate, and Deactivate — for
  BOTH Classic BAdIs (SXS_ATTR / SXC_*) and New BAdIs (Enhancement Framework /
  BADI_IMPL). Auto-detects the BAdI type via RFC (SXS_ATTR-EXIT_NAME for Classic,
  BADI_IMPL-BADI_NAME for New); asks the user when a migrated BAdI is genuinely
  ambiguous (e.g. MB_MIGO_BADI, ME_PROCESS_PO_CUST). For Create the user supplies
  a BAdI DEFINITION / enhancement-spot name; for all other operations the user
  supplies a BAdI IMPLEMENTATION name. Implementing-class work (method source,
  class create/activate) is delegated to /sap-se24; package reassignment is
  delegated to /sap-change-package. NEVER deletes a BAdI definition or any
  implementation it did not create.
  Prerequisites: Active SAP GUI session (use /sap-login first). SAP NCo 3.1
  (32-bit) for the RFC type-detection step.
argument-hint: "<operation> <name>  e.g. 'create ME_PROCESS_PO_CUST', 'display ZHK_BADI_PO_007', 'deactivate ZHK_BADI_PO_007', 'delete <impl>'"
---

# SAP SE19 BAdI Implementation Lifecycle Skill

You drive transaction **SE19 (BAdI Builder)** to manage the full lifecycle of a
BAdI **implementation** — Create / Update / Display / Delete / Activate /
Deactivate — for both **Classic** and **New** (Enhancement Framework) BAdIs.

Two facts decide everything:

1. **Operation** — `create` takes a BAdI **definition / enhancement-spot** name;
   every other operation takes a BAdI **implementation** name.
2. **BAdI type** — Classic vs New, decided automatically by an RFC classifier
   (`references/sap_se19_classify.ps1`). If a name is genuinely ambiguous
   (a *migrated* BAdI that lives in both worlds), you ASK the user.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules (no unsolicited deploy; no raw SQL writes on SAP tables) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/tr_resolution.md` | TR resolution — this skill delegates to `/sap-transport-request`; never prompt for a TR directly |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI scripting must identify by component ID + DDIC field; status via `MessageType`; VKey not menu-text; no branching on `.Text`/titles |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/abap_code_quality_rules.md` | Applies to any implementing-class source deployed via `/sap-se24` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | RFC connect helper used by the classifier |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | Parallel-safe session attach (token `%%ATTACH_LIB_VBS%%`) |

**Delegation (do not reimplement these in SE19):**

| Concern | Delegate to | Call |
|---|---|---|
| Implementing-class method source / create / activate (Rule #4) | `/sap-se24` | `/sap-se24 <IMPL_CLASS> <abs-source.abap>` |
| Change an object's package (Goto ▸ Object Directory Entry) (Rule #5) | `/sap-change-package` | `/sap-change-package CLASS <class> <pkg>` |
| Resolve a transport request | `/sap-transport-request` | (TR returned; passed into the VBS) |

---

## Step 0 — Resolve work directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The note below still applies to any OTHER keys.

Settings reads/writes follow `shared/rules/settings_lookup.md` — merge per-key on
`.value` (env var → `settings.local.json` → `userconfig.json` → `settings.json`);
non-per-connection writes go to `userconfig.json`. Set `{WORK_TEMP}` =
`{work_dir}\temp`.

```bash
cmd /c if not exist "{WORK_TEMP}" mkdir "{WORK_TEMP}"
```

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1` / `*_run.vbs` and the `_run.json` state) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for `Get-SapCurrentSessionPath -WorkTemp`.

`{LEDGER}` = `{WORK_TEMP}\se19_created_ledger.jsonl` (safety ledger — see Step 6).

---

## Step 0.5 — Start logging (best-effort)

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_se19_run.json" -Skill sap-se19 -ParamsJson "{\"op\":\"<OP>\",\"name\":\"<NAME>\"}"
```

---

## Step 1 — Parse operation + collect parameters

Parse `$ARGUMENTS` into an **operation** (`create` | `update` | `display` |
`delete` | `activate` | `deactivate`) and a **name**.

| Operation | The name is a… | Then collect… |
|---|---|---|
| `create` | **BAdI definition / enhancement spot** | implementation name(s), implementing class (New only — Classic auto-names), short text(s) |
| `display` | BAdI **implementation** | — |
| `update` | BAdI **implementation** | *what* to update (see Step 5 — usually class source → `/sap-se24`) |
| `activate` / `deactivate` | BAdI **implementation** | — |
| `delete` | BAdI **implementation** | whether to also delete the implementing class |

Parameter cheat-sheet:

| Parameter | New BAdI | Classic BAdI |
|---|---|---|
| Definition input (create) | Enhancement Spot (e.g. `ME_PROCESS_PO_CUST`) | BAdI Name (e.g. `WORKBREAKDOWN_UPDATE`) |
| Container name (create) | Enhancement Implementation (e.g. `Z_HK_BADI_PO_01`) | *(none — impl is the unit)* |
| Implementation name (create) | BAdI Implementation (e.g. `Z_HK_IM_PO_01`) | Implementation (e.g. `Z_HK_WBS_01`) |
| Implementing class | **you supply** (e.g. `ZCL_IM_HK_PO_01`) | **auto-named** `ZCL_IM_<impl minus leading Z/Y>` |
| Implementation input (other ops) | Enhancement Implementation name | Implementation name |

Do NOT ask for a transport request — Step 4 resolves it via
`/sap-transport-request`.

---

## Step 2 — Ensure SAP GUI login

Requires an active session. If `/sap-login` hasn't been run, do that first.
The classifier additionally needs SAP NCo 3.1 (32-bit) for RFC.

---

## Step 3 — Classify the BAdI (Classic vs New)

Run the classifier with the name and the expected kind
(`DEFINITION` for `create`, `IMPLEMENTATION` for everything else):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_se19_classify.ps1" -Name "<NAME>" -Expect <DEFINITION|IMPLEMENTATION>
```

Read the final `RESULT:` line plus the resolved fields. Mapping:

| `RESULT: TYPE=` | Meaning | Action |
|---|---|---|
| `CLASSIC` | Classic BAdI (SXS_ATTR, not migrated, or classic impl) | use the **classic** VBS family |
| `NEW` | New BAdI (enhancement spot / BADI_IMPL / migrated-only-new) | use the **new** VBS family |
| `AMBIGUOUS` | Migrated BAdI — implementable as BOTH (e.g. `MB_MIGO_BADI`, `ME_PROCESS_PO_CUST`) | **ASK the user** (below) |
| `UNKNOWN` | Name not found | Report "not found"; for `create` confirm the definition name with the user |

The classifier also returns, when known: `NEW_IMPL_BADI_NAME`,
`NEW_IMPL_ENHNAME`, `NEW_IMPL_CLASS`, `MIG_ENHSPOTNAME`, `CLASSIC_IMPL_IFACE`,
`CLASSIC_IMPL_CLASS`, `CLASSIC_IMPL_ACTIVE`, `TADIR_AUTHOR`, `TADIR_DEVCLASS`,
`TADIR_OBJECT`. Use these to pre-fill class names, route delete-class cleanup,
and run the safety guard (Step 6).

`KIND=` is the **discovered** kind (DEFINITION / IMPLEMENTATION / UNKNOWN) — the
`-Expect` argument is only a **check**, it never rewrites `KIND`. When `-Expect`
conflicts with what was discovered the classifier also emits `DISCOVERED_KIND=`
and `EXPECT_MISMATCH=YES` (also appended to the `RESULT:` line). A mismatch on a
`delete`/`update`/`activate` op means the supplied name is not the implementation
that op needs (e.g. it is a definition) — stop and tell the user (see Step 6).

### Step 3a — Ambiguity prompt (only when `TYPE=AMBIGUOUS`)

Use **AskUserQuestion**: *"`<NAME>` is a migrated BAdI — it can be implemented as
a Classic BAdI or as a New (Enhancement Framework) BAdI. Which do you want?"*
Options: `New BAdI (recommended)`, `Classic BAdI`. SAP recommends the New
framework for migrated BAdIs; default the recommendation accordingly but honour
the user's choice. The choice fixes the VBS family for the rest of the run.

---

## Step 4 — Resolve transport request (deploy operations only)

For `create`, `delete`, and `update` of a transportable object, resolve a TR via
`/sap-transport-request` (honours `way_to_get_transport_request`). The result is
`{TRKORR}`, passed into the VBS `%%TRKORR%%`. For Local (`$TMP`) objects, leave
`{DEVCLASS}` empty and the create VBS presses **Local Object** instead.
`display` needs no TR. `activate` / `deactivate` of a **transported** object CAN
still raise a TR popup: every VBS dispatches the `ctxtKO008-TRKORR` popup by
control id and, if `%%TRKORR%%` is empty, aborts loud with
`ERROR: ABORT_EMPTY_TR` (it never blind-accepts the popup — that would silently
fall back to Local Object). So if you know the object is transported, resolve a
TR via `/sap-transport-request` first and pass it even for activate/deactivate;
if `ABORT_EMPTY_TR` comes back, resolve a TR and re-run.

---

## Step 5 — Execute the operation

All VBS share one **fill-and-run** wrapper. Write `{RUN_TEMP}\se19_run.ps1`,
substituting the per-mode tokens plus the two shared tokens, then run via 32-bit
cscript:

```powershell
$tpl = '<SKILL_DIR>\references\<MODE_VBS>'
$c = [System.IO.File]::ReadAllText($tpl, [System.Text.Encoding]::UTF8)
# --- per-mode tokens (only those present in the chosen VBS) ---
$c = $c -replace '%%ENH_SPOT%%','<ENH_SPOT>'
$c = $c -replace '%%ENH_IMPL_NAME%%','<ENH_IMPL>'
$c = $c -replace '%%ENH_IMPL_TEXT%%','<ENH_TEXT>'
$c = $c -replace '%%BADI_DEFINITION%%','<BADI_DEF>'
$c = $c -replace '%%BADI_IMPL_NAME%%','<BADI_IMPL>'
$c = $c -replace '%%IMPL_CLASS%%','<IMPL_CLASS>'
$c = $c -replace '%%BADI_IMPL_TEXT%%','<BADI_TEXT>'
$c = $c -replace '%%BADI_NAME%%','<BADI_DEF>'
$c = $c -replace '%%IMP_NAME%%','<IMP_NAME>'
$c = $c -replace '%%IMP_TEXT%%','<IMP_TEXT>'
$c = $c -replace '%%SET_ACTIVE%%','<X-or-empty>'
$c = $c -replace '%%DEVCLASS%%','<DEVCLASS-or-empty>'
$c = $c -replace '%%TRKORR%%','<TRKORR-or-empty>'
# Optional ECC6 "Create Object Directory Entry" orphan-fill (delete VBS only;
# default '' => accept pre-filled package / Local Object; '' lang => VBS uses 'E').
$c = $c -replace '%%PACKAGE%%','<OBJDIR_PKG-or-empty>'
$c = $c -replace '%%ORIG_LANG%%','<OBJDIR_LANG-or-empty>'
# --- shared attach plumbing (Phase 3.5 / 4.2) ---
$c = $c -replace '%%SESSION_PATH%%',''
$c = $c -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText('{RUN_TEMP}\se19_run.vbs', $c, [System.Text.UnicodeEncoding]::new($false, $true))
Write-Host 'Done'
```

```bash
powershell -ExecutionPolicy Bypass -File "{RUN_TEMP}\se19_run.ps1"
C:/Windows/SysWOW64/cscript.exe //NoLogo {RUN_TEMP}\se19_run.vbs
```

Always write the VBS with **`-Encoding Unicode`** (UTF-16 LE) — cscript needs it.

### Mode → VBS routing

| Operation | New BAdI VBS | Classic BAdI VBS |
|---|---|---|
| create | `sap_se19_new_create.vbs` | `sap_se19_classic_create.vbs` |
| display | `sap_se19_new_display.vbs` | `sap_se19_classic_display.vbs` |
| activate | `sap_se19_new_setactive.vbs` (`%%SET_ACTIVE%%`=`X`) | `sap_se19_classic_setactive.vbs` (`%%SET_ACTIVE%%`=`X`) |
| deactivate | `sap_se19_new_setactive.vbs` (`%%SET_ACTIVE%%`=``) | `sap_se19_classic_setactive.vbs` (`%%SET_ACTIVE%%`=``) |
| delete | `sap_se19_new_delete.vbs` | `sap_se19_classic_delete.vbs` |
| update | *(no SE19 VBS — see below)* | *(no SE19 VBS — see below)* |

Parse the script output: success contains `SUCCESS:`; failure contains `ERROR:`
(show full output and use the Failure Modes table). On `create` success, append a
ledger record (Step 6) and — if deploying method source — delegate to
`/sap-se24`.

### Update routing

"Update a BAdI implementation" is decomposed; pick by what the user wants:

| Update target | Route |
|---|---|
| Implementing class / method logic (most common) | **`/sap-se24 <IMPL_CLASS> <source.abap>`** (Rule #4). Resolve the class from the classifier (`NEW_IMPL_CLASS` / `CLASSIC_IMPL_CLASS`). |
| Runtime active state | the **activate** / **deactivate** flow above |
| Package | **`/sap-change-package CLASS <class> <pkg>`** (Rule #5) |
| SE19-level attributes (short text, filter values, default-impl flag) | Open in change mode (the activate VBS opens change mode; reuse it) and set the field, or re-create. Not a common path; confirm intent with the user first. |

> **Known delegation gap:** `/sap-change-package` routes enhancement projects via
> `CMOD` but does **not** yet handle the new-BAdI enhancement-implementation
> object type `ENHO` or the classic `SXCI`. The package of the implementation
> container is normally set during `create` (its Object-Directory popup). If a
> *later* package move of the container is needed, flag it as a follow-up for
> `/sap-change-package`.

### After create — deploy class source via /sap-se24

SE19 creates only the empty implementing-class shell. To deploy the method
implementation, write the full class source to `{WORK_TEMP}\<IMPL_CLASS>.abap`
(complete `CLASS … DEFINITION` + `CLASS … IMPLEMENTATION`, modern syntax, no
literal MESSAGE strings) and call `/sap-se24 <IMPL_CLASS> <that-path>`. The TR is
resolved inside `/sap-se24`.

---

## Step 6 — Safety guard for Delete + the created-by-us ledger (Rule #6)

**You are FORBIDDEN to delete any BAdI definition, and any BAdI implementation
this session did not create.**

- **Definitions are never deleted here.** If `classify` returns `KIND=DEFINITION`
  (or `EXPECT_MISMATCH=YES` for a `delete`, which passes `-Expect IMPLEMENTATION`),
  refuse: SE19 deletes implementations only (definitions live in SE18 / the
  enhancement spot). `KIND` is the *discovered* kind — `-Expect` is only a check,
  it never rewrites `KIND` to the caller's expectation, so this guard is
  reachable. `EXPECT_MISMATCH=YES` means the name is a definition (or otherwise
  not the implementation the op expected) — treat it as "wrong object for this
  operation" and stop.
- **Implementations: the ledger is the gate.** "Created by you" means created by
  *this skill* — recorded in `{LEDGER}`. A matching TADIR author is **not**
  sufficient (the logon user authors plenty of objects by hand). Before running
  any delete VBS:
  1. Read `{LEDGER}` and look for a record whose `name` == the target
     (case-insensitive). **Ledger hit ⇒ we created it ⇒ proceed.**
  2. **No ledger hit ⇒ REFUSE by default**, regardless of TADIR author:
     *"`<NAME>` was not created by this skill (not in the sap-se19 ledger);
     refusing to delete per the safety rule. Confirm explicitly to override."*
     Proceed only on an **explicit** user override. Escalate the warning when
     `TADIR_AUTHOR` is a *different* user than the logon user — that object
     clearly belongs to someone else.

**Ledger record (append on every successful create):**

```bash
cmd /c echo {"ts":"<UTC>","op":"create","type":"<CLASSIC|NEW>","name":"<container-or-impl>","impl":"<badi-impl>","class":"<impl-class>","author":"<user>","system":"<SID>","client":"<client>","trkorr":"<TR>"} >> "{LEDGER}"
```

(Use the Write/Bash tools to append a clean one-line JSON record. `name` = the
value the user would pass to a later `delete`: the Enhancement Implementation for
New, the Implementation for Classic.)

**Delete leaves residue — surface it:**

- The **implementing class is NOT removed** by SE19 delete — for **either** type
  the class survives in `SEOCLASS` (verified: even classic SE19's second "delete
  class?" confirmation leaves it). After a delete, offer to remove the class via
  **`/sap-se24 delete <class>`** — but only if the class is in our ledger /
  authored by us (apply the same safety gate). Resolve the class name from the
  classifier (`NEW_IMPL_CLASS` / `CLASSIC_IMPL_CLASS`).
- A **`TADIR` orphan** (`ENHO`/`SXCI`/`CLAS` row) persists after a *transported*
  delete — this is expected; the deletion travels in the TR. Verify removal via
  the **authoritative config tables**, not TADIR: `BADI_IMPL` (New) or
  `SXC_CLASS`/`SXC_ATTR` (Classic) empty == deleted.

---

## Step 7 — Verify (RFC) + report

After write operations, RFC-verify the resulting state (reuse `sap_rfc_lib.ps1`
or re-run the classifier):

| Operation | Authoritative check |
|---|---|
| create (New) | `BADI_IMPL` row for the ENHNAME exists; `DWINACTIV` OBJ_NAME=`<enh-impl>` == 0 rows (ACTIVE) |
| create (Classic) | `SXC_CLASS`/`SXC_ATTR` row for the IMP_NAME exists |
| delete (New) | `BADI_IMPL` ENHNAME == 0 rows |
| delete (Classic) | `SXC_CLASS` IMP_NAME == 0 rows |
| **activate/deactivate (New)** | **`DWINACTIV` OBJ_NAME=`<enh-impl>` == 0 rows** — `ROWS>0` means the enhancement implementation is still INACTIVE. **Do NOT trust the VBS `SUCCESS:` line alone** for New BAdIs — it is read from `sbar.MessageType`, which can be blank when activation silently doesn't complete (see Known Issue below). |
| activate/deactivate (Classic) | `SXC_ATTR.ACTIVE` reflects the new state |

Report to the user: what was done, the resolved BAdI type, the object names, the
TR (if any), the implementing-class status (and whether class source still needs
`/sap-se24`), and any TADIR orphan note.

> **Known Issue — New-BAdI re-activation on S/4HANA 2022+ (verified 2026-05-30, S4H).**
> Re-activating a *new* BAdI enhancement implementation *after an edit* (the
> `*_new_setactive.vbs` flow) can fail to complete: pressing Activate shows the
> inactive-objects worklist, but Continue/Select-All leaves the object inactive
> and the editor switches to the enhancement-framework **conflict/adjustment tool**
> (`tabpTABS_4` / `SAPLSEEF_ADJ_TOOL` `…CONFLICT_CONTAINER`). The VBS still prints
> `SUCCESS` (blank `sbar`), so you MUST run the `DWINACTIV` check above — `ROWS>0`
> ⇒ report FAILED and surface the conflict tool to the user (it needs manual
> adjustment, or a re-record of the activate flow via `/sap-gui-probe` on 2022).
> *Create*-time activation is unaffected (it completes cleanly). Classic BAdIs are
> unaffected (no enhancement worklist).

---

## Step 8 — Clean up + log end

Delete temp VBS/PS:
```bash
cmd /c del {RUN_TEMP}\se19_run.vbs & del {RUN_TEMP}\se19_run.ps1
```
Also delete `{WORK_TEMP}\<IMPL_CLASS>.abap` if you wrote pasted source.

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_se19_run.json" -Status <SUCCESS|FAILED> -ExitCode <0|1>
```

Suggested `ErrorClass`: `SE19_FAILED`, `BADI_AMBIGUOUS_UNRESOLVED`,
`DELETE_REFUSED_SAFETY`, `BADI_NOT_FOUND`, `TR_RESOLUTION_FAILED`, `GUI_TIMEOUT`.

---

## Failure Modes / Recovery

| Symptom (script `ERROR:` …) | Cause | Recovery |
|---|---|---|
| `Create Enhancement Implementation popup did not appear` | Enhancement spot not found / not implementable | Verify the spot name; re-run `classify`; the create input must be a definition/spot |
| `Create BAdI Implementations popup did not appear` | Enh-impl created but element popup differs by release | `/sap-gui-object-details` on the live screen; update `tblSAPLENH_BADI_POPUPSG_BADI_TABLE` ids |
| combo BAdI definition stays empty | wrong `.Key` (spot has multiple defs) | enumerate combo `.Entries` (object-details) and pass the exact key |
| `Did not reach the enhancement implementation editor` | class-creation chain diverged (e.g. existing class) | `/sap-gui-diagnose` for a screenshot; the implementing class may already exist — pick a new name |
| `Could not open … in change mode` | object locked (SM12) or no authorization | release the lock / check authorization |
| `'Implementation is active' checkbox not found` | no BAdI implementation node selected in the tree | ensure a single impl; for multi-impl, select the node first (object-details) |
| Activation shows unrelated objects in the worklist | SAP groups all inactive objects of the user | the VBS presses Continue (activates the worklist) — acceptable on dev; if undesired, activate the impl alone via SE19 manually |
| New BAdI stays INACTIVE after activate/deactivate (`DWINACTIV` ROWS>0) despite `SUCCESS:` | S/4HANA 2022+ routes re-activation through the conflict/adjustment tool (`SAPLSEEF_ADJ_TOOL`); worklist Continue doesn't complete it | run the Step 7 `DWINACTIV` check (don't trust sbar); resolve the adjustment manually in SE19 or re-record the activate flow on 2022 (`/sap-gui-probe`) |
| Delete `refused … safety rule` | target not created this session | intended — only override with explicit user confirmation |
| `Delete failed` with locked-class message | implementing class is locked / used elsewhere | delete the class separately via `/sap-se24` after releasing locks |

---

## SE19 Component-ID Reference (probed S/4HANA 1909, SAP GUI 7.60, EN)

**Initial screen `SAPLSEXO` (120):** New-edit `radG_IS_NEW_1` + `ctxtG_ENHNAME`;
New-create `radG_IS_NEW_2` + `ctxtG_ENHSPOTNAME`; Classic-edit `radG_IS_CLASSIC_1`
+ `ctxtRSEXSCRN-IMP_NAME`; Classic-create `radG_IS_CLASSIC_2` +
`ctxtRSEXSCRN-EXIT_NAME`. Buttons `btnPUSHBUTTON_DISPLAY_TEXT`,
`btnPUSHBUTTON_CHANGE_TEXT`, `btnPUSHBUTTON_IMPLEMENT_TEXT`; app-bar
`tbar[1]/btn[14]` Delete implementation.

**New create chain:** Enh-impl popup `SAPLSEEF_BASE` →
`wnd[1]/usr/txtG_ENHSTRU-ENHNAME` + `-SHORTTEXT`, Continue `wnd[1]/tbar[0]/btn[0]`.
Object Directory `SAPLSTRD(100)` `ctxtKO007-L_DEVCLASS` (Save `btn[0]`, Local
`btn[7]`); TR `SAPLSTRD(300)` `ctxtKO008-TRKORR` (Continue `btn[0]`). Create-BAdI
popup `SAPLENH_BADI_POPUPS(1000)` table
`tblSAPLENH_BADI_POPUPSG_BADI_TABLE/{txtG_BADI-IMPL_NAME[0,0], txtG_BADI-CLASS_NAME[1,0], cmbG_BADI-BADI_NAME[2,0](.Key), txtG_BADI-BADI_SHORTTEXT[3,0]}`.
Create-class popup `SAPLENH_EDT_BADI(1000)` Empty-Class `wnd[1]/tbar[0]/btn[2]`.

**New detail `SAPLENHANCEMENT_EDITOR(6000)`:** name `txtENH_EDT_LAYOUT-OBJECT1`,
status `txtENH_EDT_LAYOUT-VERSION_TX`; toolbar `tbar[1]/btn[27]` Activate,
`btn[25]` Display↔Change. Tab `tabsTS_ENHANCEMENTS/tabpTABS_5` ("Enh.
Implementation Elements") → runtime flag
`…/ssubENH_BADI_IMPL:SAPLENH_EDT_BADI:0102/chkENH_BADI_IMPL_ADMIN_DATA-ACTIVE`.
Inactive-objects worklist Continue `wnd[1]/tbar[0]/btn[0]`. Delete confirm
`SAPLSPO4(300)` `wnd[1]/tbar[0]/btn[0]`.

**Classic detail `SAPLSEXO(150)`:** impl `ctxtRSEXSCRN-IMP_NAME`, status
`txtRSEXSCRN-ACTIVE`, short text `txtRSEXSCRN-IMP_TEXT`, definition
`ctxtRSEXSCRN-EXIT_NAME`; toolbar `tbar[1]/btn[27]` Activate, **`btn[28]`
Deactivate (Ctrl+F4)**. Create-impl popup `ctxtRSEXSCRN-IMP_NAME` +
`wnd[1]/tbar[0]/btn[0]`. Save Yes/No `SAPLSPO1(500)`
`wnd[1]/usr/btnBUTTON_1` (Yes). Delete confirm chain `SAPLSPO1(500)`:
`btnBUTTON_1` Yes (impl), then `btnBUTTON_1`/`btnBUTTON_2` (delete class? Yes/No).

> IDs were captured by `/sap-gui-probe` + `/sap-gui-object-details`. Re-record
> with `/sap-gui-record` if a different release renumbers a tree/menu node.

---

## Classification tables (RFC, read-only)

| Table | Key / fields | Tells you |
|---|---|---|
| `SXS_ATTR` | `EXIT_NAME`, `MIG_BADI_NAME`, `MIG_ENHSPOTNAME` | Classic definition exists; non-empty `MIG_*` ⇒ migrated (also a New spot) ⇒ AMBIGUOUS |
| `SXC_CLASS` | `IMP_NAME`, `INTER_NAME`, `IMP_CLASS` | Classic implementation + its interface + class |
| `SXC_ATTR` | `IMP_NAME`, `ACTIVE`, `UNAME` | Classic impl runtime-active flag + creator |
| `BADI_IMPL` | `BADI_NAME`, `ENHNAME`, `BADI_IMPL`, `CLASS_NAME` | New impl ↔ definition ↔ enhancement-impl container ↔ class |
| `TADIR` | `OBJECT` ∈ {`ENHS` spot, `ENHO` enh-impl, `SXSD` classic def, `SXCI` classic impl, `CLAS`}, `AUTHOR`, `DEVCLASS` | object directory + creator (safety guard) |
