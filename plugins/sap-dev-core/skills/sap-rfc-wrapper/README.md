# SAP RFC Wrapper Skill

Reaches non-RFC-callable ABAP code from outside the system (e.g. SAP NCo 3.1),
in two modes:

- **`fm`** — **calls** a non-RFC-enabled function module by routing the call
  through the generic wrapper FM (`Z_GENERIC_RFC_WRAPPER_TBL`), which executes the
  target FM dynamically and serialises all parameters as asXML — letting you
  invoke any locally-callable FM remotely without writing a per-FM wrapper.
- **`class`** — **generates + deploys** a dedicated RFC wrapper function module
  for a non-RFC-callable class method (`Z_CLSWRP_<CLASS>_<METHOD>`, ≤30 chars),
  reading the method interface from the OO repository tables and deploying the
  generated FM via `/sap-se37`.

The two modes compose: run `class` once to build a wrapper FM, then call it (or
any FM) with `fm`.

> Replaces the former `/sap-rfc-wrapper-fm` and `/sap-rfc-wrapper-class` skills.

## Auto-Trigger Keywords

- `call fm via rfc`, `invoke fm remotely`, `call non-rfc fm`, `rfc wrapper fm`
- `wrap a class method for rfc`, `generate rfc wrapper for method`

## Usage

```text
/sap-rfc-wrapper fm     RS_FUNCTION_POOL_INSERT  AREA=ZTEST  AREATEXT="Test FUGR"
/sap-rfc-wrapper fm     ZHK_VALIDATE_INVOICE     IT_LINES=@C:\path\to\lines.xml
/sap-rfc-wrapper class  ZCL_HK_INVOICE BUILD_INVOICE
/sap-rfc-wrapper class  ZCL_HK_INVOICE BUILD_INVOICE ZHKFG_API ZHK_MM S4DK900123
```

Conversational forms:

- "Call RS_FUNCTION_POOL_INSERT with AREA=ZTEST"
- "Invoke ZHK_VALIDATE_INVOICE remotely with the lines from this CSV"
- "Generate an RFC wrapper for method BUILD_INVOICE of ZCL_HK_INVOICE"

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in the GAC
- SAP connection configured (run `/sap-login`)
- **`fm` mode:** `Z_GENERIC_RFC_WRAPPER_TBL` must already exist in the SAP system.
  Deploy it via `/sap-dev-init` (which deploys the bundled
  `references/Z_GENERIC_RFC_WRAPPER_TBL.abap`). Authorisation to execute the
  target FM under the SAP user.
- **`class` mode:** an active SAP GUI session for the `/sap-se37` deploy sub-step.

## Limitations

- Generic types (`type any`, `type any table`) are not supported — asXML
  serialisation requires concrete types.
- Reference types (`type ref to ...`) are not supported (in either mode).
- `fm`: target FM must be locally callable (exists and active); output size is
  bounded by RFC payload limits (~16 MB practical, varies by kernel).
- `class`: source-based classes may expose no DDIC metadata (`SEOSUBCODF` empty) —
  fall back to an RTTI helper FM.

## Version

- Skill Version: 2.0.0
- Last Updated: 2026-07-05

## License

GPL-3.0 License - See LICENSE file in repository root.
