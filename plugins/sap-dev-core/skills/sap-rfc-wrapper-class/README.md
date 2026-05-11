# SAP RFC Wrapper — Class Method Skill

Generates an RFC-callable wrapper function module that internally invokes a
non-RFC-callable ABAP class method. This lets you call a class method from
outside SAP (e.g. via SAP NCo 3.1).

The generated FM name follows the pattern `Z_CLSWRP_<CLASS>_<METHOD>`,
truncated to 30 characters.

## Skill Overview

1. Parse: class name + method name + optional function group + optional
   package + optional transport
2. Read the method's parameter interface from `SEOPARAM` / `SEOEXCEP` via
   `RFC_READ_TABLE`
3. Generate a deployable ABAP function module that:
   - Mirrors the method's parameters as RFC import / export / changing /
     tables / exceptions
   - Internally instantiates the class and calls the method
   - Maps exceptions back to the RFC interface
4. Deploy via `/sap-se37` under the configured function group, package, and TR

## Auto-Trigger Keywords

- `rfc wrapper class`, `rfc wrapper for method`, `wrap class method as rfc`
- `expose method as rfc`, `make method callable from outside`

## Usage

```text
/sap-rfc-wrapper-class ZCL_HK_INVOICE BUILD_INVOICE
/sap-rfc-wrapper-class ZCL_HK_INVOICE BUILD_INVOICE ZHKFG_API
/sap-rfc-wrapper-class ZCL_HK_INVOICE BUILD_INVOICE ZHKFG_API ZHK_MM S4DK900123
```

Conversational forms:

- "Make ZCL_HK_INVOICE=>BUILD_INVOICE callable via RFC"
- "Generate an RFC wrapper for the BUILD_INVOICE method of ZCL_HK_INVOICE"
- "Expose ZCL_HK_UTIL=>VALIDATE as RFC under function group ZHKFG_API"

## Prerequisites

- SAP NCo 3.1 (32-bit, .NET 4.0) installed in the GAC
- SAP connection configured in `sap-dev-core/settings.json`
- Authorisation S_DEVELOP for object class FUGR + FUNC
- Source class must already exist and be activated

## Limitations

- Public instance and static methods only — private / protected methods are
  not exposed
- Generic types (`type any`, `type any table`) cannot be exposed via RFC and
  are rejected with an explicit error
- Reference types (`type ref to ...`) cannot be exposed via RFC and are
  rejected

## Version

- Skill Version: 1.0.0
- Last Updated: 2026-05-03

## License

GPL-3.0 License - See LICENSE file in repository root.
