# SAP GUI Language Independence Rules (MANDATORY)

These rules apply to **every** skill that drives SAP GUI through VBScript /
SAP GUI Scripting. Skills MUST honor them without exception. Treat any
conflicting instruction in a skill body as overridden by this file.

---

## Why this matters

Recorded VBScripts (whether captured by SAP GUI Scripting Recorder or
hand-written from an EN logon session) typically use **two kinds** of
identifiers:

1. **Stable across logon languages**
   - Component IDs — `wnd[0]/tbar[1]/btn[5]`, `wnd[0]/usr/ctxtRS38L-NAME`,
     `wnd[0]/mbar/menu[3]/menu[9]`
   - Status-bar `MessageType` codes — `S` (success), `W` (warning),
     `E` (error), `I` (info), `A` (abend)
   - Function keys / VKey codes — `sendVKey 0` (Enter), `11` (Save),
     `27` (Activate, Ctrl+F3), `26` (Ctrl+A)
   - Transaction codes — `/nSE37`, `/nSE11`
   - DDIC field names — `RS38L-NAME`, `RSFBPARA-PARAMETER`, `KO008-TRKORR`
   - Toolbar button **IDs** — `tbar[1]/btn[27]`

2. **Localised — change per logon language**
   - Window titles — `"Function Builder: Change <FM>"` (EN) vs
     `"ファンクションビルダ: 変更 <FM>"` (JA) vs `"功能模块编辑器: 修改 <FM>"` (ZH)
   - Button labels (`btn.Text`) and tooltips (`btn.Tooltip`) — e.g.
     `"Continue (Enter)"` vs `"続行 (Enter)"`
   - Status-bar **text** — `"Object(s) activated"` vs
     `"オブジェクトが有効化されました"`
   - Menu-item labels (`menu.Text`)
   - GuiLabel text and column headers in ALV grids
   - Modal window titles for popups (`Inactive Objects for <USER>` →
     `<USER> の非アクティブオブジェクト`)

A skill that branches on the **localised** kind will silently break when the
operator (or a CI agent) logs on in a non-EN language, even though every
component ID still resolves. This has bitten us before — see the activation
popup investigation in `sap-se37-update`.

---

## Rule 1 — Identify by ID, never by displayed text

When you need to **find** a control:
- ✅ `findById("wnd[0]/tbar[1]/btn[27]")` — language-independent
- ✅ `findById("wnd[1]/usr/btnSPOP-VAROPTION1")` — DDIC name, stable
- ❌ `For Each btn In tbar.Children: If btn.Text = "Activate" Then ...` —
  breaks under JA/DE/ZH/etc.
- ❌ `If oSession.findById("wnd[1]").Text = "Inactive Objects for JDOE"` —
  title is translated

When you need to **act on** the control: prefer the **VKey** equivalent over
the menu item text:
- ✅ `sendVKey 27` (Activate) instead of `mbar/menu[X]/menu[Y].select`
- ✅ `sendVKey 11` (Save) instead of `Save` menu navigation
- ✅ `sendVKey 26` (Ctrl+A = Select All) on a worklist popup
- ✅ `sendVKey 12` (Cancel / F12)

Menu indices (`menu[3]/menu[9]/menu[3]/menu[0]`) are positional and **also
stable** across languages on the same SAP release — they only change with
GUI version / patch level. Prefer them over text-matching menus.

---

## Rule 2 — Status-bar checks: use `MessageType`, not text

The 1-character `MessageType` code is the same in every language:

| Code | Meaning |
|---|---|
| `S` | Success |
| `W` | Warning |
| `E` | Error |
| `I` | Information |
| `A` | Abend (terminate) |
| `""` (empty) | No message |

```vbs
sType = oSession.findById("wnd[0]/sbar").MessageType
If sType = "E" Or sType = "A" Then
    WScript.Echo "ERROR: SAP reported [" & sType & "]: " & _
                 oSession.findById("wnd[0]/sbar").Text
    WScript.Quit 1
End If
```

❌ **Never** branch on substrings of `sbar.Text` such as `"created"`,
`"activated"`, `"no entries"`. They are translated. The legacy offenders
(`sap_se38_check.vbs`, `sap_function_group_gui_create.vbs`) were migrated to
`MessageType` / structural checks on 2026-07-10, and
`scripts/check-consistency.mjs` now fails the build on new curated-literal
branching. Where the exact text is genuinely needed, use the patterns in
Rule 4 below.

---

## Rule 3 — Detect popups by ID, not by title

To check whether a popup appeared:

```vbs
' ✅ Language-independent
If InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0 Then ...

' ✅ Language-independent — probe a known control
On Error Resume Next
Set oCtl = oSession.findById("wnd[1]/usr/ctxtKO008-TRKORR")
If Err.Number = 0 And Not oCtl Is Nothing Then
    ' This is the TR popup
End If
On Error GoTo 0
```

❌ Never:
```vbs
If oSession.findById("wnd[1]").Text = "Prompt for Workbench request" Then ...
If InStr(oSession.findById("wnd[1]").Text, "Inactive Objects") > 0 Then ...
```

