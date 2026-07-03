# Dual maintenance & retrofit during a long S/4HANA conversion

**Pattern:** `DUAL_MAINTENANCE` · tier R4 (process/governance, not a code transform) · status ACTIVE

## The problem

A brownfield conversion runs for **months**. Meanwhile the business does not stop:
developers keep changing the **source** (ECC / current-dev) custom code the
campaign has already inventoried, analyzed, remediated on the sandbox, or even
signed off. When that happens, a "finished" object silently **drifts** — the
sandbox remediation no longer matches the live source, and at cutover you ship a
fix built against a stale version (regressions, lost changes, re-work).

This is not a code transform you apply once; it is a **discipline** you run for
the life of the campaign, plus a **detection** step.

## Detection (what this skill automates)

`/sap-cc-campaign` ships `references/sap_cc_drift_read.ps1`. It reads the source
system's `E070`/`E071` for transports that touched any **tracked** (in-scope)
object **after the campaign start date**, flags the ones whose campaign state is
already `REMEDIATED` / `VERIFIED` / `TRANSPORTED` as **RE-ANALYZE candidates**,
and reads `SMODILOG` for the count of modified SAP standard objects (your SPDD /
SPAU exposure). The dashboard's **Landscape drift** section surfaces it; the
`INFO: drift touched=… reanalyze=…` line carries the counts. Run it periodically
(weekly, and always before a cutover rehearsal).

## The discipline (freeze / branch / retrofit)

1. **Announce a scope freeze early.** Once an object is `SCOPED` into the
   campaign, changes to it on the source should go through a lightweight change
   board — not because change is forbidden, but so each change is *known* and can
   be retrofitted.
2. **Prefer a code freeze on remediated objects.** After an object reaches
   `VERIFIED` on the sandbox, further source changes are the expensive case. If a
   business-critical fix is unavoidable, log it against the campaign so drift
   detection expects it.
3. **Retrofit, don't re-do.** When drift is detected on a remediated object:
   - pull the new source (`/sap-se38|24|37` download or `Read-SapAbapSource`),
   - diff it against the campaign's `remediation\<obj>.before.abap`,
   - re-apply the S/4 remediation on top of the *new* source (re-run
     `/sap-cc-analyze` → `/sap-cc-triage` → `/sap-cc-remediate` on just that
     object; the ledger transitions it back through the pipeline),
   - re-verify (ATC + unit) and re-approve.
4. **Keep the two systems' change streams reconciled.** If you run parallel ECC
   and S/4 branches during a phased go-live, every ECC change lands as a retrofit
   task on the S/4 branch. Track them; do not batch them to the end.
5. **Cutover checklist.** Immediately before cutover, run the drift check one last
   time. `touched=0 reanalyze=0` on the tracked set is the green light; any
   `reanalyze` row must be retrofitted or explicitly waived by the business owner.

## Scope of the shipped support

- **In (Phase 1):** detection + reporting + this discipline. Read-only; it never
  changes source or sandbox.
- **Out (Phase 2, demand-gated):** automated retrofit (auto-diff + auto-replay of
  the remediation onto the new source). Today the retrofit in step 3 is operator-
  driven through the normal pipeline skills.

## Related

- `/sap-cc-analyze`, `/sap-cc-triage`, `/sap-cc-remediate` — the retrofit loop.
- SPDD/SPAU: `SMODILOG` count is advisory here; the actual adjustment happens in
  the SUM/upgrade SPDD/SPAU phase, not in this pack.
