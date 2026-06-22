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
  Pass --reset for a full, truly-clean reset: it implies --force + --settings,
  additionally clears the dev-default settings keys and deletes the dev
  transport request (delegating to /sap-se01) so nothing is left behind for
  the next /sap-dev-init to choke on.
  Prerequisites: Active SAP GUI session (use /sap-login first); SAP NCo 3.1
  (32-bit, .NET 4.0) in GAC. Clean delegates to GUI-driven delete skills
  like /sap-se37, /sap-se11, /sap-se38, /sap-function-group, /sap-se21.
argument-hint: "[--reset] [--settings] [--force] [--dry-run]"
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
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | GUI-scripting language independence — applies to GUI-driven delete sub-skills (sap-se37, sap-se11, sap-se38, sap-function-group, sap-se21) |

---

## Step 0 — Resolve Work Directory and Settings

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and `userconfig.json`). Use the `WORK_DIR=` value printed by:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

The settings note below still applies to the OTHER keys.

**Settings reads/writes follow `shared/rules/settings_lookup.md`** — merge per-key on the `.value` field (env var → `settings.local.json` → `userconfig.json` → `settings.json`); non-per-connection writes go to `userconfig.json`. Read `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group`, plus the standard SAP RFC connection keys.

**Per-connection keys (Phase 4.4)**: `sap_dev_transport_request`, `sap_dev_package`, `sap_dev_function_group` are SAP-system-specific. Per `settings_lookup.md` § Per-connection exception, read them from `connections.json[pinned-profile].dev_defaults` FIRST (resolve the pin via `{work_dir}\runtime\session_registry.json` `ai_sessions[<id>]`); only fall back to the two-file merge when `dev_defaults` is empty. Critical for `clean` since deleting an artefact named in one system's dev_defaults must NOT touch a different system's artefacts.

**Target the connection named in the Task argument — MANDATORY before any delete (safety).** The Task argument may name a SAP connection (SID / description substring / UUID). Both the per-connection `dev_defaults` read above AND the GUI deletes in Step 3 resolve against the *currently pinned* connection — which is **not** necessarily the one you named — so a destructive clean can silently hit the wrong system. Resolve the argument and compare to the current pin:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; $m=@(Resolve-SapProfileHint -Hint '<TASK_ARG>'); if($m.Count -ne 1){ Write-Output ('TARGET=NEEDS_USER count='+$m.Count); return }; $cur=Get-SapCurrentConnectionProfile; Write-Output ('NAMED='+$m[0].system_name+'/'+$m[0].client+' id='+$m[0].id); Write-Output ('CURPIN='+$cur.system_name+'/'+$cur.client+' id='+$cur.id)"
```

If `TARGET=NEEDS_USER`, STOP and ask which connection. If the NAMED id ≠ the CURPIN id, switch to the named connection (pin **and** attach a live GUI session) via `/sap-login --switch <TASK_ARG>` BEFORE Step 2 — the GUI deletes must run on the right system. **Do NOT proceed to Step 3 unless the active connection is confirmed to be the named one.**

Set `{WORK_TEMP}` = `{work_dir}\temp`. Ensure it exists.

Set `{RUN_TEMP}` = the per-run scratch dir (`Get-SapRunTemp` mints + creates `{work_dir}\temp\run_<id>`):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```
Per the CLAUDE.md "Two-bucket temp model" write this skill's generated scratch (`*_run.ps1`) under `{RUN_TEMP}`; keep `{WORK_TEMP}` (base) only for the log state.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{WORK_TEMP}\sap_dev_clean_run.json" -Skill sap-dev-clean -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments

| Flag | Meaning |
|---|---|
| `--reset` | **Full, truly-clean reset.** Implies `--force` **and** `--settings`, and additionally **deletes the dev transport request** (Step 3f) so no husk is left behind. Use for the `/sap-dev-clean --reset ; /sap-dev-init` rebuild. Still per-step confirmed; combine with `--dry-run` to preview first. |
| `--settings` | After SAP-side cleanup, clear the `sap_dev_*` keys so the next `/sap-dev-init` picks fresh names. Default: keys preserved. |
| `--force` | Skip the "extras-present, skip" guards on FG and package. Use only when you're absolutely sure no operator content depends on these artefacts. |
| `--dry-run` | Pre-flight only. Print what would be deleted, prompt for nothing, change nothing. |

