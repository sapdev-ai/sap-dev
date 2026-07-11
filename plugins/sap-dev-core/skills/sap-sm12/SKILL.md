---
name: sap-sm12
description: |
  Lists and safely releases SAP enqueue locks (transaction SM12) over RFC — no
  GUI. Two modes. `list` (read-only) dumps current lock entries via ENQUEUE_READ
  with a computed lock AGE and a best-effort owner-liveness column, filterable by
  user / table / lock argument / client / age. `release` (destructive, gated)
  releases a stale lock ONLY after proving the owner has no session on ANY
  application server (a liveness gate that reads TH_SERVER_LIST + TH_USER_LIST,
  and TH_SYSTEMWIDE_USER_LIST on multi-instance systems), showing the lock
  evidence, requiring the operator to TYPE the owner's user name to confirm,
  deleting via ENQUE_DELETE, then re-reading to verify and writing an audit line.
  It hard-refuses whenever the owner is still live or liveness cannot be proven —
  there is no --force. Automates exactly the risky part of the daily "clear a
  stuck lock" op (the owner-death check operators get wrong on multi-instance
  systems), so it is safer than the manual SM12 path, not just faster.
  Use for: stuck / stale enqueue lock, "lock entry held by", release SM12 lock,
  delete lock entry, "object is locked by user", SM12.
  Prerequisites: an RFC-capable connection profile (/sap-login). `release` also
  needs the generic wrapper Z_GENERIC_RFC_WRAPPER_TBL (deploy via /sap-dev-init)
  for the ENQUE_DELETE call and the multi-instance liveness leg; `list` does not.
argument-hint: "<mode> ...   list [--user=U] [--table=T] [--arg=<GARG pattern>] [--client=C | --all-clients] [--older-than=30m|2h|1d] [--max=N] [--save-output=PATH]   |   release --user=U [--table=T] [--arg=<GARG pattern>] [--client=C]"
---

# SAP SM12 — Enqueue Lock List & Safe Release

You list SAP enqueue locks and — only through a liveness gate + typed
confirmation — release a stale one, entirely over RFC (SAP NCo 3.1, 32-bit
PowerShell). There is **no GUI automation** in this skill: if RFC is
unavailable you fail loud with the manual SM12 path, never a half-automated
GUI delete.

Task: $ARGUMENTS

The live enqueue table is memory-resident: it is read with `ENQUEUE_READ` and
mutated with `ENQUE_DELETE` (SAP's own enqueue APIs) — **never** with
`RFC_READ_TABLE` / SQL on `SEQG3` (Rule 1).

---

## Shared Resources

| File | Token | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules (no SQL writes; no unsolicited deploy; confirm gates) |
| `<SAP_DEV_CORE_SHARED_DIR>/rules/error_classes.md` | *(rule)* | `error_class` taxonomy (this skill's `LOCK_*` classes live here) |
| `<SKILL_DIR>/references/sap_sm12_lib.ps1` | `%%SM12_LIB_PS1%%` | Shared helpers: generic FM-table reader, lock-age math, server-clock |
| `<SKILL_DIR>/references/sap_sm12_list.ps1` | *(reader)* | `list` mode + release-mode re-reader / `-ExpectGone` verifier (ENQUEUE_READ) |
| `<SKILL_DIR>/references/sap_sm12_liveness.ps1` | *(gate)* | Owner-liveness verdict (TH_SERVER_LIST + TH_USER_LIST, `-MergeUserList` leg) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | `%%RFC_LIB_PS1%%` | NCo connect/disconnect; fills `%%SAP_*%%` from the pinned profile |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | `%%ARTIFACT_LIB_PS1%%` | Register `list`/`release` outputs for /sap-evidence-pack |
| `/sap-rfc-wrapper` (skill) | — | `release` delegates the ENQUE_DELETE and TH_SYSTEMWIDE_USER_LIST calls here (both FMs are not remote-enabled) |
| `/sap-dev-init` (skill) | — | Deploys `Z_GENERIC_RFC_WRAPPER_TBL` (release prerequisite) — suggest, never auto-run |

This skill drives no SAP GUI, so it has no VBS, no golden-screen baseline, no
session lock and no GUI-Security sidecar.

---

## Step 0 — Resolve Work Directory

Resolve `work_dir` (and `log_dir` for the audit trail) via the env-aware helper —
do NOT read `settings.json` directly:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir)); Write-Output ('LOG_DIR=' + (Get-SapSettingValue 'log_dir' ((Get-SapWorkDir) + '\logs')))"
```

Set `{WORK_TEMP}` = `{work_dir}\temp` (create if missing) and `{RUN_TEMP}` =
`Get-SapRunTemp` (per-run scratch — all generated `*_run.ps1` go here):

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_sm12_run.json" -Skill sap-sm12 -ParamsJson "{\"mode\":\"<MODE>\"}"
```

