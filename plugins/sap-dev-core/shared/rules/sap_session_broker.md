# SAP GUI Session Broker — contract document

Coordinates which AI task (sub-agent / skill run) is allowed to drive which
SAP GUI session at any moment, without requiring a long-running broker
process. State lives in a single JSON registry; cross-process concurrency
is serialized by a Windows named mutex.

**Multi-connection aware** (since Phase 3.5 — mutex name bumped from
`SapDevSessionBroker_v1` to `_v2`): the broker tracks every attached SAP
connection separately, partitioned by `(connection_path, system_name,
client, user)`. A claim against `/app/con[1]` (e.g. QAS / client 200)
never returns a `/app/con[0]` path (e.g. DEV / client 100). When
multiple connections are attached, every acquire MUST specify which
target it wants — there is no implicit cross-connection default.

This document is the **contract** between the broker and its callers. It
spells out what callers can rely on, what they can't, and the exact CLI
shape.

---

## Files

| File | Role |
|---|---|
| `shared/scripts/sap_session_broker.ps1`     | The broker. PowerShell. Handles mutex, JSON registry, cleanup sweep, action dispatch. |
| `shared/scripts/sap_session_broker_com.vbs` | SAP COM helper. VBScript run via 32-bit `cscript`. Performs `findById` / `Info` reads, spawns new sessions, sends `/n` resets. |
| `{WORK_TEMP}\session_registry.json`         | The registry. UTF-8, no BOM. Single source of truth. |

The broker shells out to the COM helper for every SAP-side operation because
PowerShell 7+ / .NET 5+ cannot bind to the SAP GUI Scripting Engine
(`GetActiveObject` was removed; 32-bit Windows PowerShell 5.1 fails because
the SAPGUI ProgID isn't in the Running Object Table; 32-bit `cscript`
handles it fine).

---

## What the broker promises

1. **Mutual exclusion.** At any instant, at most one `task_id` holds a
   `claimed` entry for any given session `path`.
2. **Connection isolation.** A claim resolved against connection N
   never returns a session of connection M. The acquire-time resolver
   refuses to default across connections when ambiguous.
3. **Cleanup + identity reconciliation on every call.** Acquire, release,
   discover and gc run a sweep that first mirrors the **live SAP identity**
   onto each connection block (the live state is the source of truth for
   every field read from `GuiSessionInfo`), then drops entries reflecting
   any of these failure modes:
   - The SAP GUI session was closed (`findById` returns nothing).
   - The owner PID is no longer alive (when supplied by the caller).
   - The claim's TTL expired.
   - A relogin happened on a connection. A `/app/con[N]` slot is recyclable:
     the user can close system A's connection and open system B in the same
     slot. The swap is detected by the **(system, client, user) identity
     tuple** changing — NOT by `SystemSessionId`, which on the kernels we run
     (S/4HANA 1909, 754) is **per-workstation, not per-logon**, and stays
     byte-identical across an A→B swap on one slot. On a tuple change the
     block's identity is replaced wholesale with the live one and its stale
     `connection_id` (the profile association) is cleared; the next login
     finalize re-assigns it. A rotated `SystemSessionId` or a changed logon
     language are also treated as relogin signals. In every case that
     connection's entries are dropped (the prior sessions are gone, even when
     SAP recycles the same paths); other connections are unaffected.
   - The entire connection was closed (its `connection_path` no longer
     resolves); all of that connection's entries are dropped.
4. **Spawn-on-demand.** If acquire can't find a free session on the
   target connection, the broker spawns one on that specific connection
   via `/oSESSION_MANAGER` and registers it.
5. **Idempotent acquire.** If the same `task_id` already holds a `claimed`
   entry on ANY connection, acquire returns that path unchanged (with
   refreshed `claim_time`) — even if the caller passed a connection
   filter that points elsewhere. This is deliberate: the second call
   wants the existing session, not a new one.
6. **Pre-allocation Easy-Access verification.** Before handing out a path,
   the broker verifies the session is at SAP Easy Access. If not, it
   sends `/n` and re-verifies; if still not, it marks the entry
   `user_owned` and denies the acquire so the caller can retry.

---

## What the broker does NOT promise

