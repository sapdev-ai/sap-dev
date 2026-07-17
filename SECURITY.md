# Security Policy

## Supported versions

Only the latest minor release line of `sap-dev` receives security fixes during
the early-access (`0.x`) phase. Once `1.0.0` ships, the most recent two minor
versions will be supported.

| Version | Supported          |
| ------- | ------------------ |
| 0.8.x   | :white_check_mark: |
| < 0.8.0 | :x:                |

## Reporting a vulnerability

**Do not open a public GitHub issue for a suspected vulnerability.**

Please report security issues privately by either:

- Using GitHub's **[Report a vulnerability](https://github.com/sapdev-ai/sap-dev/security/advisories/new)**
  form (preferred — produces a private security advisory we can collaborate on),
  or
- Emailing **<hello@sapdev.ai>** with the subject line `SECURITY: <short summary>`.

Please include:

- A description of the issue and the impact you believe it has.
- Steps to reproduce, ideally with a minimal proof-of-concept.
- The plugin / skill / file path involved.
- The version of `sap-dev`, SAP GUI, SAP NCo, and Windows you tested against.
- Any logs, screenshots, or VBS / PowerShell output that demonstrate the issue.

We aim to:

- Acknowledge receipt within **3 business days**.
- Provide an initial assessment (severity + planned remediation timeline)
  within **10 business days**.
- Coordinate public disclosure with you once a fix is available, typically
  via a GitHub Security Advisory and a patch release.

## Scope

In scope:

- Code in this repository (skills, shared scripts, schemas, tooling).
- Vulnerabilities in how the toolkit handles SAP credentials, transport
  requests, or generated ABAP source.
- Issues in published GitHub Releases or marketplace catalogs.

Out of scope (please report to the upstream vendor):

- Vulnerabilities in **SAP GUI for Windows**, **SAP NetWeaver / S/4HANA**,
  **SAP .NET Connector (NCo)**, or other SAP-supplied components.
- Vulnerabilities in third-party tools we orchestrate (Claude Code CLI,
  PowerShell, Node.js, Astro, Tailwind, etc.).
- Findings that require physical access to a developer workstation already
  controlled by the attacker.

## Safe-harbour

Good-faith security research that follows this policy will not be pursued
under the project's GPL-3.0 license terms or otherwise. Please give us a
reasonable window to remediate before public disclosure.
