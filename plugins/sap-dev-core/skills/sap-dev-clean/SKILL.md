---
name: sap-dev-clean
description: |
  Conservative cleanup of the artefacts /sap-dev-init created. Walks
  reverse dependency order — wrapper FM, then DDIC structure +
  table type, then utility program, then function group, then
  package — and deletes only what the operator confirms. Skips any
  artefact whose dependents were extended by the operator (e.g.
  function group that contains user-added FMs, package that contains
  user-added Z* tables) unless --force is set.
  By default the transport request is left untouched (other work may
  live in it). Settings.json keys are preserved unless --settings is
  passed, so a follow-up /sap-dev-init re-creates the same names.
  The canonical "blow away and rebuild" sequence is:
  /sap-dev-clean ; /sap-dev-init.
  Prerequisites: SAP NCo 3.1 in GAC + active SAP GUI session
  (clean delegates to GUI-driven delete skills like /sap-se37,
  /sap-se11, /sap-se38, /sap-function-group, /sap-se21).
argument-hint: "[--settings] [--force] [--dry-run]"
---

# SAP Dev Environment Clean Skill

You remove the artefacts `/sap-dev-init` created — without nuking
anything the operator added on top. The flow is conservative by
design: each step asks for confirmation, and "skip if extras present"
guards prevent destructive surprises.

Task: $ARGUMENTS

---

## Shared Resources

| File | Purpose |
|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_dev_artefacts.ps1` | RFC artefact-state pre-flight (also used by `/sap-dev-status`) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | Mandatory operating rules |

---

## Step 0 — Resolve Work Directory and Settings

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge `settings.local.json` over `settings.json` per-key on the `.value` field; writes always go to `settings.local.json`. Read `work_dir`, `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group`, plus the standard SAP RFC connection keys.

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_dev_clean_run.json" -Skill sap-dev-clean -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

| Flag | Meaning |
|---|---|
| `--settings` | After SAP-side cleanup, clear the `sap_dev_*` keys via `/update-config` so the next `/sap-dev-init` picks fresh names. Default: keys preserved. |
| `--force` | Skip the "extras-present, skip" guards on FG and package. Use only when you're absolutely sure no operator content depends on these artefacts. |
| `--dry-run` | Pre-flight only. Print what would be deleted, prompt for nothing, change nothing. |

**Trigger phrases:**

- "clean dev env", "clean my sap-dev environment"
- "remove sap-dev-init artefacts"
- "wipe ZCMST_RFC_PARAM and the wrapper FM"

If the operator says "reset dev env" without a separate verb, treat it
as the chain `/sap-dev-clean ; /sap-dev-init` and offer to run both
back to back. There is intentionally no `/sap-dev-reset` skill —
chaining is the canonical reset.

---

## Step 2 — Pre-flight via `/sap-dev-status`

Always run `/sap-dev-status` first to find out what's actually in the
system. Use its per-artefact output as the worklist for Steps 3a–3f
below — only attempt deletion of artefacts whose `STATE` is not
`MISSING` / `NOT_CONFIGURED`.

If `STATUS: ERROR`, abort: an RFC connection problem will block the
cleanup anyway.

If `--dry-run`, print the worklist and stop here.

---

## Step 3 — Delete artefacts in reverse dependency order

For each step below: confirm with the operator, showing the artefact
name and (where applicable) what depends on it. If the operator
declines, log the choice and continue with the rest. Failures of one
step do not abort subsequent steps.

### Step 3a — Wrapper FM (`Z_GENERIC_RFC_WRAPPER_TBL`)

Delegate to `/sap-se37` delete mode:

```
/sap-se37 delete Z_GENERIC_RFC_WRAPPER_TBL TRANSPORT=<TR-or-empty>
```

Pass the resolved TR (or empty for `$TMP` / already locked). The SE37
delete VBS confirms via `btnSPOP-OPTION1` and verifies removal via
TFDIR.

### Step 3b — Wrapper DDIC objects

Delegate to `/sap-se11` delete mode, table type first (depends on the
structure):

```
/sap-se11 delete TABLETYPE  ZCMCT_RFC_PARAM  TRANSPORT=<TR-or-empty>
/sap-se11 delete STRUCTURE  ZCMST_RFC_PARAM  TRANSPORT=<TR-or-empty>
```

If 3a failed (wrapper FM still references the structure), 3b will
error out — surface that and stop the DDIC sub-step.

### Step 3c — Utility program (`ZCMRUPDATE_ADDON_TABLE`)

Delegate to `/sap-se38` delete mode:

```
/sap-se38 delete program ZCMRUPDATE_ADDON_TABLE TRANSPORT=<TR-or-empty>
```

### Step 3d — Function group (`sap_dev_function_group`)

**Conservatism guard.** Before deleting, query `TFDIR` to enumerate
the FMs that belong to this FG (`PNAME = 'SAPL' & FUGR_ID`). If the
list contains anything beyond `Z_GENERIC_RFC_WRAPPER_TBL` (which Step
3a should already have removed), warn the operator:

> Function group `<FG>` still contains user-added FMs:
> `<list>`. Delete it anyway? **No** = leave the FG with the
> remaining FMs intact. Yes = drop everything.

Without `--force`, default to **No**. With `--force`, proceed silently.

If safe to proceed, delegate to `/sap-function-group --delete`:

```
/sap-function-group <FG> --delete TRANSPORT=<TR-or-empty>
```

### Step 3e — Package (`sap_dev_package`)

**Emptiness guard.** Pre-flight already reported `EMPTY` or
`NON_EMPTY` for the package. If `NON_EMPTY` (operator added their own
Z-objects) and `--force` is NOT set, skip with a warning:

> Package `<PKG>` still has TADIR children: skipping. Move your
> objects to a different package, then re-run `/sap-dev-clean
> --force` if you really want this package gone.

If safe to proceed, delegate to `/sap-se21` delete mode (Step 8 in
that skill — operator confirms there too, so this is a doubly-gated
path):

```
/sap-se21 delete <PKG> TRANSPORT=<TR-or-empty>
```

The SE21 delete VBS uses Shift+F2 from the initial screen, walks the
`btnBUTTON_1` confirmation popup, and verifies removal via TDEVC
re-check. Failures most commonly mean the package still has TADIR
children — surface SE21's error verbatim and let the operator move
those objects manually.

### Step 3f — Transport request

**By default, leave it alone.** Other work may live in it. The TR
deletion path requires SE01 release-and-delete which is risky.

With `--force`, additionally:

1. Confirm with the operator showing the TR's E071 child list (one
   line per object) — **let them read it first**.
2. If the operator approves, delegate to `/sap-se01` to release and
   delete the TR (skill must implement that path; if not, surface
   "TR cleanup not supported — handle manually in SE01").

---

## Step 4 — Optional: clear settings keys

If `--settings` was passed, after Steps 3a-3f finish, clear the
`sap_dev_transport_request`, `sap_dev_package`, and
`sap_dev_function_group` keys via `/update-config`:

```
/update-config userConfig.sap_dev_transport_request = ""
/update-config userConfig.sap_dev_package           = ""
/update-config userConfig.sap_dev_function_group    = ""
```

The next `/sap-dev-init` will then ask the operator for fresh names
(or pick defaults if defaults are configured).

---

## Step 5 — Post-flight via `/sap-dev-status`

Run `/sap-dev-status` once more. Compare with the pre-flight from
Step 2:

- Artefacts that moved from a non-MISSING state to `MISSING` →
  successfully cleaned.
- Artefacts still present → either skipped by guard (operator content
  found) or failed during delegation (failure reason already echoed).

Report the pair side-by-side:

```
Pre-clean:
  Z_GENERIC_RFC_WRAPPER_TBL  FM      ACTIVE
  ZCMCT_RFC_PARAM            TT      ACTIVE
  ZCMST_RFC_PARAM            STRUCT  ACTIVE
  ZCMRUPDATE_ADDON_TABLE     PGM     ACTIVE
  ZFG018                     FG      ACTIVE
  ZCMPKG018                  PKG     NON_EMPTY  (skipped, --force not set)
  S4DK941132                 TR      MODIFIABLE (left alone by default)

