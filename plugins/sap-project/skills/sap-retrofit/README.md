# sap-retrofit

**Retrofit maintenance-line fixes into the project line without Solution Manager ChaRM.**
Dual-track landscapes must re-apply every production fix into the project line; without ChaRM
that tracking rots in a spreadsheet and same-object conflicts surface late, as silently
overwritten fixes during go-live regression. This turns the detect/classify loop into a tracked,
evidence-based pipeline.

```
/sap-retrofit init --project <id> --maint <hint> [--since YYYYMMDD] [--packages Z*,Y*]
/sap-retrofit harvest        # read released maintenance TRs -> per-object ledger rows
/sap-retrofit classify       # diff + project-line evidence -> IN_SYNC / GREEN / YELLOW / RED
/sap-retrofit status [--report]
/sap-retrofit draft <OBJ>    # reviewable two-way diff + AI merge draft (never deploys)
/sap-retrofit apply --green-only   # confirm-gated deploy of the safe subset + re-compare verify
```

## What it does

- **harvest** (read-only) — reads released workbench/customizing TRs on the **maintenance** line
  (E070/E07T/E071 over RFC), expands to per-object rows, dedupes across TRs, advances a
  watermark. Optional package filter via a maintenance-side TADIR join.
- **classify** (read-only) — per object: diffs maint-vs-project via **/sap-compare**, then
  gathers **project-line change evidence** — VRSD versions since the baseline + E071
  workbench/customizing dev-TR hits — to label it `IN_SYNC` (already retrofitted), `GREEN`
  (project untouched → safe to auto-apply), `YELLOW` (project also changed → needs a merge), or
  `RED` (can't diff reliably).
- **draft** — for a YELLOW object, writes a two-way diff bundle + an AI merge draft + rationale.
  **Never deploys** (enforced by mode separation).
- **apply --green-only** — deploys the GREEN subset to the **project** line via /sap-se38 /
  /sap-se37 behind /sap-transport-request, confirm-gated, then re-runs /sap-compare to verify the
  object is now identical (`VERIFIED`) or fails loud (`VERIFY_FAILED`).

## Honest by construction (never a false GREEN)

- The **maintenance line is read-only forever**; `apply` refuses if the write target resolves to
  it.
- Evidence is tri-state per source: an unreadable source is `COULD_NOT_CHECK`, and **partial
  evidence caps at YELLOW** — never GREEN, so a fix is never silently overwritten. A support-
  package import is *not* counted as a project change (only K/W dev TRs are).
- The ledger state machine refuses `APPLIED` on any non-GREEN/APPROVED row; a post-deploy
  re-compare mismatch is `VERIFY_FAILED`.
- Visible coverage holes: ABAP **classes are RED in v1** (/sap-compare's class-source limit);
  **DDIC** GREEN objects are `GREEN_MANUAL` (excluded from auto-apply).

## Reads

`E070`/`E07T`/`E071` (TR harvest), `TADIR` (package filter + existence), `VRSD` (project
versions), `RPY_*` (apply source fetch) — all FMODE=R / TRANSP, identical on both releases;
either line may be ECC or S/4. Verified live on S/4HANA 1909 (S4D) and ECC 6 (EC2/ERP)
2026-07-11. The **SVRS three-way merge** (both FMs remote-enabled on both) is the v2 upgrade that
turns YELLOW attribution from suspicion into fact. Part of the sap-project plugin.
