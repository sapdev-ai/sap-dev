---
name: sap-git
description: |
  Install-free, read-only git backend for custom ABAP: gives Z code the PR-style review, blame,
  readable TR diffs, and whole-package-on-disk that abapGit would — without installing abapGit
  (often politically impossible on customer systems) and without ever writing to SAP. snapshot
  serializes a PACKAGE / TR / object-list scope to an abapGit-ISH tree over proven RFC reads and
  commits it to a local git repo with the TRs currently referencing the scope annotated in the
  message; diff re-serializes and shows working-system-vs-last-snapshot as a git diff; log/status
  are local git reads. Fully headless (no GUI/VBS), zero SAP writes. Fidelity is tri-state and
  honest: programs / function modules / message classes are FULL (RPY + T100 reads); DDIC
  (tables/data-elements/domains/table-types/views) and classes are PARTIAL deterministic metadata
  JSON (direct DD0xL / SEO reads — class SOURCE over RFC is unsupported, so classes ship as
  explicit metadata stubs; full DDIC via the Z_GENERIC_RFC_WRAPPER_TBL DDIF_*_GET path is v1.5);
  unsupported types are SKIPPED_UNSUPPORTED, never silently dropped. A hard determinism contract
  (volatile DDIC fields stripped, rows sorted by key) makes snapshot-twice yield an EMPTY diff —
  the property that makes diff trustworthy. It REFUSES any import/push/apply request (v1 is
  read-only; use the deploy skills). NOT abapGit-import-compatible (metadata is our JSON). No Z
  objects deployed. Prerequisites: git in PATH; pinned RFC profile via /sap-login; NCo 3.1
  (32-bit). /sap-dev-init is optional but recommended (its wrapper unlocks full DDIC fidelity in v1.5).
argument-hint: "snapshot PACKAGE <ZPKG> [--subpackages] | TR <TRKORR> | --objects <file> [--repo <dir>] [--message \"...\"] [--no-commit] | diff <scope> [--object <N>] [--stat] | log [--object <N>] [--max N] | status"
---

# SAP Git Skill

You put custom ABAP under local git: serialize a scope to disk over read-only RFC, commit with
TR annotations, and diff/blame with real `git`. You never write to SAP and never push. Fidelity
is honest per object (FULL / PARTIAL / COULD_NOT_CHECK / SKIPPED_UNSUPPORTED).

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_git_repo.ps1` | `-Action ensure\|commit\|diff\|log\|status\|reset` | Local git plumbing (no SAP) |
| `<SKILL_DIR>/references/sap_git_serialize.ps1` | `-Scope -RepoDir` | RFC serializer (scope -> tree + manifest) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_read_source.ps1` | dot-sourced (by serializer) | `Read-SapAbapSource` for PROG/FM |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced | Scope/object resolution |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced | `Register-SapArtifact` |
| `/sap-login` | sub-skill | Pinned RFC profile |
| `/sap-dev-init` | sub-skill | (optional) deploys the wrapper for v1.5 full DDIC |

---

## Step 0 — Resolve Work Directory

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_git_run.json" -Skill sap-git -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Refuse Writes

Modes: `snapshot` | `diff` | `log` | `status`. **Any `import` / `push` / `apply` / "write back to
SAP" phrasing -> REFUSE** with: "sap-git is a read-only backend (v1); to deploy use /sap-se38 /
/sap-se37 / /sap-se24 / /sap-se11." Scope forms: `PACKAGE <p> [--subpackages]`, `TR <trkorr>`,
`--objects <file>`. Flags: `--repo <dir>`, `--message "<extra>"`, `--no-commit`, `--object <N>`,
`--stat`, `--max N`, `--save-to <file>`.

## Step 1.5 — Preflights

- `git --version` (via `sap_git_repo.ps1 -Action status`) — missing -> `GIT_NOT_INSTALLED`
  (fix: winget install Git.Git). snapshot/diff also need a pinned RFC profile (`/sap-login`).
- Wrapper presence is NOT required in v1 (DDIC ships PARTIAL either way); note `fidelity=FULL_CORE`
  regardless — the wrapper only matters for the v1.5 full-DDIC path.

## Step 2 — Repo Resolve/Init

Repo dir = `--repo`, else `Get-SapSettingValue 'sap_git_repo_dir' '{work_dir}\git'` +
`\<SID>_<CLIENT>` (one repo per system-client). Run:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_git_repo.ps1" -Action ensure -RepoDir "<repo>" -Sid <SID> -Client <CLIENT> -SapUser <USER>
```

`DIRTY: 1` -> refuse `GIT_REPO_DIRTY` (fix: commit/stash manually or pass a fresh `--repo`) — this
guarantees diff's post-run `git reset --hard` can only ever discard files THIS run wrote.

## Step 3 — Serialize (snapshot / diff)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_git_serialize.ps1" -Scope "PACKAGE <ZPKG>" -RepoDir "<repo>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
```