1. **Path stability across re-acquires.** SAP's `(path, SessionNumber,
   SystemSessionId)` triple is recyclable on the kernels we tested
   (S/4HANA 1909 kernel 754). There is no stable per-session identity
   exposed by `GuiSession.Info`. Callers that need session continuity
   across multiple skill invocations MUST hold the claim open for the
   entire workflow.
2. **Recovery if the user destroys a session mid-task.** The next
   `findById` in the consumer's VBS will fail; the consumer must
   surface the failure cleanly. The broker drops the entry on the
   next sweep but the in-flight task is unrecoverable.
3. **Allocation of user-owned sessions.** Sessions discovered mid-work
   (transaction != `S000`/`SMEN`, or a popup is open) are tracked as
   `user_owned` and never handed out — even if the user idles them
   later. Manual `release` can reclassify if needed.
4. **Defense against out-of-band access.** Tools that drive SAP GUI
   *without* going through the broker (legacy skills, manual user
   actions) can race with broker-managed claims. The broker's mutex
   only serializes broker-aware callers.

---

## CLI contract

All actions take `-WorkTemp <abs-path>` (location of the registry file).
Last line of stdout is always a status string the caller parses.
Exit codes: 0 on success, 1 on logical denial (`DENIED:` line),
2 on usage / IO / SAP-unreachable errors.

### `acquire`

```
pwsh -File sap_session_broker.ps1 -Action acquire `
    -TaskId      "<unique-task-id>" `      # required
    -OwnerSkill  "<skill-name>" `          # optional, free-form
    -OwnerPid    <caller-PID> `            # optional, see note below
    -WorkTemp    "<abs-path>" `
    [-TtlSeconds   600]                     # default 600 = 10 min
    # --- connection-targeting (use ONE; resolution order below) ---
    [-SessionPath    "/app/con[N]/ses[M]"]   # 1. explicit; derives connection
    [-ConnectionPath "/app/con[N]"]          # 2. target a specific connection
    [-SystemName     "<SID>"]                # 3. tuple-match: any combination
    [-Client         "<CLNT>"]               #    of these three filters the
    [-User           "<USR>"]                #    live connections by GuiSession.Info
    [-PinFile        "<path>"]               # 4. read pin file -> use its
                                              #    session_path, or fall back to
                                              #    its (system_name,client,user)
```

**Connection-targeting resolution order** (first hit wins):

1. `-SessionPath` — explicit `/app/con[N]/ses[M]`; broker derives the
   connection from the path.
2. `-ConnectionPath` — explicit `/app/con[N]`; broker allocates within it.
3. `-SystemName` / `-Client` / `-User` — any non-empty subset filters
   the live connections. If exactly one matches, use it.
4. *(Phase 4.2 — removed)* `-PinFile` is still accepted by the broker
   for back-compat but no longer the default resolver. The AI-session
   pin (`ai_sessions[<id>].connection_id`, derived automatically from
   the broker's parent-PID walk) takes precedence and covers the same
   case.
5. **Exactly one connection attached** — silent default. Preserves the
   single-connection 99% case for callers that don't pass any targeting
   argument.
6. **Otherwise** — `DENIED: ambiguous target: N connections attached and
   no resolver supplied` (caller must add a targeting arg).

stdout last line:
```
ACQUIRED: path=<path> sessionNumber=<n> connection=<connection_path> reused=true|false
```
or
```
DENIED: <reason>            # exit 1
ERROR:  <reason>            # exit 2
```

`reused=true` means the path came from the registry (existing slot or
idempotent re-acquire). `reused=false` means the broker spawned a new
session for this acquire.

**About `-OwnerPid`.** Pass the PID of the **caller** (the skill /
agent process that will hold the claim), NOT the broker process itself.
The broker is transient. If you omit `-OwnerPid` (or pass `0`), the
broker stores `owner_pid=0` and the sweep skips the dead-task check for
that entry — TTL becomes the only safety net.

### `release`

```
pwsh -File sap_session_broker.ps1 -Action release `
    -TaskId   "<unique-task-id>" `
    -WorkTemp "<abs-path>"
```

stdout last line:
```
RELEASED: path=<path>       # the broker also sent /n to the session
NOT_FOUND                   # no matching claim (already released / swept)
```

Release is idempotent and never fails for an unknown task. Skills should
always call release on every exit path (success, failure, exception).

### `gc`

```
pwsh -File sap_session_broker.ps1 -Action gc -WorkTemp "<abs-path>"
```

Sweeps stale entries without acquiring. Prints one `DROP:` line per drop
with the reason, then a final summary:
```
DROP: <path> task=<id> reason=<session_closed|pid_dead|ttl_expired|system_changed|logon_changed|language_changed|connection_closed>
GC: dropped <n> stale entries
```

Useful as a startup cleanup (`/sap-login` Step 6) and between parallel
batches in the scaffolder.

### `list`

```
pwsh -File sap_session_broker.ps1 -Action list -WorkTemp "<abs-path>"
```

Read-only snapshot. Pretty-prints the full registry JSON. No side effects.

### `discover`

```
pwsh -File sap_session_broker.ps1 -Action discover -WorkTemp "<abs-path>"
```

Runs the reconciliation sweep first (so an existing block whose `/app/con[N]`
slot was reused by a different system is refreshed to the live identity —
see the cleanup contract), then walks `oCon.Children` and registers any
session the broker doesn't know about. Classifies each as `free` (at Easy
Access, no popup) or `user_owned` (mid-work). Output:
```
DISCOVERED: <n> new (total free=<f> user_owned=<u>)
```