State file `{RUN_TEMP}\sap_sm12_run.json`. Best-effort.

---

## Step 1 — Parse Arguments & Dispatch Mode

The **first token** of `$ARGUMENTS` is the mode.

| Mode | Meaning | Write? |
|---|---|---|
| `list` | ENQUEUE_READ dump with AGE + best-effort liveness | read-only, no prompt |
| `release` | Liveness gate → typed confirm → ENQUE_DELETE → verify → audit | **destructive**, typed confirm |

Common flags: `--user=U`, `--table=T`, `--arg=<GARG pattern>` (SEQG3 lock
argument; `*` wildcards), `--client=C`, `--all-clients` (list only),
`--older-than=<30m|2h|1d>` (list only), `--max=N` (list; default 200),
`--save-output=PATH` (list).

Normalize `--older-than` to minutes (`m`/`h`/`d`). If the mode token is missing
or unknown → print usage and stop. **`release` requires `--user`** — refuse with
usage if absent (locks are gated one owner per run).

Then go to **Mode: list** or **Mode: release** below.

---

## Step 2 — RFC Preflight

This is an RFC-only skill. Confirm a pinned connection profile resolves (the
generated scripts call `Connect-SapRfc`, which falls back to the pinned profile
in `connections.json`). If no profile / no NCo, the generated script prints
`STATUS: RFC_ERROR …`; surface it and stop with the manual path:

> RFC is unavailable, so I can't read or release locks automatically. Run
> `/sap-login` to pin an RFC-capable profile, or clear the lock by hand in SM12
> (`/nSM12` → select the row → Lock Entry → Delete) after confirming with the owner.

`release` has an additional preflight — see **Step 2.5**.

---

# Mode: list — show current locks

## L1 — Generate & run the reader

Materialize the reader under `{RUN_TEMP}`, substituting **only** the two library
paths; leave every `%%SAP_*%%` token literal so `Connect-SapRfc` fills them from
the pinned profile:

```powershell
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_sm12_list.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$ps = $ps.Replace('%%SM12_LIB_PS1%%', '<SKILL_DIR>\references\sap_sm12_lib.ps1')
[IO.File]::WriteAllText('{RUN_TEMP}\sm12_list_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
Write-Host 'Done'
```