**`--reset` is the umbrella destructive flag.** When it is set, treat `--force`
and `--settings` as also set for every step below (the extras-skip guards are
bypassed, the settings keys are cleared in Step 4), and run the TR-delete path
in Step 3f. It does **not** make deletes silent — each artefact step still
confirms with the operator (use `--dry-run` for a no-prompt preview).

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

**ANCHOR GATE — abort on `STATUS: CONFIG_MISMATCH` (a `CONFIG_MISMATCH:` line is
present).** This is the hard safety stop: the configured `sap_dev_package` /
`sap_dev_function_group` does **not** match where the wrapper FM actually lives
(the `ANCHOR:` line), so the package/FG this clean would target is the wrong
object — typically an application package an earlier build wrote into the
connection's `dev_defaults`. **Do NOT delete anything**, and **`--force` /
`--reset` do NOT override this gate** (they bypass the "extras present" guards,
which is exactly why a wrong pointer here is dangerous). Surface the mismatch
and stop:

> `/sap-dev-clean` aborted — the configured dev defaults point at the wrong
> objects. The wrapper FM lives in package `<anchor-package>` / FG
> `<anchor-fugr>`, but `sap_dev_package` is set to `<configured>`. Deleting
> against the current config would target the wrong package/TR. Fix the
> connection's `dev_defaults` to the anchor values, then re-run:
> ```
> <SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1 -Action set -Scope Connection -Key sap_dev_package        -Value <anchor-package>
> <SAP_DEV_CORE_SHARED_DIR>\scripts\sap_dev_default.ps1 -Action set -Scope Connection -Key sap_dev_function_group -Value <anchor-fugr>
> ```

Log `Status SKIPPED`, `ErrorClass DEV_CLEAN_CONFIG_MISMATCH`, and stop. (Offer
to apply the corrections for the operator; only proceed to the deletes once a
re-run reports `CONFIG: OK`.)

`CONFIG_HINT:` lines (a blank `sap_dev_*` key) are NOT a stop — clean simply
skips that artefact's step — but mention them so the operator can fill the key.

If `--dry-run`, print the worklist and stop here.

---

## Step 3 — Delete artefacts in reverse dependency order

For each step below: confirm with the operator, showing the artefact
name and (where applicable) what depends on it. If the operator
declines, log the choice and continue with the rest. Failures of one
step do not abort subsequent steps.

**Append `PACKAGE=<sap_dev_package>` (from Step 0) to each `/sap-se37`,
`/sap-se11`, and `/sap-se38` delete delegation below.** On ECC6 a delete can
raise the "Create Object Directory Entry" popup with an EMPTY package field
when the object's directory entry was orphaned by a prior half-delete; passing
the package lets the sub-skill fill it and record the deletion on the TR
instead of falling back to a local (non-transported) delete. When the field is
pre-filled (the normal case) the value is ignored, so it is always safe to pass.

**Invoke each sub-skill via the Skill tool — NEVER substitute its reference
VBS.** Every step below says "delegate to `/sap-X`": that means **invoke `/sap-X`
through the Skill tool**, and read its result. Do NOT shortcut by opening a
sub-skill's `references/*.vbs` and running it yourself — not even to save
context. The release-specific dispatch, fallbacks, TR resolution and
**post-delete RFC verification** live in each sub-skill's **SKILL.md, not its
VBS**; running the VBS bare silently drops them (an unverified delete can
false-succeed), and for the function group it **breaks the delete outright**: on
ECC 6.0 / NW 7.31 `sap_function_group_gui_delete.vbs` aborts *by design*
(`SE80 type/name control not found`) so `/sap-function-group` can fall through to
`/sap-se38 delete SAPL<FG>`. That abort is the **fallback trigger, not a
failure** — reading the VBS alone will mis-report a deletable FG as blocked
(observed in the field, 2026-06-22). Driving a reference VBS directly is
legitimate only for skill *development/debugging*, never inside this production
cleanup.

### Step 3a — Wrapper FM (`Z_GENERIC_RFC_WRAPPER_TBL`)

