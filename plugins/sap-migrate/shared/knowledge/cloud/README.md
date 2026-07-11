# Cloud-Readiness Knowledge Pack

Consumed by **`/sap-cc-cloud-readiness scan`** (sap-migrate). It is the versioned,
overrideable ruleset the offline scanner matches downloaded ABAP source against to
place each object on the **ABAP Cloud distance ladder** — `TIER_1_READY` /
`TIER_2_WRAPPABLE` / `TIER_3_CLASSIC`. Sibling of the Simplification Knowledge Pack
(`../` — `catalog.tsv` etc.), which answers a *different* question (does the code
survive the S/4 conversion), not *how far from clean core* it is.

## Files

| File | Shape | Role |
|---|---|---|
| `forbidden_statements.tsv` | `rule_id · pattern · tier_impact · category · note` | Statement-level regexes matched after comment/literal stripping + statement joining. A hit is a `FORBIDDEN_STMT` blocker. `pattern` is a .NET regex applied case-insensitively to a whitespace-normalised statement (keyword-anchored with `^`). |
| `cloudification_repository.json` | `{ entries: { "<KIND>:<NAME>": {state, successor} } }` | Per-object cloud-release signal for the APIs the scanner extracts (`FUNCTION`/`CLASS`/`TABLE`). `state` ∈ `released` \| `not_released`. |
| `kp_meta.json` | `{ kp_version, snapshot_date, stale_after_days, … }` | Pack version + snapshot date. `scan` emits `KP: STALE age_days=<n>` (WARN) when `snapshot_date` is older than `stale_after_days`. |

## How the scanner uses it (honesty contract)

- A **forbidden-statement** hit is high-confidence → `TIER_3_CLASSIC`.
- An extracted API reference is looked up as `<KIND>:<NAME>`:
  - `state=released` → not a blocker.
  - `state=not_released` **with** a `successor` → `TIER_2_WRAPPABLE` blocker (`UNRELEASED_API`).
  - `state=not_released` **without** a successor → `TIER_3_CLASSIC` blocker.
  - **absent from the map → `unknown`**: counted in `api_refs_total`, **never a blocker**.
- Because unknowns never block, a **partial** pack cannot manufacture a false
  `TIER_3`. The cost is disclosed the other way: an object with zero known blockers
  but ≥1 unknown API ref is `TIER_1_READY` with **`coverage=PARTIAL`** (never a clean
  `FULL`), and the AI summary surfaces it. A regex scanner is also blind to dynamic
  calls (`CALL FUNCTION <var>`, dynamic `CREATE OBJECT`, `SELECT … FROM (var)`) — any
  such token sets `dynamic_blindspot=YES` on the object, disclosed per row.

## Override + update

Customer overrides win **file-by-file** (same precedence as the Simplification pack):

```
{custom_url}\knowledge\cloud\<file>   →   this shipped pack
```

Drop a fuller `cloudification_repository.json` (a full export of SAP's public
cloudification repository) or an extended `forbidden_statements.tsv` under
`{custom_url}\knowledge\cloud\` and it replaces the shipped file for that one name;
the others fall back here. The skill itself **never** fetches from the network — the
update path is an operator dropping a refreshed snapshot into the override dir and
bumping `kp_meta.json`'s `snapshot_date`.

The shipped `cloudification_repository.json` is a **curated partial seed** — enough
to exercise the engine end-to-end and catch the best-known offenders, not a
certification-grade list. Ship a full export before treating tiers as authoritative.
