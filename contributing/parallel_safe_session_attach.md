# Parallel-Safe & Multi-Connection Session Attach for SAP-Driving VBS

**Applies to**: every operational `.vbs` template under
`plugins/<plugin>/skills/<skill>/references/*.vbs` that drives SAP GUI
via `GetObject("SAPGUI") + GetScriptingEngine`.

**Enforced by**: `sap-dev/scripts/check-consistency.mjs` — runs in CI;
fails the build on legacy patterns.

---

## TL;DR for new skill authors

When writing a new SAP-driving VBS template:

1. **Declare `Const SESSION_PATH = "%%SESSION_PATH%%"`** in the Const block near the top.
2. **Include `%%ATTACH_LIB_VBS%%`** via the standard `ExecuteGlobal` block, before any other shared-include like `%%SESSION_LOCK_VBS%%`.
3. **Attach with `Set oSession = AttachSapSession(SESSION_PATH)`** — that's the entire attach. Do NOT roll your own `For Each oCandidate In oApp.Children` loop.
4. **In the wrapping SKILL.md**, substitute the two new tokens and set `SAPDEV_PIN_FILE` so the helper finds the user's pin (see "Skill wrapper convention" below).

If you forget any of these, CI fails. If you intentionally need a different attach pattern (bootstrap before SAPGUI exists, custom session field, etc.), add the file to `TIER3_EXEMPT_VBS` in `check-consistency.mjs` with a comment explaining why.

---

## Why this rule exists

Before this contract, every operational VBS contained a copy of:

```vbs
Set oSession = Nothing
For Each oCandidate In oApplication.Children
    For Each oSessIter In oCandidate.Children
        Set oSession = oSessIter
        Exit For
    Next
    If Not (oSession Is Nothing) Then Exit For
Next
```

This grabs the **first session of the first connection**. Two failure modes:

1. **Parallel skill runs trample each other.** If two skills run concurrently (e.g. via `/sap-gui-skill-scaffold --parallel` or any other fan-out), both grab `/app/con[0]/ses[0]` and their actions interleave.
2. **Multi-connection users silently miss-target.** A user with DEV (`/app/con[0]`) + QAS (`/app/con[1]`) attached, or two different clients (100 vs 200) of the same system, ALWAYS gets `con[0]` regardless of which they meant. A skill targeted at QAS silently writes to DEV.

The shared helper at `plugins/sap-dev-core/shared/scripts/sap_attach_lib.vbs` fixes both. It exposes one function:

```vbs
Function AttachSapSession(sHint)
    ' Returns a GuiSession bound by the following resolution order:
    '   1. sHint                       — explicit /app/con[N]/ses[M] from caller
    '   2. SAPDEV_SESSION_PATH env var — same shape
    '   3. SAPDEV_PIN_FILE env var     — pin file's session_path field
    '   4. Sole-connection auto-default — only when exactly 1 connection attached
    '   5. Refuse loud with helpful error — multi-conn ambiguity
End Function
```

Strategies 1, 2, 3 take full session paths and **never silently retarget**. Strategy 4 keeps the 99% single-connection case zero-friction. Strategy 5 prevents the multi-connection-cross-target bug class.

---

## The canonical VBS pattern (copy this)

```vbs
Option Explicit

Const SOME_PARAM    = "%%SOME_PARAM%%"
Const ANOTHER_PARAM = "%%ANOTHER_PARAM%%"
Const SESSION_PATH  = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

Const VKEY_ENTER    = 0
' ... other VKey constants ...

' Include shared helpers. Order matters: attach first; session-lock's
' pre-unlock popup sweep reads from oSession.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()   ' only if write critical section

' ------ 1. Attach to existing SAP GUI session (via shared attach helper) ----
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' ------ 2. ... your transaction logic here, using oSession.findById(...) ...
```

That's the entire attach. **No `Dim oSAPGUI, oApplication`, no `For Each` loop, no error-handling stanza** — the helper does all of that internally and either succeeds or `WScript.Echo "ERROR: ..."` + `Quit 2`.

For a clean reference, see `plugins/sap-dev-core/skills/sap-se38/references/sap_se38_check.vbs`.

---

## The canonical SKILL.md wrapper convention (copy this)

Every SKILL.md PowerShell block that generates a runtime VBS must include the Phase 3.5 plumbing block immediately before the `Set-Content`/`WriteAllText` line:

```powershell
$content = Get-Content '<SKILL_DIR>\references\sap_<skill>_<mode>.vbs' -Raw
$content = $content -replace '%%SOME_PARAM%%','THE_SOME_PARAM'
# ... other parameter substitutions ...

# Phase 3.5 session-attach plumbing.
$sessionPath = ''   # set to the parsed --session value if supplied
$content = $content -replace '%%SESSION_PATH%%', $sessionPath
$content = $content -replace '%%ATTACH_LIB_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_attach_lib.vbs'
$env:SAPDEV_PIN_FILE = '{WORK_TEMP}\sap_active_session.json'

Set-Content '{WORK_TEMP}\sap_<skill>_<mode>_run.vbs' $content -Encoding Unicode
```

