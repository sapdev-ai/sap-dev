---
name: sap-rfc-monitor
description: |
  Diagnoses stuck tRFC / qRFC interface queues and audits the SM59 RFC
  destination register — read-only over RFC (no GUI). `queues` snapshots the
  tRFC (SM58) and inbound/outbound qRFC (SMQ2/SMQ1) queues: per-destination /
  per-queue depth, age, head-blocker error text, and the inbound-scheduler
  registration flag, then clusters the failed LUWs by root cause (target down /
  auth / data / not-registered) with one recommended action each. `destinations`
  parses RFCDES into an auditable register — type, target host, logon user, trust
  flag, and stored-credential PRESENCE flag (RFCDESSECU is never read) — plus the
  inbound trusted-system ACL, with an AI risk column. `retry` re-drives failed
  tRFC LUWs for one destination via RSARFCEX (confirm-gated, delegated to
  /sap-run-report) then authoritatively re-reads to verify CLEARED / REDUCED /
  UNCHANGED. LUW / queue DELETION is refused. Complements /sap-diagnose's `smq`
  interface triage as the standalone deep-dive. Prerequisites: SAP profile via
  /sap-login (RFC); SAP NCo 3.1 (32-bit) in GAC. No GUI session, no Z-object, no
  /sap-dev-init.
argument-hint: "queues [--dir=trfc|in|out|all] [--dest=D] [--queue=Q] [--top=N] [--save-output PATH] | destinations [--type=3|G|H|T|I|L] [--save-output PATH] | retry --dest=D"
---

# SAP tRFC / qRFC Queue Monitor + Destination Register

You diagnose **stuck RFC interfaces** and audit **RFC destinations**, read-only
over RFC. One `SYSFAIL` head-blocker silently halts everything queued behind it;
this skill surfaces the whole picture in seconds and clusters hundreds of failed
LUWs into a handful of causes with one recommended action each. The destinations
half is the go-live / audit twin: RFCDES parsed into a risk-annotated register.

Task: $ARGUMENTS

**You are read-only against SAP for `queues` and `destinations`.** The only state
change anywhere is `retry`, which executes the SAP-standard report RSARFCEX
through /sap-run-report behind an evidence-first confirm gate. **LUW / queue
deletion and unlock are refused** (manual SM58 / SMQ1 / SMQ2 pointer), never
automated.

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SAP_DEV_CORE_SHARED_DIR>/rules/skill_operating_rules.md` | *(rule)* | Mandatory operating rules — reads always allowed; the one write (RSARFCEX) is a SAP-supplied API, confirm-gated |
| `<SKILL_DIR>/references/sap_rfcq_read.ps1` | `-Area trfc\|qin\|qout\|qstate [-Dest -Queue -Top -HeadLuws -ExpectCleared -OutTsv]` | The tRFC/qRFC queue reader + retry verifier (RFC) |
| `<SKILL_DIR>/references/sap_rfcdes_parse.ps1` | `[-Type -Max -OutTsv]` | RFCDES → destination register + tolerant RFCOPTIONS parser (RFC) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` | dot-sourced by the engines | NCo 3.1 connect + `RFC_READ_TABLE` helpers |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_object_resolver.ps1` | dot-sourced by the engines | `Read-SapTableRows` |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_artifact_lib.ps1` | dot-sourced by the engines + Step 6 | Scope key, artifact dir, `Register-SapArtifact` |
| `/sap-run-report` | sub-skill | Executes RSARFCEX (`retry`) — owns the execution confirm gate |
| `/sap-diagnose` | related | Triages interface incidents via its own lightweight `smq` reader (Wave-0 T1-B); this skill is the standalone deep-dive (destinations register, retry, richer clustering) — invoke directly or as a follow-up |

---

## Step 0 — Resolve Work Directory and Settings

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_settings_lib.ps1'; . '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('WORK_DIR=' + (Get-SapWorkDir))"
```

Set `{RUN_TEMP}` (per-run scratch):
```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_connection_lib.ps1'; Write-Output ('RUN_TEMP=' + (Get-SapRunTemp))"
```

---

## Step 0.5 — Start Logging

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action start -StateFile "{RUN_TEMP}\sap_rfc_monitor_run.json" -Skill sap-rfc-monitor -ParamsJson "{}"
```

