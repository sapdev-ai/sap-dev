# SAP Transport Request Skill

Resolves a modifiable SAP transport request, applying the
`way_to_get_transport_request` policy from `sap-dev-core/settings.json`.

This skill is the **single TR-resolution entry point** for every deploy skill
in sap-dev (sap-se11 / sap-se38 / sap-se37 / sap-se24 / sap-se91 / sap-se21
/ sap-change-package / …). Deploy skills delegate here so the user never has
to think about TR management — and so the policy is consistent across all
flows.

## Skill Overview

1. Parse the optional input (caller may pass an existing TR number to validate)
2. Read `way_to_get_transport_request` policy from settings:
   - **`DEFAULT`** — reuse `sap_dev_transport_request` from settings; ask only
     if blank or no longer modifiable
   - **`ASK`** — ask the user each time; offer to save the answer as the new
     default
   - **`CREATE_NEW`** — always create a fresh TR; never persist
3. If a TR is required and `CREATE_NEW` is in effect (or the user chose
   `new` after a non-modifiable / unverifiable candidate — the skill
   re-prompts per policy, it never silently substitutes a fresh TR), render
   a description per `rule_of_tr_description`
   (`ASK` / `PATTERN` / `FIXED` / `RANDOM`) using
   `tr_description_template`, truncated to 60 chars
4. Delegate creation to `/sap-se01` (GUI mode) or call
   `CTS_API_CREATE_CHANGE_REQUEST` (RFC mode) per `sap_dev_mode`
5. Return the resolved TR number to the caller

## Auto-Trigger Keywords

- `transport request`, `tr`, `get tr`, `resolve tr`
- `create transport`, `new transport request`
- "I need a TR for X"

## Usage

```text
/sap-transport-request
/sap-transport-request S4DK900123
/sap-transport-request OBJECT_TYPE=PROGRAM OBJECT_DESCRIPTION="ZHKR001"
```

Conversational forms:

- "Get me a transport request"
- "Create a new TR with description 'PaymentRefactor'"
- "Validate that TR S4DK900123 is still modifiable"

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in the GAC
- SAP connection configured in `sap-dev-core/settings.json`
- `way_to_get_transport_request` set in settings (defaults to `DEFAULT` if
  blank)
- For `CREATE_NEW` and `ASK`-with-create scenarios: authorisation S_TRANSPRT

## Description placeholders (PATTERN mode)

When `rule_of_tr_description = PATTERN`, the template can include:

- `{YYYYMMDD}` — current date
- `{HHMMSS}` — current time
- `{USER}` — the SAP user from settings
- `{OBJECT_TYPE}` — passed by the caller (e.g. `PROGRAM`)
- `{OBJECT_DESCRIPTION}` — passed by the caller (e.g. `ZHKR001`)
- `{RANDOM4}` — 4-character random suffix for uniqueness

Final result is truncated/compressed to the 60-character SE01 limit.

## Limitations

- Workbench requests only — Customizing requests require explicit
  `/sap-se01 C` invocation by the user
- Mid-session policy changes ("from now on, always ask") are persisted
  immediately to `way_to_get_transport_request` and honoured for the rest of
  the session

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
