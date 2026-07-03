# Security & Authorizations Guide

What a customer security / Basis team needs to know before letting an AI
assistant drive SAP through these plugins: what the AI's SAP user must be
allowed to do, how credentials are handled, what the SAP GUI Security trust
rule means, and which write-safety controls are enforced where.

Everything below runs **on the developer's Windows workstation** against SAP
via the standard GUI Scripting and RFC interfaces, under the developer's own
Dialog user. The skills make no cloud calls of their own and cache no SAP data
off the workstation.

---

## 1. Required SAP authorizations

Grant the AI's SAP user a normal **developer role on DEV**, scoped to the
customer namespace. The table maps plugin capability to the authorization
objects involved:

| Capability (skills) | Authorization objects (key fields) |
|---|---|
| ABAP Workbench create/change/activate — `/sap-se38 /sap-se37 /sap-se24 /sap-se11 /sap-se91 /sap-function-group /sap-se41 /sap-se51 /sap-se54 /sap-cmod /sap-se19 /sap-activate-object /sap-check-fix` | `S_DEVELOP` (ACTVT 01/02/03; OBJTYPE PROG/FUGR/CLAS/INTF/DOMA/DTEL/TABL/VIEW/TTYP/SHLP/ENQU/MSAG/DYNP…; DEVCLASS = your Z*/Y* packages), `S_TCODE` for the transactions used |
| Packages — `/sap-se21 /sap-change-package` | `S_DEVELOP` (OBJTYPE DEVC), `S_TCODE` SE21/SE80 |
| Transports create/release — `/sap-transport-request /sap-se01` | `S_TRANSPRT` (TTYPE DTRA/TASK; ACTVT 01/02/03 + **43 release**), `S_TCODE` SE01/SE09/SE10 |
| Transport import — `/sap-stms` | `S_CTS_ADMI` (import functions) + STMS tcodes; production imports additionally pass the skill's typed-SID gate |
| Number ranges — `/sap-snro` | `S_NUMBER`, `S_TCODE` SNRO |
| Table reads — `/sap-se16n`, diagnose readers | `S_TABU_DIS` / `S_TABU_NAM` for the read tables (SE16N), `S_TCODE` SE16N/SM12/SM13/SM37/ST22/SLG1/ST05 |
| Table maintenance — `/sap-update-addon` | `S_TABU_DIS`/`S_TABU_NAM` maintenance on the Z/Y tables, SM30 tcode where a view exists |
| ATC / Code Inspector — `/sap-atc`, migrate analyze | `S_DEVELOP` (display), SCI/ATC tcodes (`SCI`, `SCICM`, ATC monitor); central ATC additionally needs the hub trust/RFC setup |
| ABAP Unit — `/sap-run-abap-unit`, `/sap-gen-abap-unit` | `S_DEVELOP` on the tested objects (unit tests execute the code under test) |
| RFC calls (verification gates, lookups, wrapper) | `S_RFC` (ACTVT 16) for the function groups behind `RFC_READ_TABLE`, `RFC_SYSTEM_INFO`, `RPY_*`, `DDIF_*`, `CTS_API_*`, and (after `/sap-dev-init`) the Z wrapper's function group; plus `S_TCODE` free RFC logon |
| GUI file transfer (source upload/download, SE16N export) | `S_GUI` (ACTVT 61) |
| Spool — `/sap-sp02` | `S_SPO_ACT` on own spool requests |

Practical notes:

- **Exact field values are release- and policy-specific.** Derive the final
  role the standard way: run a pilot with a wider dev role, capture
  `STAUTHTRACE`/`ST01` traces while exercising the skills you'll use, and cut
  the role from the trace. After any authorization failure, `SU53` on the AI's
  user shows the missing object.
- **`/sap-doctor` probes authorizations mechanically** (auth group, Step 3b):
  `references/sap_doctor_authz_probe.ps1` reads the machine-readable mirror of
  this table — `sap-dev-core/shared/tables/required_authorizations.tsv` — and
  calls `SUSR_USER_AUTH_FOR_OBJ_GET` (RFC-enabled; **no dev-init wrapper
  needed**) for the logged-in user, emitting `AUTH: PASS|FAIL <capability>`.
  **Keep the TSV in sync with this table when you edit either.** This table +
  SU53 remains the authoritative contract for the exact, release-specific field
  values (the probe checks the representative object/fields per capability).
- **Recommendation:** give the AI a dedicated, personal-but-separate Dialog
  user (e.g. `DEV_AI_<initials>`) on DEV only. That makes every SAP change
  attributable to the AI-assisted workflow in standard SAP audit trails
  (version management, transport ownership, SM20 where enabled), and lets you
  revoke it independently.

## 2. Credential handling