To **distinguish between** different popups that all live at `wnd[1]`,
probe for a **DDIC field name** or a **typed control** that only that popup
contains (e.g. `KO008-TRKORR` for the TR-prompt, `RSEUAP-DEVCLASS` for the
package prompt, `RSETX-MASTERLANG` for the language popup).

---

## Rule 4 — When you DO need to read text, log it but don't branch on it

It is fine to **echo** localised text for diagnostics:

```vbs
WScript.Echo "INFO: Status [" & sType & "]: " & _
             oSession.findById("wnd[0]/sbar").Text
```

…but the control flow above must use `sType` (the code), not the text.

If a skill genuinely must extract semantic information from localised text
(e.g. parse a generated number out of `"Function module Z_FOO created"`),
prefer:

1. Reading the underlying SAP table via RFC_READ_TABLE (e.g. `TFDIR` for
   FM existence, `TADIR` for object directory) — language-independent.
2. Calling a BAPI / function module that returns structured fields.
3. Using a regex that only depends on the **identifier** (the `Z*` name,
   the TR id `<SID>K\d+`), not the surrounding sentence.

---

## Rule 5 — Recording new VBScripts

When you record a new SAP GUI scripting reference VBS:

1. Record it from an **EN** logon session (the de-facto baseline). Comments
   in the resulting VBS will read naturally in the codebase.
2. Immediately after recording, **scan the file** and remove or replace any
   text comparisons (`.Text =`, `.Tooltip =`, `InStr(..., "<English text>")`).
   Replace them with ID lookups, `MessageType` checks, or VKey sends per
   Rules 1–3.
3. Add a short header comment listing the **language-independent contract**
   the script depends on: which IDs, which VKeys, which MessageTypes.
4. If a popup must be distinguished from another popup at the same window
   slot, document the **DDIC field name** used as the discriminator.

---

## Rule 6 — Document the language contract in SKILL.md

Each skill's `SKILL.md` should include — at minimum — a short note in the
"Important Caveats" or "Component ID Reference" section that says:

> "All control flow uses component IDs, `sbar.MessageType` codes, and VKey
> codes — every check is language-independent. Status text and popup titles
> are echoed for diagnostics only."

Skills that **must** parse localised text (rare) MUST call this out
explicitly, list the languages tested, and provide an override hook (e.g. a
config-driven regex table at `{custom_url}\<skill>_text_patterns.tsv`).

---

## Rule 7 — Lock the session UI for multi-step write operations

> Strictly speaking this rule is about input-race safety rather than language
> independence, but it lives here because all GUI-scripting safety rules
> belong together. Every reviewer of a new VBS reference script should check
> for both Rules 1–6 and this one in the same pass.

When a script performs a sequence of writes that depends on focus or popup
ordering — source paste, save, activate, multi-row entry, popup-driving — it
MUST lock the session for the duration of that critical section so the user
cannot accidentally steal focus or click an unrelated control.

**Use the shared helpers** at `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_session_lock.vbs`:

```vbs
' Include the helper (token-injected by the wrapper, or hard-coded path)
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()

' --- Lock ---
Dim wasLocked : wasLocked = TryLockSession(oSession)

On Error Resume Next
' ... critical section: source paste, save, activate, popup handling ...
On Error GoTo 0

' --- Release in EVERY exit path ---
ReleaseSession oSession, wasLocked
WScript.Quit 0
```

Why two helpers (not just `LockSessionUI` directly):

- `TryLockSession` degrades gracefully on older SAP GUI builds that don't
  expose the API. A failed lock is logged once and the script continues —
  better than aborting entirely.
- `ReleaseSession` is idempotent and tolerates a `Nothing` session, which
  matters in error-cleanup paths after `Set oSession = Nothing` or when
  the script aborted before `oSession` was assigned.

When to lock:

| Operation | Lock? | Why |
|---|---|---|
| Source paste + save + activate (SE38, SE37, SE24, SE91) | ✅ yes | SendKeys-based paste is focus-sensitive |
| Multi-row entry (SE91 message class, SE54 maintenance view) | ✅ yes | Each row's "New entry" button needs focus |
| Popup-driving (TR popup, language popup, activation worklist) | ✅ yes | Popups steal focus from each other |
| One-shot navigation + read (SE16N table query, RFC_READ_TABLE) | ❌ no | Read-only; nothing to race |
| Long-running operations (deploy, activate that may take seconds) | ❌ no | User may want to alt-tab; lock the press, not the wait |
| Operations that prompt the user mid-flow (TR resolution) | ❌ no | User needs input access |

Pitfalls to plan for:

1. **Always release in every exit path.** VBScript has no try/finally, so
   call `ReleaseSession` before each `WScript.Quit` and at every early
   return. A locked-but-orphaned session is worse than the focus bug you
   were preventing — the user has to kill SAP from Task Manager.