---

## Step 1 — Parse Arguments & Mode Dispatch

First token selects the mode. Flags follow.

| Mode | Args | Access |
|---|---|---|
| `queues` | `[--dir=trfc\|in\|out\|all]` (default `all`), `[--dest=D]`, `[--queue=Q]`, `[--top=N]` (default 20), `[--save-output PATH]` | **read-only** |
| `destinations` | `[--type=3\|G\|H\|T\|I\|L]`, `[--max=N]`, `[--save-output PATH]` | **read-only** |
| `retry` | `--dest=D` (required) | **gated write** (RSARFCEX) |

`--dir` maps to engine `-Area`: `trfc`→`trfc`, `in`→`qin`, `out`→`qout`, `all`→`all`.

**Hard rules at parse time (fail loud — do NOT proceed):**

- Any **delete / unlock** request (e.g. "delete the stuck LUW", "unlock the
  queue", "clear SMQ2") → **REFUSE**. Print the refusal + a manual pointer
  ("Delete/unlock is not automated. Use SM58 / SMQ1 / SMQ2 manually."), log end
  with `error_class=RFCQ_ACTION_REFUSED`, STOP. This is a refusal, not a gate.
- `retry` without `--dest` → usage ERROR, STOP.
- `destinations --test`, `destinations --diff --against <profile>`, qRFC
  `retry --dir=in|out`, per-LUW retry → **not yet implemented (Phase 1.5 / v2)**.
  Tell the user, then continue only with the implemented behavior (or STOP if
  that was the whole request). See **Scope & Limitations**.

---

## Step 2 — Ensure the RFC Profile

This skill needs an **RFC connection only — no GUI session**. A SAP profile must
be pinned (`/sap-login`); the engines self-connect via it. If no profile is
pinned, run `/sap-login` first.

**RFC unavailable → fail loud.** If an engine prints `STATUS: RFC_ERROR` (exit 2),
report the failure and the **manual tcode path** (SM58 / SMQ1 / SMQ2 for queues;
SM59 for destinations); suggest `/sap-doctor rfc`. Never present a partial or
empty result as healthy. `retry` additionally notes /sap-run-report's own
GUI/RFC prerequisite.

---

## Step 3 — `queues` (read-only)

Run the reader via **32-bit PowerShell** (NCo 3.1 is in `GAC_32`):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_rfcq_read.ps1" -Area all -Top 20 -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutTsv "{RUN_TEMP}\rfcq_snapshot.tsv"
```

Add `-Area <trfc|qin|qout>` for `--dir`, `-Dest <D>`, `-Queue <Q>`, `-Top <N>`.

Parseable output:

```
QUEUE: dir=<qin|qout> name=<q> dest=<d> depth=<n> state=<s> registered=<Y|N|-> err="<head err>" age_min=<n|->
LUW:   dir=qin ref=<q> fm=<fm> state=<s> retries=<n> err="<msg>"
TRFC:  dest=<d> state=<s> luws=<n> fm=<fm> err="<msg>" age_min=<n|->
STATUS: OK qin=<n> qout=<n> trfc=<n> reg_gaps=<n> capped=<Y|N> | RFC_ERROR
```

**Classify (you do this) each failed cluster** from `(dest, state, error-text
fingerprint, fm)` into ONE bucket, with one recommended action:

| Class | Signal | Recommended action |
|---|---|---|
| `TARGET_DOWN` | `SYSFAIL`/`CPICERR` + err ~ "does not exist" / "connection" / "CPIC" / target host | Fix / repoint the destination (SM59), **then** `retry` |
| `AUTH` | err ~ "not authorized" / "S_RFCACL" / "Name or password is incorrect" / "logon" | Fix the service user / trust (SM59, SU01), then `retry` |
| `DATA` | err ~ business (material/batch/period/config missing, locked) | Investigate the payload — **not a blind retry candidate** (it will re-fail); hand to /sap-fix-incident if custom |
| `NOT_REGISTERED` | inbound queue `depth>0` + `registered=N` | Register the inbound scheduler (**SMQR**) — retry alone won't drain it |
| `OTHER` | anything else | Investigate (SM58/SMQ2 detail) |

Rows in a non-failed state (`RECORDED` / `READ` / `READY` / `SENDED` with no
error) are a **normal backlog**, not a failure — report depth and, for a large
outbound backlog, suggest checking the consumer job / delta extraction. Never
label a normal backlog as failed.

Render a table grouped by destination → queue with depth / age / class /
recommended action. When `capped=Y`, state that the tRFC read hit its row cap
(counts are "at least N"). Only for clusters classed `TARGET_DOWN` / `AUTH`
(retry-safe **after** the fix) suggest the concrete `/sap-rfc-monitor retry
--dest=<D>` line. Register the TSV (Step 6). Apply coverage honesty: an area that
the engine reported as `COULD_NOT_CHECK` (auth-blocked / unreadable) is surfaced
as such, never as "empty / healthy".

---

## Step 4 — `destinations` (read-only)

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_rfcdes_parse.ps1" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>" -OutTsv "{RUN_TEMP}\dest_register.tsv"
```

Add `-Type <t>` for `--type`, `-Max <n>` for `--max`.

Parseable output:

```
DEST:  name=<d> type=<t>(<label>) target=<...> user=<u|-> trusted=<Y|N|?> stored_cred=<Y|?> desc="<...>" parse=<OK|PARTIAL|COULD_NOT_PARSE>
TRUST: trustsys=<sid> dest=<d|-> passwd_reqd=<Y|N> sectype=<s>
STATUS: OK n=<n> trusted=<n> stored=<n> parse_fail=<n> acl=<n> | RFC_ERROR
```

Render the register as a table and **add an AI risk column** per row:

- `trusted=Y` (especially `type 3`) → trust-based logon: confirm the trusting
  system's ACL entry is intentional and least-privilege.
- `stored_cred=Y` → stored logon credentials: verify the service user is
  least-privilege and rotated; a high-privilege user here is **HIGH** risk.
- `type_label` in {`ABAP_DRIVER`,`R2_OBSOLETE`,`CMC_OBSOLETE`} → obsolete type,
  candidate for cleanup.
- `target` an external / public host (HTTP_EXT) → outbound egress worth review.
- `parse=COULD_NOT_PARSE` → surfaced with options length only (never dropped,
  never guessed).

Summarize the `TRUST:` rows as the **inbound trusted-system ACL** section
(`passwd_reqd=N` on a trusted system is the notable one). Note that
`stored_cred` is a **presence flag** (the `v=` marker) — the skill never reads
RFCDESSECU and the register holds no password value by construction. Register the
TSV (Step 6).

---

## Step 5 — `retry` (gated write; tRFC only in v1)

1. **Pre-read** the selector — is there anything to retry?
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_rfcq_read.ps1" -Area trfc -Dest "<D>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
   ```
   0 failed LUWs → report "nothing to retry", log end SUCCESS, STOP. Else show the
   cluster evidence (count, oldest age, head error, your Step-3 class).
2. **CONFIRM gate (Rule 5)** — show it plainly and wait for an explicit `yes`:
   > I will execute **RSARFCEX** on `<SID>/<CLIENT>` to retry `<n>` failed tRFC
   > LUW(s) for destination `<D>`. This re-sends them. Proceed? (yes/no)

   `no` → log `SKIPPED`, STOP. If the Step-3 class is `DATA`, warn first that a
   retry will almost certainly re-fail until the payload/config is fixed.
3. **Delegate execution** to `/sap-run-report RSARFCEX --background` with the
   destination selector (its own Rule-5 gate follows — the accepted double gate).
   The RSARFCEX selection-screen field name for the destination is confirmed once
   via `/sap-run-report variant show` on the first live run.
4. **Verify authoritatively** (never the report's status text):
   ```bash
   C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "<SKILL_DIR>\references\sap_rfcq_read.ps1" -ExpectCleared -Dest "<D>" -SharedDir "<SAP_DEV_CORE_SHARED_DIR>"
   ```
   `CLEARED n=0` (exit 0) → success. `NOT_CLEARED n=<a>` (exit 3): compare to the
   before-count → **REDUCED** (`<b>`→`<a>`) or **UNCHANGED**. UNCHANGED or a
   still-nonzero count → report `error_class=RFCQ_RETRY_NOT_CLEARED` with the hint
   "fix the target/auth first" (a `TARGET_DOWN`/`AUTH`/`DATA` class predicts this).
5. Register the retry evidence (before rows, confirmation echo, after count).

---

## Step 6 — Register Artifacts

Register each TSV the engines wrote so `/sap-evidence-pack <scope>` collects it
(best-effort — a registration failure never changes the verdict):

```bash
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ". '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_artifact_lib.ps1'; Register-SapArtifact -Skill 'sap-rfc-monitor' -ScopeKey 'SID_<SID>_<CLIENT>' -ScopeKind 'SYSTEM' -Kind '<queue_snapshot|dest_register|retry_evidence>' -Format 'tsv' -Path '<PATH>' -Coverage '<CHECKED_CLEAN|CHECKED_FINDINGS|COULD_NOT_CHECK>'"
```

Echo the headline for the user, e.g.:

```
QUEUES: qin=<n> qout=<n> trfc=<n> failed_clusters=<n> reg_gaps=<n>  snapshot=<PATH>
DESTINATIONS: n=<n> trusted=<n> stored_cred=<n> parse_fail=<n>  register=<PATH>
```

---

## Final — Log End

```bash
powershell -ExecutionPolicy Bypass -File "<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_log_helper.ps1" -Action end -StateFile "{RUN_TEMP}\sap_rfc_monitor_run.json" -Status SUCCESS -ExitCode 0
```

A snapshot / register that builds — even one full of failed clusters — is
`SUCCESS -ExitCode 0` (the read ran; failures are valid findings). Use
`-Status FAILED` with the mapped `-ErrorClass` only for the fail-loud STOPs
(`RFC_LOGON_FAILED` on RFC_ERROR, `RFCQ_ACTION_REFUSED` on a delete/unlock
request, `RFCQ_RETRY_NOT_CLEARED` on an unverified retry).

---

## Scope & Limitations

- **v1 implemented:**
  - `queues` — tRFC (SM58 / ARFCSSTATE) + inbound/outbound qRFC (SMQ2/SMQ1)
    snapshot: server-side depth (queue FMs, never a table scan), state, age,
    head-blocker error, inbound-scheduler registration flag (QIWKTAB), root-cause
    clustering + recommended action. Read-only.
  - `destinations` — RFCDES register (type, target, user, trust flag,
    stored-credential presence flag), RFCSYSACL trusted-system ACL, AI risk
    column, tolerant RFCOPTIONS parser. Read-only.
  - `retry` — tRFC retry-all for one destination via RSARFCEX (confirm-gated,
    delegated to /sap-run-report), authoritative CLEARED/REDUCED/UNCHANGED verify.
  - Single code path on ECC 6 and S/4HANA (all tables + FMs probed identical).
- **Phase 1.5 (not yet):** `destinations --test` (RSRFCCHK bulk connectivity via
  /sap-run-report + spool parse), `destinations --diff --against <profile>`
  (register diff vs a second /sap-login profile), qRFC retry (`retry --dir=in|out`
  via RSQIWKEX / RSQOWKEX). These require a live report run to capture the
  selection-screen / spool layout — deferred until that can be verified.
- **v2 (not yet):** per-LUW re-execute (RSARFCSE), queue unlock / SMQR activate.
- **Refused permanently:** LUW / queue **deletion** and **unlock**
  (`RFCQ_ACTION_REFUSED`) — manual SM58 / SMQ1 / SMQ2 only. RSARFCSE's delete flag
  is never set on any path.
- **Read honesty:** an auth-blocked or unreadable area is `COULD_NOT_CHECK`, never
  rendered as "empty / healthy"; a large tRFC read reports `capped=Y` ("at least
  N"); an RFCOPTIONS row that will not parse is kept with its length only.
- **Secrets:** RFCDESSECU is never read; `stored_cred` is the `v=` marker presence
  only; the raw options blob is never echoed. No password value can leave the skill.
- Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP) 2026-07-11 — identical
  field names + FM signatures on both; `queues` + `destinations` exercised against
  real stuck queues and live destination registers on each.