Run under **32-bit** PowerShell. Pass the parsed filters (omit flags the user
did not give); include `-WithLiveness` (best-effort owner column) and, for
`--save-output`, `-OutTsv "<path>"`; default client = the pinned client unless
`--all-clients` was passed (then add `-AllClients`, no `-Client`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sm12_list_run.ps1" -WithLiveness -User "<U>" -Table "<T>" -LockArg "<GARG>" -Client "<C>" -OlderThanMin <N> -Max <MAX>
```

## L2 — Render & register

Parse `LOCK:` lines into a table: **Client · User · Table · Lock argument ·
Mode · Tcode · Age (min) · Owner liveness**. Read the final `STATUS: OK n=… total=…
capped=… servers=…`:

- `capped=true` → note that `total` exceeded `--max`; suggest tighter filters.
- Explain the **liveness** column honestly: `LIVE` = owner has a session now;
  `GONE` = owner absent (single-instance or verified); `UNKNOWN` = not proven
  here (multi-instance, or liveness read failed) — **`list` never gates on it**.
- `RFC_ERROR` → surface verbatim; if it names ENQUEUE_READ-not-RFC-callable,
  say locks can still be read via `/sap-rfc-wrapper fm ENQUEUE_READ`.

If `-OutTsv` was used, the script printed `OUT_TSV: <path> rows=…`; register it:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1" -Register -Skill sap-sm12 -Kind lock-list -Format tsv -Path "<path>" -Coverage CHECKED
```
*(If a direct `-Register` CLI is not available, dot-source `sap_artifact_lib.ps1`
and call `Register-SapArtifact -Skill sap-sm12 -ScopeKey (…) -Kind lock-list
-Format tsv -Path "<path>" -Coverage CHECKED`.)*

Then go to **Final — Log End** (`SUCCESS`).

---

# Mode: release — safely release a stale lock

Destructive. The gate order is **non-negotiable and not bypassable**: re-read →
prove owner death on every server → show evidence → typed confirm → re-check for
drift → delete → verify → audit. No `--force` exists.

## Step 2.5 — Wrapper preflight (release only)

`ENQUE_DELETE` and the multi-instance `TH_SYSTEMWIDE_USER_LIST` are **not**
remote-enabled, so release needs `Z_GENERIC_RFC_WRAPPER_TBL`. Verify it is
deployed (read-only TFDIR probe):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_object_resolver.ps1" -Token "FUNC Z_GENERIC_RFC_WRAPPER_TBL"
```

If it resolves `NOT_FOUND`, **refuse** (Rule 2 — never auto-deploy):

> `release` needs the generic RFC wrapper (`Z_GENERIC_RFC_WRAPPER_TBL`), which
> isn't deployed on this system. Run `/sap-dev-init` to deploy it, then retry.
> (`/sap-sm12 list` works without it.)

Log end `SKIPPED` / `LOCK_WRAPPER_MISSING` and stop.

## R1 — Re-read the candidate locks

Run the reader (L1's generator, `{RUN_TEMP}\sm12_list_run.ps1`) with the release
selectors — `--user` (required), plus any `--table` / `--arg` / `--client`
(default: pinned client). Use `-Max 0` (no cap — every candidate must be shown)
and no `-WithLiveness` (the authoritative gate follows in R2):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sm12_list_run.ps1" -User "<U>" -Table "<T>" -LockArg "<GARG>" -Client "<C>" -Max 0
```

- `STATUS: OK n=0` → `LOCK_NOT_FOUND`: report that nothing matched (the lock may
  have cleared itself), log `SUCCESS`, stop.
- Otherwise capture every `LOCK:` row (these exact rows drive R6's delete) and
  **show them all** to the operator before going further.

## R2 — Liveness gate (authoritative)

Generate + run the liveness gate:

```powershell
$ps = [IO.File]::ReadAllText('<SKILL_DIR>\references\sap_sm12_liveness.ps1', [Text.Encoding]::UTF8)
$ps = $ps.Replace('%%RFC_LIB_PS1%%',  '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_rfc_lib.ps1')
$ps = $ps.Replace('%%SM12_LIB_PS1%%', '<SKILL_DIR>\references\sap_sm12_lib.ps1')
[IO.File]::WriteAllText('{RUN_TEMP}\sm12_live_run.ps1', $ps, (New-Object Text.UTF8Encoding($false)))
Write-Host 'Done'
```

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sm12_live_run.ps1" -User "<U>"
```

Read the final `LIVENESS:` line and act on the **exit code**:

| Result | Action |
|---|---|
| `LIVENESS: LIVE` (exit 1) | **Refuse** `LOCK_OWNER_LIVE`. Show the `SESSION:` evidence ("owner still has a session on …"). No delete. Log `SKIPPED`. |
| `LIVENESS: GONE` (exit 0) | Owner proven absent, coverage complete → proceed to R3. |
| `NEED_SYSTEMWIDE …` (exit 2) | Multi-instance: connected-server absence isn't enough → do the **systemwide leg** below, then re-judge. |
| `LIVENESS: UNVERIFIABLE` with no `NEED_SYSTEMWIDE` (exit 2) | **Refuse** `LOCK_LIVENESS_UNVERIFIED`; show the `REASON:` and which servers were uncovered. No delete. Log `SKIPPED`. |

**Systemwide leg (only on `NEED_SYSTEMWIDE`).** Invoke **`/sap-rfc-wrapper fm
TH_SYSTEMWIDE_USER_LIST`** via the Skill tool (it reads the live interface, so
you map outputs by the field names it shows — the per-user rows carry a `BNAME`
user field). Collect every returned user name, write them one per line to
`{RUN_TEMP}\sm12_systemwide_users.txt` (UTF-8), then re-invoke the gate to let it
compute the verdict (verdict logic stays in one place):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sm12_live_run.ps1" -User "<U>" -MergeUserList "{RUN_TEMP}\sm12_systemwide_users.txt"
```

`LIVE` (exit 1) → refuse `LOCK_OWNER_LIVE`; `GONE` (exit 0) → proceed. If the
wrapper call itself fails, treat as `LOCK_LIVENESS_UNVERIFIED` and refuse.

## R3 — Evidence

Show the operator, together: the candidate lock rows (R1), the gate verdict
**GONE** + the covered-server list (`SERVER:` lines), and the lock age. This is
the evidence they are signing off on.

## R4 — Typed confirmation (production-grade)

This is a destructive op on a shared runtime object → **typed** confirmation, not
a yes/no. Prompt exactly:

> Type the lock owner's user name to release **N** lock(s) held by **`<U>`**: _

Accept only an exact (case-insensitive) match of `<U>`. Any mismatch or empty
answer → stop, log `SKIPPED`, write the audit line (R8) with verdict `REFUSED`,
touch nothing.

## R5 — Drift re-check

Immediately re-run R1's reader once more with the same selectors. Compare to the
R1 rows. **Any** difference (new/removed/changed rows) → abort back to R1 with a
note that the lock situation changed under you (do not delete a moved target).
Identical → proceed.

## R6 — Delete via /sap-rfc-wrapper

Invoke **`/sap-rfc-wrapper fm ENQUE_DELETE`** via the Skill tool. `ENQUE_DELETE`
has a TABLES parameter carrying the enqueue entries to delete — build **one row
per R5-verified lock**, mapping the re-read values to the interface fields the
wrapper shows (typically `GCLIENT` / `GNAME` / `GARG` / `GUNAME` / `GMODE`;
`GARG` must be the exact byte-for-byte value from R1, not the display form).
Leave importing flags at their defaults. Do not invent field names — use exactly
what `/sap-rfc-wrapper`'s interface reader lists.

Never treat the wrapper's echo as success — R7 is authoritative.

## R7 — Verify (authoritative re-read)

Re-run the reader with `-ExpectGone` and the same selectors:

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "{RUN_TEMP}\sm12_list_run.ps1" -User "<U>" -Table "<T>" -LockArg "<GARG>" -Client "<C>" -Max 0 -ExpectGone
```

`STATUS: GONE` (exit 0) → **RELEASED**. `STATUS: NOT_GONE` (exit 1) → the rows
persist → `LOCK_DELETE_FAILED` (most likely cause: missing `S_ENQUE` delete
authorization — surface that hint).

## R8 — Audit & register

Append one tab-separated line to the append-only audit trail (survives runs;
one line per attempted release, **including refusals**), and register the
per-run evidence:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d='{LOG_DIR}'; if(-not(Test-Path $d)){[void](New-Item -ItemType Directory -Force $d)}; $f=Join-Path $d 'sm12_release_audit.tsv'; if(-not(Test-Path $f)){[IO.File]::WriteAllText($f,\"ts`trun_id`tsid`tclient`toperator`towner`tn_locks`ttables`tverdict`treason`r`n\",(New-Object Text.UTF8Encoding($true)))}; Add-Content -LiteralPath $f -Value ((Get-Date -Format s)+\"`t{RUN_ID}`t<SID>`t<C>`t<OPERATOR>`t<U>`t<N>`t<TABLES>`t<VERDICT>`t<REASON>\")"
```

Fill `<VERDICT>` ∈ `RELEASED` / `REFUSED` / `FAILED`, `<REASON>` = the
`error_class` (or `ok`). Also write the evidence TSV (lock rows + `SERVER:`
coverage + verdict) under the artifact dir and `Register-SapArtifact`
(`-Kind release-evidence -Verdict <VERDICT>`).

Then go to **Final — Log End**.

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_sm12_run.json" -Status <SUCCESS|SKIPPED|FAILED> -ExitCode <0|1> [-ErrorClass <CLASS> -ErrorMsg "<short>"]
```

`error_class` values (all in `shared/rules/error_classes.md`): `LOCK_OWNER_LIVE`,
`LOCK_LIVENESS_UNVERIFIED`, `LOCK_NOT_FOUND`, `LOCK_DELETE_FAILED`,
`LOCK_WRAPPER_MISSING`; plus infra `RFC_LOGON_FAILED` / `RFC_ERROR`.

---

## Safety & gates (summary)

- **Rule 1** — locks are read/deleted only through `ENQUEUE_READ` / `ENQUE_DELETE`
  (SAP enqueue APIs); never SQL/`RFC_READ_TABLE` on `SEQG3`.
- **Rule 2** — the wrapper FM is never auto-deployed; missing → refuse + point at
  `/sap-dev-init`.
- **Rule 3** — `release` is destructive → **typed** confirmation (owner user
  name), shown only after the liveness gate passes; `list` runs unprompted.
- **Fail-loud (Rule 10)** — the gate refuses on `LIVE` *and* on any
  `UNVERIFIABLE` (a "couldn't check" is treated as unsafe, never as GONE). There
  is no override flag at any phase.
- **v1 refuses** update-task-owned locks pending the SEQG3 backup-flag mapping;
  the delete then targets only non-update entries (conservative).

## Limitations

- **Own liveness model is user-presence-based** (owner has ANY session), not
  per-session detail — matches the SM04/AL08 check operators do by hand.
- **Multi-instance leg** relies on `TH_SYSTEMWIDE_USER_LIST` via the wrapper; if
  that FM's output can't be read, release refuses rather than guessing.
- **Update-task locks**: deleting one can corrupt an in-flight update, so v1
  refuses them; use SM13 to clear the stuck update first.
- No GUI fallback in v1 — RFC is required. `list` on a system where ENQUEUE_READ
  is not remote-enabled can still be done via `/sap-rfc-wrapper fm ENQUEUE_READ`.
- First release on a new release/kernel should be exercised in a sandbox: the
  `ENQUE_DELETE` / `TH_SYSTEMWIDE_USER_LIST` interfaces are resolved live by
  `/sap-rfc-wrapper`, but confirm the delete actually clears the entry (R7 does
  this authoritatively).
