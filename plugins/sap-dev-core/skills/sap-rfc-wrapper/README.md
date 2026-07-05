# SAP RFC Wrapper — Function Module Skill

Calls a non-RFC-enabled SAP function module by routing the call through a
generic wrapper FM (`Z_GENERIC_RFC_WRAPPER_TBL`). The wrapper executes the
target FM dynamically and serialises all parameters as asXML — letting you
invoke any locally-callable FM remotely without writing a per-FM wrapper.

## Skill Overview

1. Parse: target FM name + parameter values (key=value pairs)
2. Read the target FM's interface using `RPY_FUNCTIONMODULE_READ_NEW`
3. Validate the user-supplied parameter names and types against the interface
4. Build asXML payloads for import / changing / tables parameters
5. Invoke `Z_GENERIC_RFC_WRAPPER_TBL` via direct RFC, passing the FM name +
   payloads
6. Deserialise the export / changing / tables output and return to the caller

## Auto-Trigger Keywords

- `call fm via rfc`, `invoke fm remotely`, `call non-rfc fm`
- `rfc wrapper fm`, `wrap fm call`

## Usage

```text
/sap-rfc-wrapper-fm  RS_FUNCTION_POOL_INSERT  AREA=ZTEST  AREATEXT="Test FUGR"
/sap-rfc-wrapper-fm  ZHK_VALIDATE_INVOICE     IT_LINES=@C:\path\to\lines.xml
```

Conversational forms:

- "Call RS_FUNCTION_POOL_INSERT with AREA=ZTEST"
- "Invoke ZHK_VALIDATE_INVOICE remotely with the lines from this CSV"

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in the GAC
- SAP connection configured in `sap-dev-core/settings.json`
- **`Z_GENERIC_RFC_WRAPPER_TBL` must already exist in the SAP system.** Deploy
  it via `/sap-dev-init` (which deploys the bundled
  `references/Z_GENERIC_RFC_WRAPPER_TBL.abap`).
- Authorisation to execute the target FM under the SAP user

## Limitations

- Generic types (`type any`, `type any table`) in the target FM are not
  supported — asXML serialisation requires concrete types
- Reference types (`type ref to ...`) are not supported
- Target FM must be locally callable in the target system (i.e. exists and is
  active)
- Output size limited by RFC payload limits (~16 MB practical, varies by
  kernel)

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