Call this once after `/sap-login` succeeds. Idempotent for an unchanged
system — re-running adds nothing if everything is already known. After a
slot is reused by a different system, the stale entries are dropped and the
live sessions re-registered, so `discover` then `list` reflect the live
identity (and `set-connection-id` re-binds the profile).

---

### `ensure-own-session`

```
pwsh -File sap_session_broker.ps1 -Action ensure-own-session -WorkTemp "<abs-path>" [-TtlSeconds <n>] [-OwnerSkill <name>]
```

Guarantees the calling **AI session** owns a dedicated session on its
pinned connection, so two conversations logged into the **same** SAP
connection never drive the same `/app/con[N]/ses[M]` (the
`Get-SapCurrentSessionPath` resolver otherwise hands both the connection's
first session). Auto-resolves the AI-session id (parent-PID walk) and:

1. already claims a session here → refresh + return it;
2. else the session it currently *resolves to* (mirror of
   `Get-SapCurrentSessionPath`: first `free`, else first entry) is
   **formalized** — claimed in place, no GUI navigation — UNLESS that
   session is claimed by a *different live* AI session;
3. else (resolved target taken by a live other) → **spawn** a fresh
   session, reset only the newcomer to Easy Access, and claim it.

The claim's `owner_pid` is the AI session's conversation PID (reverse-
mapped from `runtime\ai_session_by_pid\`), so the PID-death sweep releases
it when that conversation ends. Idempotent and non-disruptive (never
navigates another conversation's session). Wired into `/sap-login`
**Step 6.7** so isolation is automatic for every parallel login. Output:
```
OWN_SESSION: path=<p> connection=<c> reused=<bool> spawned=<bool> [formalized=true]
NO_PIN: <reason>     # this AI session is not pinned to a live connection yet
DENIED: <reason>     # contended connection + spawn failed (exit 1)
```

---

## Registry schema

`{WORK_TEMP}\session_registry.json`, UTF-8 no BOM. Schema v2 (multi-
connection, since Phase 3.5):

```json
{
  "updated_at": "2026-05-14T11:36:19",
  "connections": [
    {
      "connection_path": "/app/con[0]",
      "description":     "S4HANA_1909_MICHAELLI",
      "system_name":     "S4D",
      "client":          "100",
      "user":            "MICHAELLI",
      "logon_id":        "000C298056DE1FE193E27A22AD87CE0A",
      "entries": [
        {
          "path":           "/app/con[0]/ses[1]",
          "session_number": 2,
          "task_id":        "agent_a83f96",
          "owner_pid":      12345,
          "owner_skill":    "sap-se38-create",
          "status":         "claimed",
          "claim_time":     "2026-05-14T10:38:44",
          "ttl_seconds":    600,
          "discovered":     true
        }
      ]
    },
    {
      "connection_path": "/app/con[1]",
      "system_name":     "S4H",
      "client":          "200",
      "user":            "MICHAELLI",
      "logon_id":        "7B277BFC...",
      "entries": [ ... ]
    }
  ]
}
```

- `connections[].connection_path` — primary key for a connection block.
  The address-of-record (recyclable). Use `(system_name, client, user)`
  for stable identification.
- `connections[].logon_id` — current `SystemSessionId` for THIS
  connection. A *secondary* relogin signal only: on the kernels we run it is
  per-workstation, not per-logon, so it does NOT change when a slot is reused
  by a different system. Stable identification uses `(system_name, client,
  user)`; see the cleanup contract above. Empty before first
  acquire/discover on the connection.
- `connections[].connection_id` — the saved-profile UUID this live
  connection maps to, assigned by `set-connection-id` (login finalize). NOT
  read from SAP. Cleared by the sweep when the slot's identity tuple changes
  (the old profile association is then invalid); re-assigned on next finalize.
- `connections[].entries[].path` — primary key for a session within
  the connection. Stable while the session is alive.
- `connections[].entries[].session_number` — `Info.SessionNumber` at
  claim time. Recorded for forensics; NOT used as identity (recycles).
- `connections[].entries[].status` — one of `free`, `claimed`,
  `user_owned`.

The pre-3.5 v1 schema was a flat `entries` array with one top-level
`logon_id`. The v2 broker auto-detects v1 registries by the missing
`connections` field and rebuilds fresh on first call.
- `entries[].discovered` — `true` if pre-existing at discover time;
  `false` if the broker spawned it.

The schema is internal — don't depend on it from outside the broker.
Use the CLI.

---

## Cleanup architecture (4 hooks)

The broker maintains the registry's correctness through four hooks. All
of them run *inside* the named mutex.

### Hook 1: reactive cleanup on every `acquire` / `release`

Every acquire and release call runs `Sweep-StaleEntries` before doing its
own work. Sweep checks each entry against the 4 failure modes and drops
the stale ones. Cost: one cscript call (INFO), then in-memory comparisons.

### Hook 2: explicit `release` on task completion

Skills call `release` in their exit path. Release sends `/n` to the
session (reset to Easy Access) then marks the entry `free`. If the
session was destroyed in the meantime, the COM helper reports
`{"ok":false}` and release silently proceeds — the next sweep will
drop the entry.

### Hook 3: standalone `gc` for manual / scheduled cleanup

Same sweep logic but invoked without an acquire. Verbose mode emits a
`DROP:` line per dropped entry with the reason. Useful for:
- `/sap-login` startup (purge stale state from a previous AI session).
- Between parallel batches in the scaffolder.
- Manual operator inspection when something looks wrong.

### Hook 4: pre-flight `discover`

Reconciles each existing block to live identity (catching a slot reused by a
different system), then registers any pre-existing sessions the broker
doesn't know about. Classifies each as `free` or `user_owned`. Run once after
`/sap-login`; the broker only allocates sessions it explicitly knows about.

---

## How callers integrate

### Typical skill wrapper pattern (PowerShell)

```powershell
$BROKER = '<SAP_DEV_CORE_SHARED_DIR>\scripts\sap_session_broker.ps1'
$WT     = '{WORK_TEMP}'

# Acquire — pass our own $PID so dead-task cleanup works.
$out = & powershell -ExecutionPolicy Bypass -File $BROKER `
    -Action acquire `
    -TaskId     $env:SAPDEV_TASK_ID `      # or another stable handle
    -OwnerSkill 'sap-se38-create' `
    -OwnerPid   $PID `
    -WorkTemp   $WT
$lastLine = ($out | Select-Object -Last 1)
if ($lastLine -notmatch '^ACQUIRED:') {
    Write-Error "could not acquire SAP session: $lastLine"
    exit 1
}
# Parse: ACQUIRED: path=/app/con[0]/ses[1] sessionNumber=2 reused=true
$null = $lastLine -match 'path=(\S+)'
$sessionPath = $matches[1]

try {
    # ... thread $sessionPath into the cscript that does the real work ...
    cscript //NoLogo "<SKILL_DIR>\references\sap_xx.vbs" /session $sessionPath ...
} finally {
    # Always release, even on failure.
    & powershell -ExecutionPolicy Bypass -File $BROKER `
        -Action release `
        -TaskId   $env:SAPDEV_TASK_ID `
        -WorkTemp $WT | Out-Null
}
```

### Identity propagation: `SAPDEV_TASK_ID`

The `task_id` is supplied by the caller. Conventions:

- A top-level skill invocation gets `$env:SAPDEV_TASK_ID` from the
  orchestrator. If not set, derive a UUID and use it for the run.
- A scaffolder fan-out passes a different `task_id` to each sub-agent
  (e.g. `agent_<short-id>`) so each agent gets its own claim.
- A multi-step skill that calls other skills internally propagates
  `SAPDEV_TASK_ID` so the inner skills idempotently re-claim the
  same session (returns the existing `path` unchanged).

The orchestrator (Claude) is responsible for setting `SAPDEV_TASK_ID`
before invoking any skill that drives SAP GUI. The convention mirrors
the existing `SAPDEV_RUN_ID` / `SAPDEV_PARENT_RUN_ID` chain used by the
log helper.

### Scaffolder fan-out pattern

```
1. Orchestrator: pwsh -File sap_session_broker.ps1 -Action discover ...
2. For each scenario i:
     orchestrator: acquire -TaskId "agent_<i>" -OwnerPid $PID
       -> ACQUIRED: path=/app/con[0]/ses[N_i]
     orchestrator: dispatch Agent { prompt includes --session N_i }
