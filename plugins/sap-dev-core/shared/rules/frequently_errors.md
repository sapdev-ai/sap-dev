# frequently_errors — the recurring-mistake feedback loop

A team-shareable, curated catalog of recurring **FM / class-method / codegen
mistakes and their remedies**. It complements the FM/struct/authz *signature*
caches: signatures give the *shape* of a call, frequently_errors gives the
*traps* those signatures cannot express. The goal is fewer syntax/activation/
ATC errors on `sap-gen-abap` output by feeding hard-won lessons back in.

This is distinct from MEMORY files: it lives under `{custom_url}` so a team
shares one store (e.g. a shared drive or a checked-out git repo), and it is
keyed per object so deploy/ATC can append to it automatically.

## Three tiers (precedence: highest wins on conflict; union otherwise)

1. `{custom_url}\frequently_errors.tsv` — hand-authored team override (highest).
   A `STATUS=MUTE` row here suppresses a noisy lower-tier entry.
2. `{custom_url}\frequently_errors\<OBJECT>.tsv` — per-object store. The
   **auto-record target** (deploy + ATC) and the curation surface. `<OBJECT>`
   is the FM or class name, sanitized to `[A-Z0-9_]` (method goes in the
   `CONTEXT` column, not the filename). Unattributable errors land in
   `_UNATTRIBUTED.tsv`.
3. `plugins/sap-dev-core/shared/tables/frequently_errors.tsv` — plugin seed
   (lowest). Maintainer-curated baseline; ships with the plugin.

Merge key = `OBJECT_TYPE | OBJECT_NAME | CONTEXT | ERROR_CLASS` (upper-cased).

## Schema

Core columns (tiers 1 + 3): `OBJECT_TYPE  OBJECT_NAME  CONTEXT  ERROR_CLASS
RELEASE  WRONG_PATTERN  CORRECT_PATTERN  SEVERITY  RULE_REF  STATUS  NOTE`.

The per-object tier-2 file appends audit columns set by the recorder:
`SOURCE  OCCURRENCES  FIRST_SEEN  LAST_SEEN  EXAMPLE`. Readers are
header-aware (map by column name), so a file may carry any subset/superset.

- `OBJECT_TYPE` — `FM | METHOD | BAPI | STMT | AUTHZ` (`STMT` = a general
  statement-level rule, `OBJECT_NAME=*`).
- `RELEASE` — `ALL` or a SAP_BASIS release (e.g. `7.52`) the trap applies to.
- `CORRECT_PATTERN` — the **load-bearing field**: the remedy to emit. An entry
  with no remedy teaches the generator nothing.
- `STATUS` — `CONFIRMED` (injected into generation) | `CANDIDATE` (recorded,
  awaiting human review — NOT injected by default) | `MUTE` (never injected).
- `RULE_REF` — cross-ref to `abap_code_quality_rules.md` (e.g. `section 24`),
  keeping the prose rationale and the machine-readable data in sync.

## Read path (sap-gen-abap Step 1.5f)

OFFLINE merge of the 3 tiers for the FMs / class methods / auth objects the
spec references, filtered to injectable statuses (`frequently_errors_inject_status`,
default `CONFIRMED`), written to `{work_folder}\_error_hints.txt` and injected
into Step 2. `WRONG_PATTERN` is forbidden output; `CORRECT_PATTERN` is emitted.

## Write path (deploy + ATC, best-effort, CANDIDATE)

- `sap-se38` / `sap-se37` / `sap-se24` on a syntax/activation failure record
  the captured error lines (`-Action record -Source SE## -RawOutputFile`).
- `sap-atc` records FM/METHOD-attributable findings from the Stage-4b
  `.findings.tsv` (`-Action record -Source ATC -FindingsFile`).

Attribution is **locale-independent**: the deploy error's source line number
maps to the enclosing `CALL FUNCTION '<FM>'` / method call; ATC findings are
matched by a known-object token in the finding text. New rows land as
`CANDIDATE` — they do NOT influence generation until promoted.

Auto-record never changes a deploy/ATC verdict. Master switches:
`frequently_errors_enabled`, `frequently_errors_autorecord`.

## Curation (/sap-error-kb)

`list` the candidates, fill in each `CORRECT_PATTERN` (Edit the per-object
file), then `promote` to `CONFIRMED` (or `mute` the noise). Only `CONFIRMED`
rows reach generation by default.

## Authoring TSVs

Real TAB separators (the Write tool injects a literal `\t` — author/edit with
care or via PowerShell `` `t ``), UTF-8 **without BOM**, `#` comment lines and
blank lines skipped, header row first. PowerShell helper scripts stay ASCII.
