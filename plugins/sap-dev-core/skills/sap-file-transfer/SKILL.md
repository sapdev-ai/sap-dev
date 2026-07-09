---
name: sap-file-transfer
description: |
  Transfers files between the local PC and the SAP application server, and
  lists app-server directories. Four modes: upload (CG3Z, PC -> app server),
  download (CG3Y, app server -> PC), list and exists (headless RFC via
  EPS2_GET_DIRECTORY_LISTING - no AL11 scraping). Text (ASC) or binary (BIN)
  transfer, explicit --overwrite flag, popup-guarded (overwrite Query,
  cannot-open-file Information popup), locale-independent (all outcomes read
  via control IDs + MessageType, verified for JA logons). Wires the SAP GUI
  Security precheck/sidecar around the local-file IO. Closes the
  file-interface test loop: upload test input -> /sap-run-report -> list ->
  download output -> diff against the spec's expected output (golden rows /
  Mapping (File Out)). No transport request involved - this skill touches
  no repository object.
  Typical asks: "upload <file> to the SAP server", "download /tmp/x from S4D",
  "list /usr/sap/trans", "does /tmp/out.txt exist on the app server".
  Prerequisites: active SAP GUI session (use /sap-login first) for
  upload/download; SAP NCo 3.1 (32-bit) in GAC for list/exists.
argument-hint: "upload <local-file> <appserver-file> [--binary|--text] [--overwrite] | download <appserver-file> <local-file> [--binary|--text] [--overwrite] | list <appserver-dir> [--mask <pattern>] | exists <appserver-file>   [--session /app/con[N]/ses[M]]"
---

# SAP File Transfer Skill

You move files between the operator's PC and the SAP application server
(CG3Z / CG3Y) or list app-server directories headlessly over RFC.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/language_independence_rules.md` | *(rule)* | GUI-scripting language independence — the drivers key every outcome on control IDs + `MessageType`; localized text appears only inside `WScript.Echo` diagnostics |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/sap_gui_security_handling.md` | *(rule)* | Both transfer modes are SAP-GUI-side local-file IO (upload READS a PC file, download WRITES one) → can raise the modal "SAP GUI Security" dialog, which suspends the whole Scripting API |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_precheck.ps1` | — | Read-only `saprules.xml` probe before the transfer (`-Access r` for upload, `-Access w` for download) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_gui_security_sidecar.ps1` | — | OS-level watcher that auto-dismisses the SAP GUI Security dialog; pre-arm when the precheck says `NOT_COVERED` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_attach_lib.vbs` | `%%ATTACH_LIB_VBS%%` | Parallel-safe session attach (Tier 3 contract) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_session_lock.vbs` | `%%SESSION_LOCK_VBS%%` | Session lock around the fill+execute critical section; release sweeps orphan modals |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | — | NCo connect helpers, dot-sourced by `sap_file_list.ps1` (list/exists) |
| `<SKILL_DIR>/references/sap_file_transfer_upload.vbs` | — | CG3Z driver. Tokens: `%%LOCAL_FILE%%`, `%%REMOTE_FILE%%`, `%%TRANSFER_MODE%%`, `%%OVERWRITE%%` (+ attach/lock tokens) |
| `<SKILL_DIR>/references/sap_file_transfer_download.vbs` | — | CG3Y driver. Same tokens; execute button is btn[13] (vs btn[14] in CG3Z) |
| `<SKILL_DIR>/references/sap_file_list.ps1` | — | `list` / `exists` over RFC: `EPS2_GET_DIRECTORY_LISTING` with legacy `EPS_` fallback. 32-bit PowerShell |

Probed against: S/4HANA 1909 (S4D), SAP GUI 7.70 — CG3Z dialog `SAPLC13Z`/1020,
CG3Y dialog `SAPLC13Z`/1010, overwrite Query `SAPLSPO1`/300, cannot-open-file
Information popup `SAPMSDYP`/10. Golden baselines in `references/*.screens.json`.

---

## Step 0 — Resolve Work Directory

**Resolve `work_dir` via the env-aware helper** — do NOT take `work_dir` from a
direct `settings.json` read (that ignores the `SAPDEV_AI_WORK_DIR` env var and
`userconfig.json`):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` (base — ONLY for
`Get-SapCurrentSessionPath -WorkTemp`). Write this skill's OWN scratch (the
generated `*_run.vbs`, sidecar log) under `{RUN_TEMP}`.

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_file_transfer_run.json" -Skill sap-file-transfer -ParamsJson "{\"mode\":\"<MODE>\",\"remote\":\"<appserver-path>\"}"
```

---

## Step 1 — Parse Arguments

