# sap-api-advisor

Natural-language **SAP API discovery** over RFC (no GUI). Turn a goal into a
ranked, trap-annotated, paste-ready shortlist of BAPIs / function modules /
classes — with released state (S/4), interface + docs for the top hits, the
team's known traps inlined, and a `CALL FUNCTION` snippet.

```
/sap-api-advisor discover "create a sales order" [--top=10] [--details=3] [--type=fm|bapi|class|any]
```

Also (later phases): `successor <NAME>` (released → sanctioned replacement) is
phase 2; `scan <OBJECT>` (clean-core worklist over an object's API calls) is
phase 3.

## What it reads

- **BAPI catalog** — `BAPI_MONITOR_GETLIST` (`ABAPNAME` = the FM, `BAPI_TEXT`/`BO_TEXT`,
  `OBSOLETE`, component) — the richest source, leads the harvest.
- **FM name + text** — `TFDIR` (name LIKE + `FMODE`) and `TFTIT` (DB-side text LIKE).
- **Classes** — `SEOCLASS` / `SEOCLASSTX`.
- **Released state (S/4)** — `ARS_W_API_STATE` (`RELEASE_STATE`, `SUCCESSOR_*`);
  absent on ECC → rendered `NOT_APPLICABLE`.
- **Detail** — `FUPARAREF` / `FUNCT` parameter texts + `DOCU_GET` documentation.

## Two hard rules

- **Never smoke-calls a candidate** — not even a "read-only" one. The deliverable
  is metadata + docs + a **text** snippet, never an executed FM.
- **Never invents an API name** — zero matches is `NO_MATCH`, honestly.

## Search tip

The skill derives SAP **abbreviation** keywords automatically (goods movement →
`goodsmvt`, sales order → `salesorder`/`vbak`). This is what makes it work on
non-English systems, where SAP short texts are localized and the **name** carries
the match. If a search comes up short, add the object's table/abbreviation to the
goal.

Read-only; deploys nothing; no dev-init, no GUI. Verified live on S/4HANA 1909
(S4D) and ECC 6 (EC2/ERP) — one code path, released-state column the only divergence.
