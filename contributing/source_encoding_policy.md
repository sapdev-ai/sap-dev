# Source encoding policy (ASCII-first)

> Architectural rule for the encoding of runtime `.ps1` / `.vbs` files. Read this
> before adding non-ASCII characters to any script under
> `plugins/<plugin>/skills/<skill>/references/` or `plugins/sap-dev-core/shared/scripts/`.
> Lives under `contributing/` (repo authors only — not shipped to end users).
> Surfaced by the non-ASCII guard in `scripts/check-consistency.mjs`.

## TL;DR

- **Committed execution scripts (`.ps1` / `.vbs`) stay ASCII.** Express any
  non-ASCII *runtime* character with `ChrW(&H….)` (VBS) or `[char]0x….` (PS).
- **Localized text is allowed only in diagnostics** (`WScript.Echo` / `Write-*`),
  per `plugins/sap-dev-core/shared/rules/language_independence_rules.md` — and
  even there, prefer ASCII so customer consoles don't mojibake.
- **Markdown / docs / templates stay multilingual.** This policy is about
  *execution scripts*, not prose.
- **Do not bulk-convert the tree to UTF-16 LE BOM** (see "Why not UTF-16
  everywhere"). The one place UTF-16 LE is correct is a `.vbs` *generated at
  runtime* and fed straight to `cscript` (e.g. the login VBS).

## Why — the failure mode

Windows **PowerShell 5.1** (the runtime the skills invoke via
`C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`) and **32-bit
cscript** both read a **BOM-less** `.ps1` / `.vbs` as the host **ANSI codepage**
— *not* UTF-8. (PowerShell 7 changed the no-BOM default to UTF-8; 5.1 did not.)

A non-ASCII character in the source then decodes wrong at load time. An em-dash
`—` is UTF-8 `E2 80 94`; read as CP1252 it becomes `â€"`, as CP932 (Japanese)
`窶覇`-style garbage, as CP936 (Chinese) something else again. This is not
theoretical — it shipped: an em-dash in a string literal in
`sap-migrate/.../sap_cc_usage.ps1` rendered as mojibake inside a generated
`scope.tsv`.

**ASCII bytes (`0x00`–`0x7F`) are identical across UTF-8 and every common ANSI
codepage.** So an ASCII-only source file decodes to the same characters no
matter what encoding the interpreter guesses. That is the entire reason for the
ASCII-first rule: it is the one byte range where a wrong encoding guess cannot
hurt you. It protects real Japanese / Chinese / Western Windows customers, all
of whom run a non-UTF-8 ANSI codepage.

## Capability vs. source-decode (important clarification)

PS 5.1 and cscript are **fully Unicode-capable at runtime.** PowerShell strings
are .NET `System.String` (UTF-16); VBScript strings are `BSTR` (UTF-16); text
coming back from the SAP GUI Scripting COM API arrives as proper UTF-16
regardless of codepage. Comparing SAP-returned Japanese against a literal works
*if that literal was decoded correctly when the file loaded*. The problem is
**only** how the engine decodes the script file off disk:

| Source file encoding | PowerShell 5.1 reads it… | 32-bit cscript reads it… |
|---|---|---|
| **ASCII** (no BOM) | correctly (codepage-invariant) | correctly (codepage-invariant) |
| UTF-8, **no BOM** | as ANSI codepage → **mojibake** | as ANSI codepage → **mojibake** |
| UTF-8 **with BOM** (`EF BB BF`) | correctly | can choke WSH → avoid for `.vbs` |
| UTF-16 LE **with BOM** (`FF FE`) | correctly | correctly (cscript's native Unicode) |
| UTF-16 LE **no BOM** | mis-detected → garbage / parse error | mis-detected → garbage / parse error |

There is also a separate **console output** axis (`chcp` / `$OutputEncoding`)
that can mojibake what you *print* independently of source decoding — but the
debt this policy addresses is entirely the source-decode column. (Two further
axes — runtime *file* I/O and SAP `GUI_UPLOAD` — are covered in *Adjacent
encoding axes* below.)

## Adjacent encoding axes (not source-decode)

The policy here governs how the *interpreter* decodes a committed **script** file.
Two *other* axes produce the same mojibake symptom — keep them distinct. Both were
confirmed live (2026-06-04) on this Japanese / **CP932** SAP box.

### Runtime file I/O in PowerShell 5.1 (data files, not scripts)

Measured machine state — note the console is already UTF-8; the ACP is the culprit:

| Layer | Codepage |
|---|---|
| Console output / input | **65001 (UTF-8)** — already correct |
| System ANSI (ACP) | **932 (Shift-JIS)** — the real culprit |
| System OEM | 932 |
| Shell | Windows PowerShell 5.1 |

The mojibake was **not** a console-output problem (the console is already 65001) — it is a
**file-read** problem. PS 5.1 defaults to the system **ACP (932)** when it reads/writes a
file with no explicit `-Encoding`, so a UTF-8 (no-BOM) file is decoded as Shift-JIS →
garbage; it then *prints* fine because the console is 65001. Same UTF-8 file, two reads:

- `Get-Content` (no `-Encoding`) → `迚ｩ譁吩ｸｻ謨ｰ謐ｮ…` (mojibake)
- `Get-Content -Encoding UTF8` → `物料主数据批量上传Ver54` (correct)

That is exactly why the RFC scripts and `[IO.File]::ReadAllText(…, UTF8)` reads showed CJK
correctly all along, while casual `Get-Content` / `cat` did not.

**Rule (zero-risk, per-process — already our practice): always pass explicit UTF-8 on file I/O.**
- Read: `Get-Content -Encoding UTF8`, or `[IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)`
- Write: `[IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))` (UTF-8, no BOM)

**cscript caveat:** `WScript.Echo` of non-ASCII does not honor the 65001 console cleanly, so
SAP status echoes (e.g. `SAP status: [S] ?�ۏW…`) can still look garbled. Cosmetic — verify
the real outcome via RFC (UTF-8) or a screenshot, never by trusting that echoed text.

### SAP `GUI_UPLOAD` codepage (ABAP-side file reads)

`GUI_UPLOAD … filetype = 'ASC'` with **no** `codepage` means "interpret the file's bytes as
the **logon language's** legacy codepage." A UTF-8 file under a ZH / JA logon is then
*silently* garbled — no error is raised. Live proof, same intended text `中文物料描述AB`:

| File encoding | Program `codepage` | Stored in MAKT-MAKTX | Result |
|---|---|---|---|
| UTF-8 | (none) | `涓枃鐗╂枡鎻忚堪AB` | garbled |
| GBK / cp936 | (none) | `中文物料描述AB` | correct |
| UTF-8 | `'4110'` | `中文物料描述AB` | correct |

- **Fix A (no code change):** match the file to the logon language's codepage (GBK for ZH) —
  the zero-deploy fallback when you cannot change the program.
- **Fix B (robust, preferred):** add `codepage = '4110'` (SAP's number for UTF-8) to the
  `GUI_UPLOAD` call and keep the file **UTF-8 without BOM** → it decodes correctly regardless
  of logon language. Generated ABAP that uploads text should prefer this locale-independent
  form. (Properly an ABAP-codegen concern; recorded here so every encoding axis lives in one
  place.)

## The policy (what to do)

1. **ASCII source for committed `.ps1` / `.vbs`.** No raw `—`, `→`, `…`, smart
   quotes, or CJK in committed execution scripts.
2. **Runtime non-ASCII via escapes.** When a script genuinely needs a non-ASCII
   character at runtime, build it from a code point so the source bytes stay
   ASCII:
   - VBS: `ChrW(&H2026)` for `…`; see `sap_syntax_check_lib.vbs`'s
     `GetSyntaxErrorWord` for the canonical idiom (it assembles localized SAP
     words via `ChrW()`).
   - PS: `[char]0x2026`.
3. **Localized text only in diagnostics**, and even then prefer ASCII. Branching
   logic must key off locale-independent signals (icon-ID prefixes, DDIC field
   names, `MessageType` codes) — see `language_independence_rules.md`. A
   localized literal used in a *comparison* is both a language-independence
   violation and an encoding hazard.
4. **Markdown / docs / `.tsv` templates stay multilingual.** The guard does not
   scan them; multilingual customer-facing content is desired there.
5. **Generated-at-runtime `.vbs` = UTF-16 LE (with BOM).** A VBS written by a
   skill into `{WORK_TEMP}` and fed straight to `cscript` (e.g. `sap-login`'s
   `sap_login_run.vbs`) is written `[System.Text.Encoding]::Unicode` because
   that is cscript's native Unicode encoding and UTF-8-with-BOM breaks cscript.
   Its committed *template* (`sap_login.vbs`) is still read as UTF-8 and stays
   ASCII. Keep that boundary: **committed = ASCII; generated runtime VBS = UTF-16 LE.**
6. **Narrow opt-in if a committed file truly needs non-ASCII bytes** (rare —
   today *no* file does): add a **UTF-8 BOM** to a `.ps1` (the guard accepts it;
   PS 5.1 reads it), or **UTF-16 LE BOM** to a `.vbs` *only after* confirming
   nothing reads it as UTF-8 and its `FSO.OpenTextFile` includes use Unicode
   mode. Prefer `ChrW()` over a BOM.

**Glyph-in-comment exception (deliberate).** A non-ASCII glyph MAY appear in a
*comment* to document the character a `ChrW()` runtime literal builds — as
`sap_syntax_check_lib.vbs` and `sap_atc_check_run_status.vbs` do, e.g.
`Dim JA_ERROR : JA_ERROR = ChrW(&H30A8) & ChrW(&H30E9) & ChrW(&H30FC)  ' エラー = error`.
The *runtime* string stays ASCII; only the comment carries the glyph. Trade-off:
a `.vbs` with glyph comments can never be *cleared* from the guard — cscript
forbids a UTF-8 BOM and UTF-16 LE isn't the guard's opt-in, so ASCII-only is the
sole guard-clean path for a `.vbs`. Such a file therefore stays an informational
warning permanently. Use it only where the glyph genuinely aids the reader
(localized SAP text that's being matched); keep ordinary comments ASCII.

## Why not UTF-16 everywhere

Converting the whole tree to UTF-16 LE BOM looks tempting (PS 5.1 + cscript both
read it fine) but is the wrong tree-wide move:

1. **It fights this guard.** The guard's BOM opt-in is the **UTF-8 BOM only**
   (`EF BB BF`). A UTF-16 LE file starts `FF FE`; the guard reads `0xFF` as a
   non-ASCII byte on line 1 → *every* file flagged. You'd go from 133 warnings to
   ~all files.
2. **It breaks git.** Git treats UTF-16 as binary — no line diffs, painful
   3-way merges. This repo is edited by multiple sessions in parallel
   (see `parallel_safe_session_attach.md`); readable diffs are load-bearing.
3. **It breaks the UTF-8 read pipeline.** Token substitution does
   `[IO.File]::ReadAllText(template, [Encoding]::UTF8)` + `.Replace('%%TOKEN%%', …)`;
   VBS includes do `ExecuteGlobal FSO.OpenTextFile("%%LIB%%",1).ReadAll()` in
   MBCS mode; `check-consistency.mjs` parses with `readFileSync(abs,'utf8')`.
   All assume UTF-8 / ASCII.
4. **Overkill.** Only ~6 genuinely-executed non-ASCII literals exist (below).
   Re-encoding hundreds of files to fix six is a large, conflict-prone churn.
5. **ASCII already solves it for free** — codepage-immune, git-diffable,
   reader-safe, guard-clean — with no per-file-type encoding decisions.

## The CI guard

`scripts/check-consistency.mjs`, "Non-ASCII source guard" (added 2026-06-02).

- **Scope:** every `.ps1` / `.vbs` under each plugin's
  `skills/<skill>/references/` plus `sap-dev-core`'s `shared/scripts/`.
- **Detection:** raw bytes. A leading **UTF-8 BOM** is the explicit opt-in
  (skipped). Otherwise it reports the **first** byte `> 0x7F` per file with its
  1-based line and decoded code point. (So the warning count = number of
  **files** flagged, not number of bad bytes.)
- **Severity:** **informational `WARN`, not a build failure** — the tree carries
  pre-existing debt that predates the guard, so it flags regressions without
  breaking CI or forcing a rewrite. Mirrors the golden-screen baseline gate's
  "ratchet" stance (see `golden_screen_baselines.md`).
- **Ratchet plan:** clean the tree (P1 + P2 below) → *then* promote the guard to
  a hard error (`errors.push(...)`) so new non-ASCII fails CI. Do **not** flip it
  blocking first — 133 pre-existing files would turn the build red instantly.

To clear a file's warning: replace the offending bytes with ASCII (or `ChrW()` /
`[char]` for runtime chars), or — only if non-ASCII is genuinely required — add
the appropriate BOM per the policy table.

## Current debt snapshot (2026-06-04)

`node scripts/check-consistency.mjs` → `133 non-ASCII warning(s)`, build green.
(The count is a **living metric** — it ticked to `134` mid-authoring when a
concurrent session added an em-dash to `sap_update_addon_detect.ps1` /
`sap_log_*.ps1`, which is precisely the regression the guard exists to surface.)

**2026-06-04 cleanup pass.** Count re-verified at `133` — the headline is unchanged
but the *composition* shifted. Two fixes landed:

- `sap_update_addon_se16.vbs` — the success/error summary `WScript.Echo` was a
  *previously unlisted* genuinely-executed literal (`"成功: … エラー: …"`); rebuilt via
  `ChrW(&H6210)&ChrW(&H529F)` (`成功`) and `ChrW(&H30A8)&ChrW(&H30E9)&ChrW(&H30FC)`
  (`エラー`), glyphs kept only in the trailing comment. It stays on the list for that
  comment glyph + a header em-dash — intentional, per the glyph-in-comment exception.
- `sap_change_package_{se11,se24,se37,se38,se91}.vbs` — UTF-8 BOMs removed (a BOM on a
  `.vbs` can choke WSH, per the policy table) and comment/echo `—`→`--`;
  `sap_change_package_cmod.vbs` cleaned in the same pass. All six are now **pure ASCII**
  and off the guard list. (The five had been BOM-*skipped* before, so un-BOMing them
  briefly pushed the count to `139` until the `—`→`--` pass brought it back to `133`.)
  Sibling `sap-se11/references/sap_se11_change_package.vbs` keeps a pre-existing em-dash
  — left for the P2 backlog.
A byte-level scan of every non-ASCII *line* (not just the first per file) across
those files:

| Category | Lines | Runtime impact |
|---|---|---|
| Comments (`'…` / `#…`, incl. trailing) | 658 | **None** — never executed |
| Diagnostic output (`WScript.Echo`, `Write-*`, `L "…"`, `Emit "…"`) | 136 | Cosmetic — message text garbles on a non-UTF-8 console; ASCII keywords intact |
| Already `ChrW()`-safed | 5 | Correct by design |
| Executable code (hand-reviewed) | 62 | Mostly trailing comments / multi-line `Echo` continuations; see below |
| **Total non-ASCII lines** | **861** | |

Code-point mix: em/en-dash 749, arrows 99, CJK 77, ellipsis 5, other 10
(≈85% is `—` / `→` / `…` typography).

After hand-reviewing all 62 "executable" hits, the **only genuinely-executed
non-ASCII literals** are:

- `sap-dev-core/skills/sap-atc/references/sap_atc_check_run_status.vbs` (×5) —
  Japanese run-state words (`終了`/`完了`/`処理中`/`実行中`/`エラー`/`失敗`/`中止`)
  in `InStr()` comparisons. **Mitigated:** the primary match is locale-independent
  icon-ID prefixes (`@03/@DF/@AC`, `@2F/@BZ`, `@5C/@5B`) + English substrings, so
  the JA tier degrades gracefully. Fix: lean on the icon-ID path and/or rebuild
  the JA literals via `ChrW()`.
- `sap-dev-core/skills/sap-se11/references/sap_se11_set_enh_category.vbs:746` —
  `If lastCh = "…"` (trailing-char trim). Negligible effect if it mojibakes; fix:
  `ChrW(&H2026)`.
- `sap-dev-core/shared/scripts/sap_check_signatures.ps1`,
  `sap_check_spec_refs.ps1` — an em-dash inside the *advice-text column* written
  to a `.tsv`. Data-cosmetic (tabs / keywords / structure are ASCII and intact;
  only the prose garbles — this is the "scope.tsv mojibake" class).
- `sap-dev-core/skills/sap-gui-skill-scaffold/references/emit_skill_folder.ps1`
  (×4) — text inside strings that become *generated Markdown* (a scaffolding
  author tool; Markdown is multilingual-OK anyway).

Everything else in the 62 is a trailing comment after code (`Exit For   ' … — …`,
`sendVKey 6   ' F6 — …`) or the second half of a multi-line `WScript.Echo`
(all ten SE11/SE24/SE37/SE38/SE91 `"…— pressing 'Maint. in orig. lang.'"` lines).
**Net: zero of the 861 lines alters control flow without an existing ASCII
fallback.** This is a hygiene + customer-polish issue, not a correctness
emergency.

## Prioritized remediation

- **P1 — DONE (2026-06-04):** the genuinely-executed literals were converted to
  `ChrW()`. In `sap_atc_check_run_status.vbs` the run-state words became named
  `JA_*` **and `ZH_*`** constants (Simplified Chinese added for parity). Each
  constant's trailing comment carries the glyph per the glyph-in-comment
  exception above. The SE11 ellipsis became `ChrW(&H2026)`.
  **ZH live-verification (S4D 1909, ZH logon, 2026-06-04):** a read-only probe of
  the ATC Run Monitor grid (`SAPLSATC_UI_MONITOR`/200, column `STATE_ICON`) showed
  3 completed run series with cell value `@DF\Q状态：已完成@` — so the COMPLETED
  word `已完成` (and substring `完成`) is **confirmed**; `ZH_FINISHED` was set to the
  exact observed `已完成`. RUNNING / ERROR states were absent at capture, so those
  ZH words stay best-effort (the icon-ID path `@2F`/`@5C` covers them regardless).
  Validated on 32-bit cscript: a `ChrW` round-trip (incl. `&H884C` > `&H8000`),
  a 15-case match harness, and a replay of the **real captured** `@DF\Q已完成@`
  cell value — all routing correctly under `Option Explicit`; a byte scan
  confirmed the only executable-position non-ASCII left is one pre-existing
  em-dash inside a `WScript.Echo` diagnostic. Both files remain on the warning
  list (glyph comments / em-dashes) — expected, per the glyph-in-comment trade-off.
- **P2 — polish (bulk, manual):** replace cosmetic `—`→`--`, `→`→`->`, `…`→`...`
  in diagnostics and generated TSV/Markdown text so customer consoles and output
  files stop showing `â€"`. Comments can follow but are lowest value (never run).
  Per CLAUDE.md Rule 2, edits are **manual** — no sed/awk batch rewrite (a blind
  `—`→`--` pass would also corrupt the intentional JA literals).
- **P3 — process:** once the tree is clean, promote the guard to a hard error to
  catch regressions (the ratchet).

## Decision log

- **2026-06-04 — Rejected any *tree-wide* conversion to UTF-16 LE or UTF-8-with-BOM.**
  Evaluated on the back of a "we have to handle kanji / wrong-codepage trouble" concern.
  Conclusion: **keep ASCII-first**; UTF-8 BOM stays a *per-file* opt-in, never tree-wide.
  Rationale, consolidated:
  - **Git.** UTF-16 is treated as **binary** by git (NUL bytes) → no line diffs, painful
    3-way merges; no `.gitattributes` / `working-tree-encoding` exists in this repo today,
    and `working-tree-encoding` wouldn't fix the *non-git* readers anyway. UTF-8-with-BOM
    *is* git-safe (text, line-diffable) — that is exactly why it's the opt-in — but
    32-bit `cscript` chokes on a UTF-8 BOM in a `.vbs`, so it is not a blanket answer.
  - **Redundant.** A driving `.vbs` is already written to `{WORK_TEMP}` as UTF-16 LE
    before `cscript` runs it (`Set-Content -Encoding Unicode` / `[IO.File]::WriteAllText(…,
    UnicodeEncoding)`), so `cscript` never decodes the *committed* file — committing it as
    UTF-16 buys nothing for execution.
  - **Cost.** ~287 `FSO.OpenTextFile` includes (ASCII/MBCS mode), ~47 PowerShell readers
    (`ReadAllText` / `[Encoding]::UTF8`), and the JS guard (`readFileSync(…, 'utf8')`) all
    assume UTF-8 / ASCII; a flip would have to touch every one.
  - **Orthogonal to kanji.** Runtime kanji *data* (SAP GUI `BSTR`, NCo `.NET String`,
    `ADODB.Stream` UTF-8 file reads) is already UTF-16 in memory regardless of source
    encoding. Source encoding only governs glyphs *typed into the file*, which `ChrW()` /
    `[char]` already cover.

  **Standing rule:** UTF-8 BOM is a per-file opt-in (a `.ps1` that truly needs non-ASCII,
  or a leaf `.vbs` template that is read-as-UTF-8 then written UTF-16 at runtime); never
  tree-wide; FSO-included shared libs stay ASCII via `ChrW()`.

- **2026-06-04 — Rejected flipping the system ANSI codepage to UTF-8 (65001) machine-wide.**
  The "Beta: Use Unicode UTF-8 for worldwide language support" toggle (Region →
  Administrative → Change system locale) would make even a bare `Get-Content` read UTF-8,
  but: (a) it needs a **reboot** — which kills the live SAP session and working context;
  (b) it switches ANSI for *every* app — Microsoft flags it **Beta** precisely because it
  breaks legacy / non-Unicode apps that assume Shift-JIS, which on a Japanese SAP box can
  include SAP GUI itself (file dialogs, non-Unicode RFC paths, older add-ons). Not worth it
  for a display nicety. The fix is per-process explicit `-Encoding UTF8` (see *Adjacent
  encoding axes*); do not change the system locale without explicit, informed operator
  go-ahead.

## Related

- `plugins/sap-dev-core/shared/rules/language_independence_rules.md` — localized
  text only in diagnostics; branch on IDs / `MessageType`, never `.Text`.
- `contributing/golden_screen_baselines.md` — same "informational warning →
  ratchet to hard error" CI stance.
- `contributing/parallel_safe_session_attach.md` — why git-diffability (and thus
  ASCII / UTF-8 source) matters in a multi-session repo.
- `scripts/check-consistency.mjs` — the guard implementation.