- **At rest**: `connections.json` under `{work_dir}\runtime\` stores
  `sap_password` DPAPI-encrypted (`dpapi:<base64>`, CurrentUser scope). A
  copied file is useless on another machine/account. Plaintext values are
  accepted for migration but trigger a re-save prompt.
- **In flight**: SAP GUI and NCo need the plaintext at logon, so `/sap-login`
  generates a runner in the per-run scratch dir (`{RUN_TEMP}`) with the
  decrypted value substituted. The runner deletes the password-bearing files
  in a `finally` block **in the same process** (crash of the login still
  cleans up), Step 5 sweeps again, and every later `/sap-login` removes any
  >10-minute-old residue a hard process kill might have left. Never copy these
  files out of `{RUN_TEMP}`.
- **In logs**: the structured loggers redact `sap_password`/`password`/
  `token`/`secret`… by key (`log_redact_keys`), recursively.
- The password is **never** echoed into the conversation, and never stored
  anywhere server-side.

## 3. The SAP GUI Security trust rule (`saprules.xml`)

SAP GUI raises a per-program security dialog for file reads/writes a script
triggers. Because SAP keys "Remember my decision" on the individual program
dynpro, freshly generated programs would raise the dialog forever. So
`/sap-dev-init` Step 1b writes ONE broad rule into
`%APPDATA%\SAP\Common\saprules.xml`:

- **Scope**: read/write **limited to `{work_dir}`** (the plugin's sandbox
  directory) — NOT the whole filesystem.
- **Context**: any system/client/program by default. This is deliberate: the
  rule is path-scoped, and the same workstation sandbox serves every SAP
  system the developer works on. It is also flagged as a security-weakening
  action, so the operator explicitly approves it once.
- **Least-privilege option**: pass `-System <SID> -Client <nnn>` to
  `sap_gui_security_grant.ps1` to pin the rule per system; you then re-grant
  per SID.
- **Audit/revoke**: the rule is plain XML in `saprules.xml` (also visible
  under SAP GUI Options > Security > Security Configuration); delete the
  `{work_dir}` rule to revoke. SAP Logon must restart to pick up external
  edits.

## 4. Write-safety rules and where they are enforced

| Rule | Where enforced |
|---|---|
| No direct SQL writes on SAP **standard** tables (Z/Y only; reads always allowed) | `shared/rules/skill_operating_rules.md` contract for the AI + no skill ships such a write path; TADIR cleanup goes through SAP's own `TR_TADIR_INTERFACE` API with a definition-gone guard that refuses live objects |
| No unsolicited deployments | Operating-rules contract + the Claude Code permission layer: live SAP writes are write-classified tool calls the harness surfaces for approval in non-auto modes |
| Destructive operations confirm first | In-skill: delete flows (SE01/SE11/SE21/SE24/SE37/SE38/function-group) require explicit user confirmation; TR release shows the object inventory first; STMS production import gates on a typed SID |
| Migration campaign human gates | **In code**: `/sap-cc-campaign next` refuses (`BLOCKED`, exit 3) until the scope sign-off is recorded; `/sap-cc-remediate record` refuses until the dry-run review sign-off is recorded |
| Quality gates before deploy | ATC gate fails loud on parse/scope problems (never silently 0 findings); post-activate RFC verification + SE38 content verification catch silent deploy failures |
| Dev-environment teardown safety | `/sap-dev-clean` validates the anchor (wrapper FM → TADIR truth) and ABORTS on mismatch rather than deleting the wrong package/TR |

Honest boundary: the operating rules are a *workstation-side* contract
(prompt + harness permissions + in-skill guards), not a server-side control.
The SAP-side control remains the authorization concept — which is why the
dedicated, DEV-only AI user in §1 is the recommendation.

## 5. Data flow & audit trail

- All processing is local: workstation ⇄ SAP via SAP GUI Scripting / NCo RFC.
  Design specs, generated ABAP, logs, and artifacts live under `{work_dir}`.
- Structured JSONL logs (`{work_dir}\logs`) record every skill run with
  `run_id` chaining and a stable failure vocabulary
  (`shared/rules/error_classes.md`) — suitable for SIEM/dashboard ingestion.
- `/sap-evidence-pack` bundles the per-change artifacts (checks, ATC results,
  unit runs, approvals) for audit hand-off.
- On the SAP side, every change is a normal transported change under the AI
  user's name — version management and transport logs apply unchanged.

## 6. Security-review checklist (copy for your assessment)

1. Create the dedicated AI Dialog user on DEV; assign the role derived from §1
   (start wide on a sandbox, cut from `STAUTHTRACE`).
2. Confirm `sapgui/user_scripting = TRUE` is acceptable on DEV (and only DEV,
   if policy demands; the plugins do not need it on PRD — `/sap-stms` PRD
   imports are the only PRD-facing action and are RFC/GUI on the domain
   controller with a typed-SID gate).
3. Review the `{work_dir}` saprules.xml grant; narrow per-system if required.
4. Verify DPAPI credential storage meets policy (or have operators type the
   password per session — DPAPI save is opt-in).
5. Set `log_retention_days` / redaction keys to policy; point `log_dir` at a
   collected location if you ingest logs.
6. Decide the Claude Code permission mode for live SAP writes (interactive
   approval vs. allowlisted).