(`-Subpackages`, `-ObjectsFile <file>` for the other scope forms.) Parse each `GIT: <TYPE> <NAME>
<fidelity>` line + the `SERIALIZE: total=.. full=.. partial=.. cnc=.. skipped=..` summary. Empty
scope -> `SNAPSHOT_EMPTY_SCOPE`, stop. Every affected object with no wrapper degrades to PARTIAL /
COULD_NOT_CHECK — a class stub or DDIC metadata is NEVER presented as a full serialization.

## Step 4 — snapshot: TR annotation + commit

Read the TRs currently holding scope objects (E071 join E070 + E07T texts — honest label "TRs
referencing scope at snapshot time", not "since last snapshot"). Build the commit message
(`snapshot <scope>` + SID/client + release marker + the TR lines + any `--message`) into
`{RUN_TEMP}\commit_msg.txt`, then (unless `--no-commit`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_git_repo.ps1" -Action commit -RepoDir "<repo>" -MessageFile "{RUN_TEMP}\commit_msg.txt"
```

Echo `COMMIT: <sha>` back (authoritative: `sap_git_repo.ps1 -Action log -Max 1`). `no_changes`
after a re-snapshot is a legitimate SUCCESS (nothing changed on the system).

## Step 5 — diff / log / status

- **diff**: `sap_git_repo.ps1 -Action diff -RepoDir <repo> [-Stat] [-PathSpec src/<pkg>/<obj>*]
  [-SaveTo <file>]` — stages the freshly-serialized tree, shows `git diff --cached HEAD`, then
  resets hard to restore the last commit. `DIFF_LINES: 0` = no change (the determinism guarantee).
- **log**: `-Action log -Max <n> [-PathSpec ...]` — one line per snapshot with its TR annotations.
- **status**: `-Action status` — repo, HEAD, dirty flag.

## Step 6 — Register + Summarize

Register the manifest (and a diff patch when saved):

```bash
powershell -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-git' -ScopeKey '<SCOPE_KEY>' -Kind 'snapshot' -Format 'tsv' -Path '<repo>\.sapgit.manifest.tsv' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS>'"
```

Summarize: objects FULL/PARTIAL/CNC/skipped, commit sha, repo path, and the fidelity caveat
(classes + DDIC are metadata/PARTIAL; class source needs SE24/ADT).

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_git_run.json" -Status SUCCESS -ExitCode 0
```

Failure classes: `GIT_NOT_INSTALLED`, `GIT_REPO_DIRTY`, `GIT_COMMIT_FAILED`, `SNAPSHOT_EMPTY_SCOPE`,
`SNAPSHOT_SERIALIZE_FAILED`, `RFC_LOGON_FAILED`.

---

## Scope & Limitations (v1)

- **v1 implemented:** snapshot / diff / log / status. Scope: PACKAGE (+`--subpackages` via TDEVC
  walk), TR (E071), `--objects` list. One repo per (SID,client) under `{work_dir}\git`.
- **Live-verified on S4D (S/4HANA 1909):** snapshot of the 38-object package **ZCMDEVAI** produced
  7 FULL (4 programs via RPY, the ZFGDEVAI function group with its FMs, 2 message classes), 30
  PARTIAL (7 domains, 15 data elements, 3 tables, 1 table type, 4 class stubs — all deterministic
  metadata JSON), and 1 COULD_NOT_CHECK (an empty/generated program RPY returns nothing — honest).
  Commit landed; **re-serialize + diff returned DIFF_LINES: 0** — the load-bearing determinism
  contract (snapshot-twice = empty diff) holds live. `.sapgit.json` marker + `.sapgit.manifest.tsv`
  written. `diff`'s post-run `git reset --hard` is made safe by the mandatory clean-worktree refusal.
- **Fidelity is honest (Rule 10):** FULL = PROG/FM/MSAG (source/text). PARTIAL = DDIC (direct
  DD0xL field-list / header metadata — NOT the full DDIF_*_GET round-trip) and classes (metadata
  stub; **class source over RFC is unsupported** — SE24 GUI download / ADT only, a stack-wide
  limit /sap-compare also documents). SKIPPED_UNSUPPORTED = TRAN/SHLP/ENQU/etc (manifest row, never
  a silent drop). No object is ever presented at a higher fidelity than it was read.
- **v1.5:** full DDIC (DDIF_TABL/DTEL/DOMA/TTYP/VIEW_GET + textpool + dynpro) via
  `Z_GENERIC_RFC_WRAPPER_TBL` promoting DDIC rows PARTIAL->FULL; `blame <object>` (needs >=2
  snapshots); `diff --against <sha>`. **v2 (only with a concrete consumer):** abapGit-compatible
  export / push-to-SAP — v1 REFUSES all import/push/apply phrasing.
- **Read-only, no gates:** every FM is a read (Rule 1); no report execution (Rule 5); the wrapper is
  only *used* if present, never deployed (Rule 2). The one local destructive op (diff's reset) is
  gated by the clean-worktree refusal. ECC 6 shares the identical path (all 23 objects probed
  identical); no release branch. **Security:** serialized source can contain hardcoded credentials
  and the repo lives under `{work_dir}` — the skill never adds a remote or pushes (README warns).