2. **Orphan modal popups are handled by `ReleaseSession`** — no caller
   action needed. If the script reaches the release point with a modal
   popup still on screen (e.g. an unexpected confirmation dialog the
   main flow didn't anticipate), `ReleaseSession` automatically sweeps
   up to 5 chained modals via `sendVKey 12` (F12 / Cancel) before
   calling `UnlockSessionUI`. This guarantees the user gets a clean
   main-window session back, even on abort paths. F12 is chosen because
   it closes popups *without* committing changes — safer than Enter
   on the abort path.
3. **Do not lock across a user-prompt step.** If the script delegates to
   another skill (e.g. `/sap-transport-request`) that asks the user a
   question, the user can't answer while the session is locked. Release
   the lock before the prompt; re-lock after.
4. **Pair with AppActivate guards for SendKeys.** `LockSessionUI` does not
   stop another *application* from grabbing focus. Keep the existing
   `AppActivate`-loop + `Iconified` check pattern for any block that uses
   `WshShell.SendKeys`; the lock is defence-in-depth, not a replacement.
5. **Never assume a lock succeeded.** Always test the return value of
   `TryLockSession`. The script must work whether or not the lock took.

---

## Quick checklist for reviewers

When reviewing a new or modified VBS reference script, reject the change if
any of these patterns appears outside a `WScript.Echo` diagnostic line:

- `.Text =` or `.Text <>` against a window, button, menu, or label
- `.Tooltip =` against any control
- `InStr(... .Text, "<English word>")` on `sbar`, window title, menu, label
- Branching on `findById("...").Text` for a control that does not represent
  user-entered data
- A multi-step write critical section (source paste, save, activate,
  popup-driving) that lacks a `TryLockSession` / `ReleaseSession` wrap
- A `WScript.Quit` reachable from inside a locked critical section that
  isn't preceded by `ReleaseSession` (Rule 7)

Acceptable patterns:

- `findById("wnd[0]/sbar").MessageType = "E"`
- `findById("wnd[0]/sbar").MessageType <> ""`
- `InStr(oSession.ActiveWindow.Id, "wnd[1]") > 0`
- `findById("wnd[1]/usr/ctxt<DDIC-NAME>")` existence probe
- `sendVKey <code>` instead of menu-text navigation
- `TryLockSession(oSession)` ... `ReleaseSession oSession, wasLocked` around
  every multi-step write, with release before every `WScript.Quit`

---

## Known offenders (migration backlog)

### Localised-text branching (Rules 1–4)

Backlog cleared 2026-07-10 — the last two offenders were migrated
(`sap_se38_check.vbs` now decides structurally via program/screen identity;
`sap_function_group_gui_create.vbs` derives the outcome from
`sbar.MessageType`), and `scripts/check-consistency.mjs` now FAILS the build
on new localised-text branching in `references/*.vbs`. Add new entries here
only if a file must temporarily ship with a known violation.

**Documented Rule-6 exceptions** (multi-locale matchers, listed in the
checker's `LOCALE_LITERAL_EXEMPT` where they trip the curated-literal gate):

| File | Why text matching is unavoidable |
|---|---|
| `sap-atc/references/sap_atc_check_run_status.vbs` | ATC Run Monitor state cell exposes no MessageType; icon-ID prefixes stay authoritative, EN/JA/ZH tooltip stems add recall |
| `sap-se24/sap_se24_change_props.vbs`, `sap-se38/sap_se38_change_attrs.vbs`, `sap-se37/sap_se37_change_attrs.vbs`, `sap-se37/sap_se37_reassign_fugr.vbs`, `sap-se91/sap_se91_change_props.vbs` | Generic message popup (`txtMESSTXT1..4` + OK) has no locale-stable control/icon/MessageType; fatal-popup classifier matches EN + ChrW-built JA/ZH lock/error wording |

### Missing session lock (Rule 7)

Bulk migration completed via `tools/migrate_session_lock.py` — see that
script's `RETROFITS` dict for the per-file boundaries (lock anchor +
release anchor) used at retrofit time. **20 files retrofitted** across
SE38 / SE37 / SE24 / SE11 / sap-project (test-data skills). The script is idempotent: re-running
it is safe (skips files that already contain `TryLockSession`).

Still pending (not retrofitted):

| File / pattern | Reason |
|---|---|
| `sap-se91/references/sap_se91_check.vbs` (when extended to write) | Currently read-only; defer until it gains a write path |
| `sap-se11/references/sap_se11_*_update.vbs` (9 files) | Not in the original explicit backlog. Same shape as the matching `*_create.vbs`; retrofit when next touched, or extend `tools/migrate_session_lock.py` `RETROFITS` and re-run |
| `sap-project/skills/{sap-bp,sap-mm01,sap-va01}/references/sap_*_update.vbs` (3 files) | Same as SE11 updates above |

To retrofit additional files:

1. Add the file path + lock/release anchor regexes to `RETROFITS` in
   `tools/migrate_session_lock.py`.
2. Run `python tools/migrate_session_lock.py --dry-run` to preview.
3. Run without `--dry-run` to apply.
4. The script also patches the matching `SKILL.md` token-replacement block
   when the Get-Content path is a direct literal. For SKILL.md flows that
   use a parameterised `$tpl` variable, add the
   `'%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_lock.vbs'`
   replacement line manually.

Do not add new offenders.