3. Wait for all agents to return.
4. For each scenario i:
     orchestrator: release -TaskId "agent_<i>"
```

The orchestrator owns the lifetime of every claim. Sub-agents don't
touch the broker — they just use the path they were given.

---

## Known constraints and caveats

1. **No stable per-session identity.** See `sap-dev/CLAUDE.md` and the
   verification test results in the design notes. `SystemSessionId`
   is per-logon, `SessionNumber` recycles with the path index. The
   broker compensates with reactive cleanup and operational hygiene
   rather than identity.

2. **PowerShell can't bind SAP COM directly.** The broker uses
   `sap_session_broker_com.vbs` as a 32-bit cscript subprocess for
   every SAP introspection / mutation. Each helper call is ~80-100ms;
   acquire typically takes 200-400ms total.

3. **Mutex is per-Windows-user-session.** Two AI sessions running under
   the same Windows account share the broker (correctly serialised).
   Two Windows accounts share neither mutex nor registry (each has
   its own `{WORK_TEMP}`).

4. **Cap of 6 sessions per SAP connection.** SAP default
   `rdisp/max_alt_modes = 6`. Acquire fails with `DENIED: no free
   session and spawn failed (cap reached or SAP GUI not running)`
   once the cap is hit. Increase the SAP profile parameter to
   raise it.

5. **OK-code spawn idiosyncrasy.** `/oSESSION_MANAGER` is the only
   spawn mechanism verified to work on S/4HANA 1909 kernel 754.
   Bare `/o` is a no-op; `CreateSession` isn't surfaced. Other
   kernels may differ — the helper will report `{"ok":false}` and
   acquire returns `DENIED`.

6. **Cleanup may briefly run twice in races.** When two callers both
   trigger a sweep simultaneously, the mutex serialises them; the
   second one finds an already-clean registry and is a no-op. The
   only observable effect is that `gc -VerboseDrops` may emit drops
   that were already done by a peer call — accept this as benign
   double-reporting.

---

## Operational playbook

| Situation | What to do |
|---|---|
| "I want to see what's claimed right now." | `list` |
| "I think there are stale entries." | `gc` (prints what it dropped, why) |
| "I just ran `/sap-login`." | `discover` (idempotent; registers any pre-existing sessions) |
| "A sub-agent crashed and I'm not sure if its claim was released." | `gc` then `list`. The pid_dead path drops it if the agent's process is gone. |
| "I want to release a stuck claim manually." | `release -TaskId <id>`. Idempotent; returns `NOT_FOUND` if nothing to do. |
| "I want to reset everything from scratch." | Delete `{WORK_TEMP}\session_registry.json`; next call re-creates it empty. Any in-flight claims will be lost, so coordinate first. |

---

## Versioning

Mutex name encodes the schema version. **Current: `SapDevSessionBroker_v2`**
(Phase 3.5 — multi-connection registry schema, new connection-targeting
acquire args, per-connection cleanup, `connection_closed` failure mode).
The previous `_v1` mutex (single flat-entries schema) is retired; running
a v1 broker and a v2 broker concurrently against the same registry would
corrupt state. The v2 broker auto-detects a v1 registry on disk and
rebuilds it fresh; the operator's first call after upgrading prints a
`WARN: v1 registry detected; rebuilding under v2 schema` line.

Bump the version when:
- The registry JSON schema changes incompatibly.
- The CLI contract changes incompatibly.
- The cleanup algorithm changes in a way callers might observe.

| Version | Released | Highlights |
|---|---|---|
| v1 | Phase 3 (initial broker) | Single flat-entries schema. Assumed one SAP connection. Mutex: `SapDevSessionBroker_v1`. |
| v2 | Phase 3.5 (multi-connection) | Nested `connections[]` schema. Mutex: `SapDevSessionBroker_v2`. New acquire args: `-ConnectionPath`, `-SystemName`, `-Client`, `-User`, `-PinFile`. New failure modes: `connection_closed`, per-connection `logon_changed`. ACQUIRED stdout now includes `connection=<path>`. |