Delegate to `/sap-se37` delete mode:

```
/sap-se37 delete Z_GENERIC_RFC_WRAPPER_TBL TRANSPORT=<TR-or-empty>
```

Pass the resolved TR (or empty for `$TMP` / already locked). The SE37
delete VBS confirms via `btnSPOP-OPTION1` and verifies removal via
TFDIR.

### Step 3b — Wrapper DDIC objects

Delegate to `/sap-se11` delete mode in strict reverse-dependency order —
table type (depends on the structure), then the structure, then the data
element and domain it is built on:

```
/sap-se11 delete TABLETYPE    ZCMCT_RFC_PARAM  TRANSPORT=<TR-or-empty>
/sap-se11 delete STRUCTURE    ZCMST_RFC_PARAM  TRANSPORT=<TR-or-empty>
/sap-se11 delete DATAELEMENT  ZCMDE_RFCVAL     TRANSPORT=<TR-or-empty>
/sap-se11 delete DOMAIN       ZCMD_RFCVAL      TRANSPORT=<TR-or-empty>
```

`ZCMDE_RFCVAL` / `ZCMD_RFCVAL` are the wrapper family's own payload data
element + domain (single-source DDIC, created by `/sap-dev-init` Steps 4b and
4c). Order matters: the structure must be gone before the DE delete (the
structure references it), and the DE before the domain. If 3a failed (wrapper
FM still references the structure) — or a delete fails because its dependent is
still present — surface the error and stop the DDIC sub-step.

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

**By default (no `--reset` / `--force`), leave it alone.** Other work may live
in it.

**With `--reset`** — delete the dev transport request itself, so the reset
leaves no husk. By this point Steps 3a–3e have removed every object the dev TR
held, so it now carries only those (now-deleted) entries and is safe to drop:

1. Confirm with the operator, showing the TR's `E071` child list (one line per
   object) — **let them read it first**. If the list contains objects the
   operator added that are NOT sap-dev-init artefacts, STOP and surface them —
   do not delete a TR holding unrelated work, even under `--reset`.
2. Delete the (unreleased) TR via `/sap-se01`:
   ```
   /sap-se01 delete <TR>
   ```
   This deletes the request **object** — NOT release (releasing would transport
   the throwaway dev objects onward). `/sap-se01 delete` is two-phase: it first
   **empties** the request of any object entries (SAP refuses to delete a
   non-empty request), then drops it. By this point 3a–3e have already deleted
   the objects, so the empty-phase is a no-op safety net here — nothing is
   orphaned. A released TR cannot be deleted (only reimported); if SE01 reports
   it is released, surface that and skip.
3. **If the delete cannot complete** (e.g. `/sap-se01` reports the TR is
   already released, or the delete errors), do NOT fail the clean — Step 4
   clears the TR reference (so the next `/sap-dev-init` self-heals and never
   reuses it), leaving only a harmless husk. Report the TR for manual handling
   in SE01.

**With `--force` but not `--reset`** (legacy opt-in): same confirm-then-delete
flow as the `--reset` path above.

---

## Step 4 — Optional: clear settings keys