- `$sessionPath = ''` is intentional default — the helper auto-resolves via `SAPDEV_PIN_FILE` → sole-connection → refuse.
- Setting `$env:SAPDEV_PIN_FILE` gives the helper the path to the user's pin file (created by `/sap-login`) so single-connection callers stay zero-friction.
- If the SKILL.md is wrapping a write-class skill that also includes `%%SESSION_LOCK_VBS%%`, leave that substitution in — it's complementary, not redundant.

---

## Exempt files (intentionally NOT migrated)

These four files in `plugins/sap-dev-core/shared/scripts/` use their own attach logic by design. Do not migrate them, and do not add new files to this list without a clear reason:

| File | Why exempt |
|---|---|
| `sap_login.vbs` | Bootstrap. Runs BEFORE SAPGUI is guaranteed to be running — `AttachSapSession` assumes the engine is already alive. |
| `sap_check_gui_login_status.vbs` | Single-purpose pre-flight probe; structured differently. |
| `sap_gui_security_warmup.vbs` | One-shot dialog warmup at `/sap-dev-init` Step 1b. Runs before any user task. |
| `sap_login_capture_active_session.vbs` | Captures the just-logged-in session as part of the `/sap-login` bootstrap. |
| `sap_gui_object_details.vbs` | Has its own `findById(SESSION_PATH)` from the Phase-1 sentinel-collision fix. Uses the `Chr(37)` sentinel idiom to detect unsubstituted tokens. |
| `sap_gui_probe_action.vbs` | Resolves session from the action-JSON `"session"` field (different contract: per-action explicit pin). |
| `sap_attach_lib.vbs` | The helper itself. |

If you write a new bootstrap-style file that legitimately needs custom attach, add it to `TIER3_EXEMPT_VBS` in `sap-dev/scripts/check-consistency.mjs` with an inline comment.

---

## Common gotchas

1. **Don't inline the literal `%%SESSION_PATH%%` token as a sentinel comparison.** The PowerShell wrapper's `.Replace()` is global, so any occurrence of the literal token will be rewritten. If you need to detect "unsubstituted token," build the comparison string at runtime via `Chr(37) & Chr(37) & "SESSION_PATH" & Chr(37) & Chr(37)`. See `sap_gui_object_details.vbs` for the precedent (and the bug it originally hid).
2. **Include order matters when both attach-lib and session-lock are present.** Attach lib MUST load first because session-lock's pre-unlock popup sweep reads from `oSession`. The canonical pattern above gets this right.
3. **The helper handles ALL error paths.** Don't wrap `AttachSapSession(SESSION_PATH)` in your own `If oSession Is Nothing Then ...` — the helper has already `WScript.Quit 2`'d on failure. Adding your own block is dead code.
4. **`SAPDEV_PIN_FILE` is set in PowerShell, read by cscript.** Process env vars cross the boundary, so the cscript child inherits it. Don't try to pass it as an argv arg — the helper specifically looks at the env var.

---

## Verifying compliance

```bash
cd sap-dev
node scripts/check-consistency.mjs
```

Should print:
```
OK: 3 plugins, 49 skills, all manifests aligned at version 0.1.0, Tier 3 attach contract clean
```

On failure, the script lists each non-conforming file with a specific reason. The check covers:

1. Legacy `For Each oCandidate In oApp.Children` (and its variant patterns) → must not appear in non-exempt operational VBS.
2. VBS with `Const SESSION_PATH` but no `%%ATTACH_LIB_VBS%%` include → the helper will be undefined at runtime.
3. VBS that drives SAP GUI (matches `GetObject("SAPGUI")` or `GetScriptingEngine`) but uses neither token → unmigrated.
4. VBS with `%%ATTACH_LIB_VBS%%` include but no `AttachSapSession(...)` call → dead include.
5. SKILL.md that wraps a template requiring `%%ATTACH_LIB_VBS%%` but doesn't substitute it → the runtime VBS will fail to attach.

---

## Related contracts

- **`shared/rules/sap_session_broker.md`** — the broker's CLI contract (`acquire` / `release` / `discover` / `gc` / `list`), v2 multi-connection registry schema, cleanup architecture. Read this when you need to coordinate session ownership across parallel agents.
- **`shared/scripts/sap_attach_lib.vbs`** — the helper itself; well-commented.
- **`shared/scripts/sap_session_broker.ps1`** + **`shared/scripts/sap_session_broker_com.vbs`** — broker implementation.

---

## History

- **Pre-Tier-3** (legacy): every operational VBS had its own attach loop. Parallel runs and multi-connection users both broken.
- **Phase 3.0** (2026-05-14): introduced `sap_attach_lib.vbs`.
- **Phase 3.1**: migrated 4 read-only skills as proof.
- **Phase 3.5**: made the broker multi-connection aware (registry schema v2, new acquire args, attach-lib's pin-file fallback).
- **Phase 3.2 / 3.3 / 3.4**: migrated 19 / 32 / 9 more files across sap-dev-core and sap-tcd plugins, for 100 total.
- **Phase 3.6**: added CI gate at `scripts/check-consistency.mjs` to prevent regression.
