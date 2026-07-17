# sap-user-guide

**End-user training guides + UAT scripts from recorded transaction walkthroughs** —
the unfunded rollout mandate everyone hand-makes from screenshots pasted into Word,
composed instead from ground truth the suite already owns: `/sap-gui-probe` records
the transaction step by step with full screen identity, DDIC carries the authoritative
field labels and F1 documentation, and the `docx` skill renders Word.

```
/sap-user-guide guide <probe-run-folder | "TXN: scenario"> [--with-screens] [--lang EN|JA|ZH]
                [--docx] [--uat] [--no-writes] [--output <dir>]
/sap-user-guide pack <pack.tsv> [--lang ..] [--docx]
```

## What it does

- **guide** — harvests a `/sap-gui-probe` run folder (`steps.tsv` + the (table,field)
  tokens from the findById paths), resolves DDIC labels + F1 long docs over RFC
  (TSTCT / DDIF_FIELDINFO_GET / DOCU_GET — the CLUSTER-safe path, no RFC_READ_TABLE
  on DOKTL, which is CLUSTER on ECC 6), then composes a business-language step-by-step
  guide in Markdown (`--docx` for Word) in the target language. Claude writes the step
  prose over the assembled skeleton. Given `"TXN: scenario"` with no folder, it
  delegates a fresh `/sap-gui-probe drive` first.
- **--with-screens** — replays the recorded actions one at a time on the live GUI to
  capture a per-step screenshot (`/sap-gui-inspect`). Each replayed action is verified
  live-vs-recorded (program, dynpro); divergence stops with `REPLAY_DIVERGED`, keeping
  partial captures — never a wrong-screen action.
- **--uat** — the same assets double as a UAT script with per-step expected-result +
  sign-off columns.
- **pack** — batches guides into a curriculum (`curriculum.md`: TOC, exercises,
  test-data prerequisites mapped to `/sap-bp` / `/sap-mm01` / `/sap-va01` as
  SUGGESTIONS, never auto-invoked).
- Outputs land in `{OUT}` = `Get-SapArtifactDir -ScopeKey TCODE_<TXN>` and are
  registered (`guide` / `uat_script` / `curriculum`) for `/sap-evidence-pack`.

## Prerequisites

- A `/sap-gui-probe` run folder (or a scenario to drive fresh)
- Active SAP GUI session via `/sap-login` — only for `--with-screens`
- SAP NCo 3.1 (32-bit) for the DDIC text/F1 resolution
- No new Z objects

## Reference files

| File | Purpose |
|---|---|
| `references/sap_guide_compose.ps1` | Parse probe folder + assemble guide skeleton (`-Action harvest\|compose`, local) |
| `references/sap_guide_ddic_texts.ps1` | DDIC labels + F1 docs over RFC |
| `references/sap_guide_replay.vbs` | Single-action replay + screen-identity verify (32-bit cscript) |
| `references/sap_guide_replay.screens.json` | Golden-screen baseline (generic deps) |

## Safety & limitations (v1)

- **Read-only except `--with-screens`**, which EXECUTES the transaction and is
  confirm-gated with every recorded write action enumerated (typed `<SID>` off DEV).
  `--no-writes` truncates the replay before the first write instead of gating.
- Honesty invariants: a field whose label/doc can't be fetched is COULD_NOT_CHECK,
  never dropped; replay divergence is REPLAY_DIVERGED with a partial-capture note,
  never a false-complete guide; the guide header records the SID/client/release it was
  produced on.
- Live-verified on S4D (S/4HANA 1909): DDIC-text engine (VA01 title, field labels,
  real F1 docs via DOCU_GET), harvest, and compose. The GUI replay leg was
  deliberately not run autonomously. ECC 6 shares the identical RFC path.
- Deferred: full `--uat` expected-result engine and wrapper-based full-dynpro field
  inventory (v1.5); `pack --create-data` invoking the tcd skills (v2).
