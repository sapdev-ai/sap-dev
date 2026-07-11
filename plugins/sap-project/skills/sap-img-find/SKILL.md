---
name: sap-img-find
description: |
  Finds WHERE in SPRO/IMG a setting lives, semantically — the thing SAP's literal IMG search
  can't do. A one-time RFC harvest dumps the IMG activity index (TNODEIMGT node labels, TNODEIMG
  hierarchy, TNODEIMGR node->activity refs, CUS_IMGACH activity->tcode, CUS_ACTOBJ->maintenance
  objects) into a per-system local cache, reconstructing each node's full SPRO path locally from
  the parent chain. find expands a natural-language question ("where do I set the tolerance for
  invoice price differences?") into SAP-vocabulary keywords, runs a cheap lexical prefilter over
  the cache (the full index never enters context — only a <=200-row shortlist), then Claude
  semantically ranks it into top-N hits, each showing the full SPRO path + generated tcode +
  maintenance objects so a wrong hit costs one glance, not an hour. show prints one activity's
  dossier; launch navigates the live GUI session to the activity (generated tcode, else SM30/SM34
  Display on its maintenance object, else prints the manual path) behind a confirm gate — it only
  NAVIGATES, never Saves. Pure RFC_READ_TABLE (all TRANSP, FMODE=R), local path reconstruction ->
  zero SAP writes, no wrapper FM, no dev-init, single code path ECC6 + S/4 (24/24 objects
  identical). Prerequisites: pinned /sap-login RFC profile; NCo 3.1 (32-bit); a GUI session only
  for launch.
argument-hint: "\"<natural-language question>\" [--top N] [--launch] [--refresh] | harvest [--refresh] | show <ACTIVITY> | launch <ACTIVITY>"
---

# SAP IMG Find Skill

You answer "where in SPRO do I configure X?" semantically: harvest the IMG index once, then
prefilter + rank against the question, always showing the full path + tcode so a wrong hit is
cheap. `launch` only navigates (never saves) behind a confirm gate.

Task: $ARGUMENTS

---

## Shared Resources

| File | Token / call | Purpose |
|---|---|---|
| `<SKILL_DIR>/references/sap_img_harvest.ps1` | `-CacheDir -Profile` | One-time RFC harvest -> per-system cache (`img_index.tsv` + `meta.json`) |
| `<SKILL_DIR>/references/sap_img_query.ps1` | `-CacheDir -Keywords -OutFile` | Lexical prefilter -> shortlist (full index never enters context) |
| `<SAP_DEV_CORE_SHARED_DIR>/scripts/sap_rfc_lib.ps1` · `sap_connection_lib.ps1` · `sap_settings_lib.ps1` | dot-source | RFC connect + `img_cache_dir` setting |
| `/sap-login` · `/sap-config-compare` | sub-skills | Session/profile / (v2) compare an activity's tables cross-system |

---

## Step 0 — Directories + Logging

Resolve `work_dir` + `{RUN_TEMP}` (canonical one-liner). Resolve `img_cache_dir` (default
`{work_dir}\cache\img_index`) via `sap_settings_lib.ps1`; the per-system cache is
`{img_cache_dir}\<SID>_<client>\`. Start logging (`sap_log_helper.ps1`).

## Step 1 — Parse & Dispatch

`"<question>"` (find, default) | `harvest` | `show <ACTIVITY>` | `launch <ACTIVITY>`. Pinned RFC
profile via `/sap-login`.

## Step 2 — Cache Gate

Cache missing -> auto-run harvest (tell the user: one-time, a couple minutes). `meta.json` older
than the TTL (30 days) -> WARN `IMG_CACHE_STALE`, proceed, suggest `--refresh`. `--refresh` ->
harvest first.

## Step 3 — harvest

```bash
... sap_img_harvest.ps1 -CacheDir "<cache>" -Profile <hint>
```

`IMGH:` per-table row counts + `IMGH: INDEX activities=.. index_rows=..`. A core table reading 0
rows -> `IMG_HARVEST_INCOMPLETE` (never a silently thin index). Writes `img_index.tsv` (activity /
tcode / node_text / spro_path / objects) + `meta.json`.

## Step 4 — find

1. **You** expand the question into 5-15 SAP-vocabulary keywords/synonyms (e.g. "plant" -> plant,
   WERKS, site, factory) BEFORE touching the cache.
2. `sap_img_query.ps1 -Keywords "<list>" -OutFile "{RUN_TEMP}\img_shortlist.tsv"` -> the shortlist.
3. **You** semantically rank the shortlist against the ORIGINAL question -> top-N (default 5, cap
   20), each with the full SPRO path + tcode + objects + a one-line rationale. Never emit a hit
   without its path. A nonsense query -> say low-confidence honestly, never fabricate hits.

## Step 5 — show

Print one activity's dossier from the cache (all SPRO paths, tcode, maintenance objects).
`IMG_ACTIVITY_NOT_FOUND` if absent.

## Step 6 — launch (confirm-gated GUI)

Resolve target: generated `TCODE` from the index (priority 1) -> `/n<tcode>`; else a maintenance
object -> SM30/SM34 in **Display**; else print the manual SPRO path (`IMG_LAUNCH_NO_TARGET`, INFO).
**CONFIRM gate:** "Open IMG activity `<ID>` (`<text>`) via `<tcode|SM30 obj>` on `<SID>/<client>`?
The skill only NAVIGATES, never saves. (yes/no)". The tcode path drives `/n<tcode>` and verifies
arrival via `session.Info.Transaction`; the SM30/SM34 fallback VBS ships `NEEDS_RECORDING` (record
once via `/sap-gui-probe --record`). On no -> `SKIPPED`.

## Step 7 — Register

`Register-SapArtifact` (scope `SYSTEM_<SID>_<client>`; kind `img_find_result` for a find,
`img_index` for a harvest; coverage CHECKED, or COULD_NOT_CHECK when the cache is stale/incomplete
and the user proceeded) for `/sap-evidence-pack`.

## Final — Log End

Log end (`SUCCESS`/`FAILED`/`SKIPPED` + error_class). Error classes: `IMG_LAYOUT_UNKNOWN`,
`IMG_HARVEST_INCOMPLETE`, `IMG_CACHE_STALE` (WARN), `IMG_ACTIVITY_NOT_FOUND`, `IMG_LAUNCH_NO_TARGET`
(INFO), `IMG_LAUNCH_FAILED`; reused `RFC_LOGON_FAILED` / `GUI_TIMEOUT`.

---

## Scope & Limitations (v1)

- **Engine live-verified on S4D (S/4HANA 1909) 2026-07-11:** the harvest (node-text dump +
  local SPRO-path reconstruction from the TNODEIMG parent chain + node->activity->tcode/object
  join) and the find pipeline (lexical prefilter -> scored shortlist) were verified on a bounded
  harvest — e.g. find "tax/tolerance/payment/currency/exchange" returned "Create Bill of Exchange
  Payable" with the reconstructed path "Bill of Exchange Payable > Create Bill of Exchange Payable".
  The searchable SPRO label is the **node** text (TNODEIMGT), not CUS_IMGACT (generic "Notes on
  Implementation" docs) — a build-time finding. TNODEIMGR references are REF_TYPE='COBJ' whose
  REF_OBJECT is either an IMG activity (-> CUS_IMGACH generated tcode) or a maintenance view/table
  directly (-> SM30 target) — both resolved. A **full** harvest over a remote WAN link is minutes-
  slow (a one-time, cached, ~monthly-TTL cost; fast on a LAN system) — the full S4D harvest completed
  at **11,907 indexed activities with correct deep SPRO breadcrumbs** (e.g. "Contract Accounts
  Receivable and Payable > Basic Functions > Postings and Documents > Document > Tolerance Groups for
  Amount Limits"). Second build finding: TNODEIMGR.REF_OBJECT does not join cleanly to
  CUS_IMGACH.ACTIVITY (the generated-tcode column stays empty across the full harvest), so v1 surfaces
  each hit's SPRO path + the maintenance object (REF_OBJECT, launchable via SM30) and defers the
  generated-tcode enrichment to v1.5 — the node text + path (the search value) are complete.
  EC2 (ECC 6) was probed in-plan (24/24 objects identical, SPRO/SM30/SM34 same programs)
  but unreachable at build time; one code path, no variant.
- **The full index never enters context** — the harvest writes a local per-system cache; find only
  loads the <=200-row lexical shortlist, which Claude ranks. Ranking has no ground truth, so every
  hit shows its full SPRO path + tcode for cheap discard, and a nonsense query returns honest
  low-confidence output.
- **Pure read-only, no dev-init.** Path is reconstructed locally from the harvested parent chain
  (STREE_GET_PATH_TO_NODE is FMODE-blank and deliberately avoided so the skill needs no wrapper FM
  / runs on a bare customer QAS). launch only navigates — never Saves; SM30/SM34 opens in Display.
- **v1.5:** SM30/SM34 launch VBS live recording; `--against` cross-system presence (config-compare
  pattern); config-workbook paragraph output (DOKIL/DOKHL doc text). **v2:** project/add-on IMG
  structures (v1 scopes the SAP Reference IMG); S/4 Fiori-relocated (SSCUI) activities flagged.
- Release tolerance is at the field-introspection layer (meta.json records the discovered layout);
  a missing expected column fails loud `IMG_LAYOUT_UNKNOWN`, never a guessed harvest.