| Mode | Direction | Required args | Flags |
|---|---|---|---|
| `upload` | PC → app server (CG3Z) | `<local-file> <appserver-file>` | `--text` (default) / `--binary`, `--overwrite` |
| `download` | app server → PC (CG3Y) | `<appserver-file> <local-file>` | `--text` (default) / `--binary`, `--overwrite` |
| `list` | RFC read | `<appserver-dir>` | `--mask <pattern>` |
| `exists` | RFC read | `<appserver-file>` | — |

- `--binary` → `TRANSFER_MODE=BIN` (byte-exact); `--text` → `ASC`. **Text mode
  strips trailing blanks per line and converts line endings / codepage**
  (probed: an 86-byte CRLF file with 2 trailing spaces came back 84 bytes).
  Interface files consumed by `OPEN DATASET ... IN TEXT MODE` want `ASC`;
  byte-fidelity round trips want `BIN`.
- `--overwrite` → `OVERWRITE=X`. Without it, an existing target makes the run
  exit 4 (`FILE_TARGET_EXISTS`) — deliberately loud, never silent.
- `--session "<path>"` overrides the pinned-session resolution.
- App-server paths pass to SAP **verbatim** — separator style must match the
  server OS (`/tmp/...` on Unix, `D:\...` on Windows app servers).
- No transport request is involved in any mode.

---

## Step 1.5 — Target-Identity Guard

File paths are system-specific; a transfer landing on the wrong SAP system is
silent data misplacement. Resolve the pinned profile and echo the target:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; $p = Get-SapCurrentConnectionProfile -WorkTemp '{WORK_TEMP}'; Write-Output ('TARGET: sid=' + $p.system_name + ' client=' + $p.client + ' user=' + $p.user)"
```

If the user named a system in their request (e.g. "upload to EC2") and the
echoed SID/client disagrees, STOP: tell them to run
`/sap-login --switch <SID>` first. Do not proceed on a mismatch.

---

## Step 2 — `list` / `exists` (RFC, no GUI) — then Done

Run under **32-bit PowerShell** (NCo 3.1 lives in the 32-bit GAC):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_file_list.ps1" -Action list -DirName "<appserver-dir>" -Mask "<pattern-or-empty>"
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_file_list.ps1" -Action exists -FilePath "<appserver-file>"
```

Parse the `FILE:` lines + final `STATUS:` line (`OK count=… fm=…` /
`EXISTS` / `NOT_FOUND` / `RFC_ERROR …`). On `RFC_ERROR`, report it and point
at `/sap-doctor` (rfc group) — do NOT fall back to AL11 GUI scraping; the
transfer modes below stay available without RFC. Log end and **Done** for
these modes.

---

## Step 3 — Pre-flight for Transfer Modes (GUI session + GUI Security)

1. **GUI session live?**

```bash
C:/Windows/SysWOW64/cscript.exe //NoLogo "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_check_gui_login_status.vbs"
```

If not `LOGGED_IN`, stop: run `/sap-login` first.

2. **SAP GUI Security coverage.** Upload = SAP GUI **reads** the local file
(`-Access r`); download = **writes** it (`-Access w`):

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_precheck.ps1" -Path "<local-file>" -Access <r|w>
```

- `ALLOWED` → proceed directly.
- `NOT_COVERED` → launch the sidecar as a parallel watcher BEFORE the VBS
  (per `sap_gui_security_handling.md`), then run Step 4 while it watches:

```bash
powershell -ExecutionPolicy Bypass -Command "Start-Process powershell -WindowStyle Hidden -PassThru -RedirectStandardOutput '{RUN_TEMP}\sidecar_out.txt' -ArgumentList '-ExecutionPolicy','Bypass','-File','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_gui_security_sidecar.ps1','-TimeoutSeconds','60' | Select-Object -ExpandProperty Id"
```

After the VBS, read `{RUN_TEMP}\sidecar_out.txt`: `FOUND_BUT_STUCK` must be
surfaced (the transfer likely did not run), `DISMISSED:WIN32` means a rule was
persisted (tell the user), `TIMEOUT` is fine when the precheck was wrong-side
conservative. Keeping local paths under `{work_dir}` avoids the dialog
entirely (the dev-init grant covers it `rw`).

---

## Step 4 — Run the Transfer Driver

Pick the variant, substitute tokens, run via **32-bit cscript**:

```powershell
$skillDir = '<SKILL_DIR>'; $runTemp = '{RUN_TEMP}'; $mode = '<upload|download>'
$variantPath = & "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_select_vbs_variant.ps1" `
    -ReferencesDir "$skillDir\references" -BaseName "sap_file_transfer_$mode"
if ($LASTEXITCODE -ne 0 -or -not $variantPath) { Write-Error "no VBS variant for mode=$mode"; exit 1 }

$content = [System.IO.File]::ReadAllText($variantPath, [System.Text.Encoding]::UTF8)
$content = $content.Replace('%%LOCAL_FILE%%',    '<local-file>')
$content = $content.Replace('%%REMOTE_FILE%%',   '<appserver-file>')
$content = $content.Replace('%%TRANSFER_MODE%%', '<ASC|BIN>')
$content = $content.Replace('%%OVERWRITE%%',     '<X-or-empty>')
$content = $content.Replace('%%SESSION_PATH%%',  '<--session value or empty>')
$content = $content.Replace('%%ATTACH_LIB_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs')
$content = $content.Replace('%%SESSION_LOCK_VBS%%', '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs')
. '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'
$env:SAPDEV_SESSION_PATH = Get-SapCurrentSessionPath -WorkTemp '{WORK_TEMP}'
[System.IO.File]::WriteAllText("$runTemp\sap_file_transfer_run.vbs", $content, [System.Text.UnicodeEncoding]::new($false, $true))
C:\Windows\SysWOW64\cscript.exe //NoLogo "$runTemp\sap_file_transfer_run.vbs"
```

