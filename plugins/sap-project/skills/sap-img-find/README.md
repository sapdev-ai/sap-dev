# sap-img-find

**Finds WHERE in SPRO/IMG a setting lives, semantically** — the thing SAP's literal IMG
search can't do. Ask *"where do I set the tolerance for invoice price differences?"* and
get top-N IMG activities, each with its full SPRO breadcrumb path. Read-only over RFC
(zero SAP writes, no wrapper FM, no dev-init).

```
/sap-img-find "<natural-language question>" [--top N] [--launch] [--refresh]
/sap-img-find harvest [--refresh]
/sap-img-find show <ACTIVITY>
/sap-img-find launch <ACTIVITY>
```

## What it does

- **harvest** (one-time, auto-run when the cache is missing) dumps the IMG activity index
  over `RFC_READ_TABLE` — TNODEIMGT node labels, TNODEIMG hierarchy, TNODEIMGR
  node→activity refs, CUS_IMGACH activity→tcode, CUS_ACTOBJ→maintenance objects — into a
  per-system local cache (`{img_cache_dir}\<SID>_<client>\img_index.tsv` + `meta.json`),
  reconstructing each node's **full SPRO path locally** from the parent chain. 30-day TTL
  with an `IMG_CACHE_STALE` warning; `--refresh` re-harvests.
- **find** expands the question into SAP-vocabulary keywords, runs a cheap lexical
  prefilter over the cache (**the full index never enters context** — only a ≤200-row
  shortlist), then Claude semantically ranks it into top-N hits (default 5, cap 20), each
  showing the full SPRO path + maintenance objects + a one-line rationale — a wrong hit
  costs one glance, not an hour.
- **show** prints one activity's dossier (all SPRO paths, tcode, maintenance objects).
- **launch** navigates the live GUI session to the activity **behind a confirm gate** — it
  only NAVIGATES, never Saves. The generated-tcode path drives `/n<tcode>` and verifies
  arrival; the **SM30/SM34 fallback VBS is not yet shipped** (to-be-recorded): it emits
  `NEEDS_RECORDING` and points at `/sap-gui-probe --record`. No target at all → the manual
  SPRO path is printed (`IMG_LAUNCH_NO_TARGET`, informational).

## Honest by construction

A core harvest table reading 0 rows → `IMG_HARVEST_INCOMPLETE`, never a silently thin
index. A missing expected column fails loud (`IMG_LAYOUT_UNKNOWN`) — the harvest is never
guessed. Ranking has no ground truth, so every hit carries its full path for cheap
discard, and a nonsense query returns honest low-confidence output, never fabricated hits.

## Reads

`TNODEIMGT` / `TNODEIMG` / `TNODEIMGR` / `CUS_IMGACH` / `CUS_ACTOBJ` — all TRANSP,
FMODE=R; single code path ECC 6 + S/4 (24/24 objects probed identical). Backends:
`references/sap_img_harvest.ps1` (harvest) + `references/sap_img_query.ps1` (prefilter).

Pure read-only; a GUI session is needed only for `launch`. Engine live-verified on
S/4HANA 1909 (S4D): the full harvest indexed **11,907 activities with correct deep SPRO
breadcrumbs**. v1 surfaces each hit's path + maintenance object; the generated-tcode
enrichment is deferred to v1.5 (TNODEIMGR.REF_OBJECT does not join cleanly to
CUS_IMGACH). v1.5 also brings the SM30/SM34 launch recording and `--against` cross-system
presence; v2 adds project/add-on IMG structures and S/4 Fiori-relocated (SSCUI) flags.