If `--settings` **or** `--reset` was passed, after Steps 3a-3f finish, clear the
`sap_dev_transport_request`, `sap_dev_package`, and
`sap_dev_function_group` standing defaults. Since `/sap-dev-init` now persists
them **Connection-scoped** (the pinned connection's `dev_defaults` block), clear
them THERE — an empty value reads as "unset", so reads fall through:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; foreach ($k in 'sap_dev_transport_request','sap_dev_package','sap_dev_function_group') { Set-SapUserSetting -Key $k -Value '' -Scope Connection }"
```

Also clear the legacy global layer (for any pre-migration values that may still
linger there):

```
/update-config userConfig.sap_dev_transport_request = ""
/update-config userConfig.sap_dev_package           = ""
/update-config userConfig.sap_dev_function_group    = ""
```

Also clear the **Session** layer for this conversation × connection, so the
current chat doesn't retain a stale task-scoped TR/package/FG after the reset
(the Session layer is otherwise age-pruned, but a reset should drop it now):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; foreach ($k in 'sap_dev_transport_request','sap_dev_package','sap_dev_function_group') { Set-SapUserSetting -Key $k -Value '' -Scope Session }"
```

The next `/sap-dev-init` will then ask the operator for fresh names (or pick
defaults if defaults are configured).

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
  ZCMDE_RFCVAL               DTEL    ACTIVE
  ZCMD_RFCVAL                DOMA    ACTIVE
  ZCMRUPDATE_ADDON_TABLE     PGM     ACTIVE
  ZFG018                     FG      ACTIVE
  ZCMPKG018                  PKG     NON_EMPTY  (skipped, --force not set)
  S4DK941132                 TR      MODIFIABLE (left alone by default)

Post-clean:
  Z_GENERIC_RFC_WRAPPER_TBL  FM      MISSING
  ZCMCT_RFC_PARAM            TT      MISSING
  ZCMST_RFC_PARAM            STRUCT  MISSING
  ZCMDE_RFCVAL               DTEL    MISSING
  ZCMD_RFCVAL                DOMA    MISSING
  ZCMRUPDATE_ADDON_TABLE     PGM     MISSING
  ZFG018                     FG      ACTIVE  (skipped — extras present)
  ZCMPKG018                  PKG     NON_EMPTY
  S4DK941132                 TR      MODIFIABLE
```

**Also check for TADIR orphans (ECC6).** The per-artefact checker compares
DEFINITION state, but on ECC6 a successful SE-delete commonly removes the
definition while leaving the object's `TADIR` directory row behind (only the
object that happened to get a transport deletion entry clears it). Such an
orphan reads as `MISSING` in the checker (definition gone) yet still blocks
the **package** delete (Step 3e) — `SE21` refuses a package whose `TADIR`
still has children. So after the comparison, RFC-check `TADIR` for every
deleted artefact (`PGMID=R3TR`, `OBJECT` ∈ {`PROG`,`TABL`,`TTYP`,`DTEL`,
`DOMA`,`FUGR`}, `OBJ_NAME=<name>`); a row that survives while the definition
is gone is a TADIR orphan. Report each orphan explicitly (do NOT fold it into
"cleaned") with the remediation:

- **Clear the directory entries** — `SE03 → Object Directory → Change Object
  Directory Entries` (report `RSWBO052`; ECC6 has no dedicated "Delete Object
  Directory Entries" node): select the orphan rows → delete.
- **or release/delete the transport** holding the objects — releasing
  finalizes the recorded deletions and clears their `TADIR`; deleting the TR
  (once it holds only deleted objects) unlocks them so the SE03 step / a
  re-run of Step 3e can complete.

Until the orphans are cleared the package CANNOT be dropped — surface this as
a follow-up rather than reporting the clean as fully complete.

---

## Step 6 — Clean Up

```bash
cmd /c del "{RUN_TEMP}\sap_dev_clean_run.ps1"
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
`DEV_CLEAN_TR_RISK`, `DEV_CLEAN_CONFIG_MISMATCH` (anchor gate, Step 2).

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

For a full, truly-clean reset — also deletes the dev TR and clears the
dev-default settings so nothing dangles for the next init:

```
/sap-dev-clean --reset
/sap-dev-init         # self-heals any stale refs, then recreates fresh
```

The chain is two slash commands, not one — atomicity isn't a real
benefit of merging since the failure modes (TR locked, package not
modifiable, wrapper-FM activation refused) are identical either way.
Keeping them separate makes "I want to clean but not reinstall" a
trivial one-step operation.

---

## Limitations

- **TR deletion is opt-in.** By default the TR is presumed to host other work
  and is left alone. `--reset` (or legacy `--force`) deletes the dev TR via
  `/sap-se01 delete`, still with explicit per-call confirmation of its `E071`
  contents, and refuses if the TR holds non-sap-dev-init objects. The `/sap-se01`
  delete mode is two-phase (it empties the request of object entries, then drops
  it — SAP refuses to delete a non-empty request); since 3a–3e already removed
  the objects, the empty-phase is a no-op here and nothing is orphaned. If the
  delete cannot complete (released TR, or a task that won't empty), Step 4 still
  clears the TR reference so the next `/sap-dev-init` self-heals — see Step 3f.
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
