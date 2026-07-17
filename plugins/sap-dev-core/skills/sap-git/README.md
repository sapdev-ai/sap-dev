# SAP Git Skill

Install-free, **read-only** git backend for custom ABAP: gives Z code the
PR-style review, blame, readable TR diffs, and whole-package-on-disk that
abapGit would — **without installing abapGit** (often politically impossible
on customer systems) and **without ever writing to SAP**. `snapshot`
serializes a PACKAGE / TR / object-list scope to an abapGit-ish tree over
proven RFC reads and commits it to a local git repo, annotating the commit
message with the TRs currently referencing the scope; `diff` re-serializes and
shows working-system-vs-last-snapshot as a git diff; `log` / `status` are
local git reads. Fully headless — no GUI, no VBS, zero SAP writes.

## Security Warning

**Serialized ABAP source can contain hardcoded credentials.** The local
repository lives under `{work_dir}` and the skill **never adds a remote and
never pushes**. Keep it that way: do not add a remote or push these
repositories yourself without first reviewing the serialized source for
secrets.

## Skill Overview

1. Parse the mode: `snapshot` | `diff` | `log` | `status`. **Any `import` /
   `push` / `apply` / "write back to SAP" phrasing is REFUSED** (v1 is
   read-only; deploy via `/sap-se38` / `/sap-se37` / `/sap-se24` / `/sap-se11`)
2. Preflight: `git` in PATH (`GIT_NOT_INSTALLED` otherwise); pinned RFC
   profile for snapshot/diff
3. Resolve/init the repo — one repo per (SID, client) under `{work_dir}\git`
   (override with `--repo`). A dirty worktree is refused (`GIT_REPO_DIRTY`),
   which is what makes diff's post-run `git reset --hard` safe
4. Serialize the scope over RFC; every object gets an honest fidelity:
   **FULL** (programs / function modules / message classes), **PARTIAL**
   (DDIC + classes as deterministic metadata JSON — class source over RFC is
   unsupported), `COULD_NOT_CHECK`, or `SKIPPED_UNSUPPORTED` (never a silent
   drop)
5. `snapshot`: commit with TR annotations (E071/E070/E07T join). `diff`:
   stage, show `git diff --cached HEAD`, reset. Register the manifest for
   `/sap-evidence-pack`

A hard determinism contract (volatile DDIC fields stripped, rows sorted by
key) makes snapshot-twice yield an **empty diff** — the property that makes
`diff` trustworthy (`DIFF_LINES: 0` = no change on the system).

## Auto-Trigger Keywords

- `snapshot package ZHK_*`, `put ZPKG under git`, `git snapshot`
- `diff the package against the last snapshot`, `what changed in ZPKG`
- `git log for ZHKR001`, `sap git status`

## Usage

```text
/sap-git snapshot PACKAGE ZCMDEVAI
/sap-git snapshot PACKAGE ZCMDEVAI --subpackages --message "before refactor"
/sap-git snapshot TR DEVK900123
/sap-git snapshot --objects objects.txt --repo D:\repos\s4d --no-commit
/sap-git diff PACKAGE ZCMDEVAI --stat
/sap-git diff PACKAGE ZCMDEVAI --object ZHKR001
/sap-git log --object ZHKR001 --max 10
/sap-git status
```

## Prerequisites

- `git` in PATH (e.g. `winget install Git.Git`)
- Pinned RFC profile via `/sap-login`; SAP NCo 3.1 (32-bit) in GAC
- `/sap-dev-init` optional but recommended — its wrapper FM unlocks the full
  DDIC fidelity path in v1.5 (v1 ships DDIC as PARTIAL either way)

## Directory Structure

```text
sap-git/
├── SKILL.md                          # Skill definition (single source of truth)
└── references/
    ├── sap_git_repo.ps1              # Local git plumbing (ensure/commit/diff/log/status/reset)
    └── sap_git_serialize.ps1         # RFC serializer (scope -> tree + manifest)
```

## Limitations

- **Read-only (v1).** Refuses all import / push / apply requests. No Z objects
  deployed; the wrapper FM is only *used* if present, never deployed.
- **NOT abapGit-import-compatible** — the metadata format is this skill's own
  JSON.
- Class source over RFC is unsupported (SE24 GUI download / ADT only) —
  classes ship as explicit PARTIAL metadata stubs; DDIC is PARTIAL
  deterministic metadata until the v1.5 `DDIF_*_GET` wrapper path.
- The one local destructive operation (diff's `git reset --hard`) is gated by
  the mandatory clean-worktree refusal — it can only discard files the run
  itself wrote.
- v1.5 roadmap: full DDIC fidelity, `blame`, `diff --against <sha>`. v2 (only
  with a concrete consumer): abapGit-compatible export / push-to-SAP.
- Live-verified on S4D (S/4HANA 1909), including the snapshot-twice
  empty-diff contract; ECC 6 shares the identical path.

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-07-17

## License

GPL-3.0 License - See LICENSE file in repository root.
