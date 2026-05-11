# Transport Request Resolution Rule (MANDATORY for deploy skills)

This rule defines **how every deploy skill (sap-se11, sap-se38, sap-se37,
sap-se24, sap-se91, etc.) obtains a modifiable transport request** when one
is needed. Skills MUST NOT implement their own ad-hoc TR resolution logic —
delegate to `/sap-transport-request`, which centralises this flow.

---

## 1. Settings that drive the flow

Read from sap-dev-core `settings.json` `userConfig`:

| Setting | Allowed values | Default |
|---|---|---|
| `way_to_get_transport_request` | `DEFAULT`, `ASK`, `CREATE_NEW` | `DEFAULT` |
| `sap_dev_transport_request` | A TR number (e.g. `S4DK900123`) or blank | blank |
| `rule_of_tr_description` | `ASK`, `PATTERN`, `FIXED`, `RANDOM` | `ASK` |
| `tr_description_template` | Template/literal string | blank |

Unknown values fall back to the defaults above with a one-line warning.

---

## 2. Resolution flow (`way_to_get_transport_request`)

A skill that needs a TR calls `/sap-transport-request`. The flow:

### `DEFAULT` — always reuse the saved default

1. If `sap_dev_transport_request` is set, verify it is still modifiable
   (TRSTATUS = `D`) via RFC (`TR_READ_REQUEST` or equivalent).
2. **Modifiable** → return it. Do not ask the user.
3. **Released / locked / not found** → ask the user:
   > "The default transport `<TR>` is not modifiable. Provide a different
   > modifiable TR, or create a new one?"
   - If the user supplies a TR → verify modifiable; if not, repeat.
   - If the user picks "create new" → invoke `/sap-se01` (see §3).
4. Persist the resolved TR number to `sap_dev_transport_request` via
   `/update-config` so future calls reuse it.

### `ASK` — ask each time, optionally save as default

1. Do NOT auto-read `sap_dev_transport_request`.
2. Ask the user:
   > "Which transport should I use? (existing TR number, or 'new' to create one)"
3. If the user supplies a TR → verify modifiable; if not, repeat.
4. If the user picks "new" → invoke `/sap-se01` (see §3).
5. After resolving, ask once:
   > "Save `<TR>` as the default for future requests? (y/N)"
   - On `y`, persist to `sap_dev_transport_request`.

### `CREATE_NEW` — always create a fresh TR

1. Do NOT read `sap_dev_transport_request`. Do NOT ask.
2. Invoke `/sap-se01` (see §3) to create a new request.
3. Return the new TRKORR. Do NOT persist it as the default.

### Mid-session change

If the user explicitly says something like *"switch to ask mode"* or *"always
create new from now on"*, persist the new value to
`way_to_get_transport_request` immediately and follow it for the rest of the
session.

---

## 3. New-TR creation rules (when `/sap-se01` is invoked by this flow)

### Request type

- Default to **W (Workbench)**. Do NOT ask the user for the type.
- Only honour `C (Customizing)` when the user explicitly requested it
  (e.g. "create a customizing TR for ...").

### Description (driven by `rule_of_tr_description`)

| Value | Behaviour |
|---|---|
| `ASK` | Prompt the user: "Short description for the new TR?" |
| `PATTERN` | Render `tr_description_template`, substituting placeholders (see below) |
| `FIXED` | Use `tr_description_template` verbatim |
| `RANDOM` | Generate a random alphanumeric description (e.g. `TR_<8-hex>_<YYYYMMDD>`) |

Placeholders for `PATTERN`:

| Placeholder | Source |
|---|---|
| `{YYYYMMDD}` | Today (workstation date) |
| `{HHMMSS}` | Now (workstation time) |
| `{USER}` | `sap_user` from settings.json |
| `{OBJECT_TYPE}` | Object type the caller is deploying (`TABLE`, `STRUCTURE`, `DTEL`, `DOMAIN`, `TABLETYPE`, `VIEW`, `SEARCHHELP`, `LOCKOBJECT`, `REPORT`, `FUGR`, `FM`, `CLASS`, `MSGCLASS`, …) |
| `{OBJECT_DESCRIPTION}` | Object name being deployed (e.g. `ZHKMARA`) |
| `{RANDOM4}` | 4-character random alphanumeric (uniqueness suffix) |

The caller (`/sap-se11`, `/sap-se38`, …) MUST pass `OBJECT_TYPE` and
`OBJECT_DESCRIPTION` to `/sap-transport-request` so that `PATTERN` can be
rendered. If a caller cannot supply them, fall back to `OBJECT_TYPE = OBJ` and
`OBJECT_DESCRIPTION = <skill name in upper case>`.

### Length constraint

The **SE01 short description field is 60 characters max**. After rendering,
truncate to 60 chars by:
1. If the rendered text ≤ 60 chars, use as-is.
2. Otherwise, drop vowels from `{OBJECT_DESCRIPTION}` first, then from
   `{OBJECT_TYPE}`, then hard-truncate the entire string to 60 chars.

---

## 4. Persisting the result

- `DEFAULT` mode → always persist the resolved TR to `sap_dev_transport_request`.
- `ASK` mode → persist only if the user opts in.
- `CREATE_NEW` mode → never persist.

Persistence is via `/update-config` writing to sap-dev-core `settings.json`.

---

## 5. What deploy skills MUST do

Every skill that needs a TR (currently sap-se11, sap-se38, sap-se37, sap-se24,
sap-se91) MUST include a step **before** the package/transport dialog:

```
## Step N — Resolve Transport Request

If a transport request is needed (i.e. PACKAGE is non-empty and not $TMP),
invoke /sap-transport-request with:
  OBJECT_TYPE        = <e.g. REPORT, TABLE, FM, CLASS, MSGCLASS>
  OBJECT_DESCRIPTION = <the object name being deployed>

The skill resolves the TR per shared/rules/tr_resolution.md and returns a
modifiable TRKORR. Use that TRKORR as the %%TRANSPORT%% token value.

If PACKAGE is empty or $TMP, skip this step (local object — no TR needed).
```

Skills MUST NOT prompt the user directly for the TR or call `/sap-se01`
themselves — let `/sap-transport-request` mediate.