**Outcome contract** (parse stdout + exit code — never infer success from
silence):

| Exit | Marker line | Meaning → error_class |
|---|---|---|
| 0 | `FILE_TRANSFER: UPLOADED\|DOWNLOADED …` + `DONE` | transferred; sbar MessageType was `S` |
| 3 | `ERROR: …` | tcode blocked / SAP `E`/`A` / no success message → `FILE_TCODE_UNAVAILABLE` or `FILE_TRANSFER_FAILED` |
| 4 | `FILE_TRANSFER: TARGET_EXISTS …` | target exists, `--overwrite` not given → `FILE_TARGET_EXISTS` (suggest rerun with `--overwrite`) |
| 5 | `FILE_TRANSFER: OPEN_ERROR msg=…` | source unreadable / path invalid (OS errno in msg) → `FILE_SOURCE_MISSING` |

---

## Step 5 — Verify

- **upload + RFC available** — `exists` on the target
  (`sap_file_list.ps1 -Action exists -FilePath <appserver-file>`): `BIN` →
  reported size must equal the local byte count; `ASC` → existence + size > 0
  (text conversion legitimately changes the byte count).
- **download** — the local file must exist; `BIN` → compare
  `Get-FileHash` against a reference when doing a round trip.
- **RFC down** — round-trip re-download to `{RUN_TEMP}` and hash-compare
  (`BIN` exact; `ASC` after line-ending normalization), or record
  `VERIFY: SKIPPED reason=rfc_unavailable`.

Report one line: `VERIFY: RFC_SIZE_OK|EXISTS_OK|ROUNDTRIP_HASH_OK|SKIPPED reason=…` —
a skipped verify must never read as verified.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_file_transfer_run.json" -Status SUCCESS -ExitCode 0
```

On failure: `-Status FAILED -ExitCode 1 -ErrorClass <CLASS> -ErrorMsg "<short>"`
with `<CLASS>` from: `FILE_TCODE_UNAVAILABLE`, `FILE_TRANSFER_FAILED`,
`FILE_TARGET_EXISTS`, `FILE_SOURCE_MISSING`, `FILE_LIST_RFC_UNAVAILABLE`,
`NO_SESSION` (see `shared/rules/error_classes.md`).

---

## Gotchas (probed / by design)

1. **The CG3Y/CG3Z UI is a modal dialog that stays open after success** — the
   drivers read the `wnd[0]` status bar while `wnd[1]` is still up, then close
   it with Cancel (btn[12]). Success is ONLY `MessageType=S`; a declined
   overwrite leaves an **empty** status bar.
2. **CG3Y checks the local target's overwrite BEFORE reading the source** — a
   missing app-server file surfaces only after the Query is answered. The
   local target is NOT touched when the source turns out unreadable (probed).
3. **Authorizations**: `S_TCODE` CG3Y/CG3Z + `S_DATASET` (ACTVT 33 read for
   download, 34 write for upload); SPTH / `S_PATH` may additionally restrict
   paths. `/sap-doctor` probes these via the `file_transfer_*` capability rows.
4. **Multi-app-server systems**: instance-local paths (e.g. `DIR_HOME`) belong
   to whichever server the GUI session logged on to. Use a shared path
   (`DIR_GLOBAL`, `/usr/sap/trans`) or pin the connection when a batch job on
   another instance must read the file.
5. **JA/ZH logons**: all branch detection is control-ID based
   (`btnSPOP-OPTION1`, `txtMESSTXT1`, `chkRCGFILETR-IEFOW`) — no text matching.
   The Information-popup text echoed in `OPEN_ERROR msg=` is localized and is
   for the operator's eyes only, never parsed.
6. **Large files**: CG3Y/CG3Z stream through the GUI connection — fine for
   test/interface files (KB–MB); for bulk data prefer an application-level
   interface.