Post-clean:
  Z_GENERIC_RFC_WRAPPER_TBL  FM      MISSING
  ZCMCT_RFC_PARAM            TT      MISSING
  ZCMST_RFC_PARAM            STRUCT  MISSING
  ZCMRUPDATE_ADDON_TABLE     PGM     MISSING
  ZFG018                     FG      ACTIVE  (skipped — extras present)
  ZCMPKG018                  PKG     NON_EMPTY
  S4DK941132                 TR      MODIFIABLE
```

---

## Step 6 — Clean Up

```bash
cmd /c del "{WORK_TEMP}\sap_dev_clean_run.ps1"
```

(The shared status checker is invoked indirectly via `/sap-dev-status`,
which manages its own temp file.)

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_dev_clean_run.json" -Status SUCCESS -ExitCode 0
```

On failure (substitute `<CLASS>` and short message):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{WORK_TEMP}\sap_dev_clean_run.json" -Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"
```

Suggested `<CLASS>`: `DEV_CLEAN_FM_FAILED`, `DEV_CLEAN_DDIC_FAILED`,
`DEV_CLEAN_FG_HAS_EXTRAS`, `DEV_CLEAN_PKG_NON_EMPTY`,
`DEV_CLEAN_TR_RISK`.

---

## "Reset" workflow

There's intentionally no `/sap-dev-reset` skill. The canonical reset
chain is:

```
/sap-dev-clean        # remove artefacts (conservative defaults)
/sap-dev-init         # recreate
```

To also wipe settings (so the next init asks fresh names):

```
/sap-dev-clean --settings
/sap-dev-init
```

The chain is two slash commands, not one — atomicity isn't a real
benefit of merging since the failure modes (TR locked, package not
modifiable, wrapper-FM activation refused) are identical either way.
Keeping them separate makes "I want to clean but not reinstall" a
trivial one-step operation.

---

## Limitations

- **No automatic TR deletion by default.** The TR is presumed to host
  other work; cleaning the TR is opt-in via `--force` and still
  requires explicit per-call confirmation.
- **Conservative guards stop at the first user object.** A package
  with one Z table the operator added is left intact even if the rest
  is sap-dev-init detritus. Use `--force` to override, but read the
  pre-flight list first.
- **Delegated delete paths inherit their owners' caveats.** SE11
  STRUCTURE delete relies on no inactive workspace remnants; SE38
  delete on the program not being open in another session; etc. See
  the respective skills' troubleshooting sections.
- **`/sap-se21` delete is doubly gated.** This skill confirms before
  delegating, and SE21 itself confirms again at Step 8 (its own
  irreversibility prompt). That's intentional — package deletion has
  the largest blast radius of any cleanup step.
