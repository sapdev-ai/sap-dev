# Windows shell & encoding FAQ (operators)

Background for running the sap-dev skills on Windows: which shell to launch from,
why CJK sometimes mojibakes, and what (not) to change. The *source-file* encoding
rules live in `contributing/source_encoding_policy.md`; this is the operator-facing
companion to it.

## TL;DR
- Launch `claude` from **whatever shell you like** — it does not change how the skills run.
- The skills always use **Windows PowerShell 5.1** + 32-bit `cscript`; **pwsh is not required**.
- CJK correctness comes from the **skills** (explicit UTF-8 file I/O + RFC), not from your terminal.
- Do **not** flip `chcp` or the system locale to UTF-8 as a "fix" — it breaks legacy/SAP tools.
- To *see* CJK on screen: use **Windows Terminal + a CJK font** (no install on Windows 11).

## 1. Does it matter whether I open Claude from cmd, PowerShell, or pwsh?
Not for correctness. Claude Code picks its own runtimes regardless of the launching shell:
the **Bash tool** runs in **git-bash**, and the **skills** invoke **Windows PowerShell 5.1**
(`powershell`, not `pwsh`) plus **32-bit `cscript`**. So encoding behaviour and skill results
are identical across cmd / PowerShell / pwsh.

What *does* differ:
- **Environment inheritance** — variables set in your shell/profile pass to Claude. Set
  `SAPDEV_AI_WORK_DIR` at the **OS-user level** so every shell inherits it.
- **Which profile loads** — cmd: none; PS 5.1 and pwsh load *different* `$PROFILE` files.
- **Rendering** (font / Unicode) — best in Windows Terminal.

## 2. The three layers: shell → console → terminal
Encoding questions stay confusing until you separate these:

| Layer | Process | Owns |
|---|---|---|
| **Shell** | `cmd` / `powershell.exe` / `pwsh.exe` | its own default text encoding for files & pipes |
| **Console** | `conhost.exe`, or `OpenConsole.exe` (ConPTY) under Windows Terminal | the **code page** (`chcp`), the Console API (`WriteConsoleW`), the screen buffer |
| **Terminal** | `WindowsTerminal.exe` (or classic conhost's own renderer) | the window, **font**, pixel rendering |

Your shell's stdout is a **console handle** pointing at the console (conhost/ConPTY); the
console turns output into a text stream that the **terminal** renders. With Windows Terminal
you can see them as separate processes (`tasklist`): one `WindowsTerminal.exe` plus several
`OpenConsole.exe`.

## 3. Console code page vs. file encoding — two different knobs
- **`chcp`** sets the **console** code page — a property of the console, **shared by any shell
  in it** (on a Japanese box it defaults to **932**, identical for cmd/PS/pwsh).
- Each **shell** has its *own* default encoding for **files and pipes**: **PowerShell 5.1 =
  ANSI (932)**, **pwsh = UTF-8**. *This* is what garbles a UTF-8 file when PS 5.1 reads it with
  no `-Encoding`.

Console CP governs **display**; the shell's file-encoding governs **reads/writes**. They are
independent — `chcp 65001` makes the console *display* UTF-8 but does **not** change PS 5.1's
932 file-read default. Fix file reads with explicit **`-Encoding UTF8`**, not `chcp`.

## 4. `chcp` and `chcp.com`
`chcp` = "Change Code Page." `chcp.com` is an ordinary Windows **PE executable** that merely
wears a legacy `.com` extension (in `System32` / `SysWOW64`). cmd resolves it via `PATHEXT`
(`.COM` before `.EXE`); git-bash needs the explicit `chcp.com`.

**Scope of a code-page change — only the last row is an OS-level change:**

| Scope | How | OS-level? | Reboot? |
|---|---|---|---|
| this console session | `chcp 65001` | No | No |
| this process's I/O | `[Console]::OutputEncoding=…` / pwsh defaults / `cscript //U` | No | No |
| your future shells | cmd Autorun registry / PowerShell `$PROFILE` | No (user config) | No |
| **system default, every app** | "Beta: Use Unicode UTF-8" / Change system locale | **Yes** | **Yes** |

**Do not** flip `chcp` (or the system locale) to UTF-8 as a fix: it only helps UTF-8-emitting
tools, **breaks** legacy / non-Unicode tools that assume the ANSI code page (which on a
Japanese SAP box can include SAP GUI itself), and does nothing for captured-pipeline mojibake.

## 5. Is Windows Terminal "the console"?
No. Windows Terminal is the **terminal** (the window / renderer). The **console** behind it is
`OpenConsole.exe` / `conhost.exe` (ConPTY) — that is what owns the code page and answers
`WriteConsoleW`; Windows Terminal just renders the resulting text stream with your font. (In
the classic setup with no Windows Terminal, one `conhost.exe` plays *both* roles, which is why
people loosely call the window "the console.")

So **terminal = rendering, console = code page + API, shell = encoding** — three things.
For *seeing* CJK you need the terminal to render Unicode with a CJK-capable font; the encoding
correctness is a separate, upstream concern.

## 6. Deployment baseline (customers)
- Supported runtime: **Windows PowerShell 5.1** + SAP GUI + SAP NCo. **pwsh is NOT required**
  and is never invoked by the skills.
- **CJK correctness** is built into the skills — explicit `-Encoding UTF8`, `ChrW()` in VBS,
  `ADODB.Stream` UTF-8 files, RFC (UTF-16 in .NET), and `GUI_UPLOAD codepage='4110'`. It does
  **not** depend on the console code page or the launch shell, so customers install nothing extra.
- **Display** of CJK is optional polish: Windows Terminal (pre-installed on Windows 11) hosts
  PS 5.1 fine, or set `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8` in a PS 5.1
  `$PROFILE` — both no-install.

## See also
- `contributing/source_encoding_policy.md` — the *source-file* encoding rules: ASCII-first,
  `ChrW()` for runtime non-ASCII, the cscript **console-vs-redirected** output behaviour, and
  using UTF-8 files / RFC to carry CJK *data*.
- `docs/settings-local-faq.md` — settings / `work_dir` onboarding.
