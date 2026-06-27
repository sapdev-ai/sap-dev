# ABAP gate fixtures

Real generated-ABAP cases that gate CI through the two offline quality gates:

| Gate | Script | What it proves |
|---|---|---|
| Contract lint | `scripts/lint-abap-contract.mjs ... --fixture` | The generated code obeys the project's offline contract rules (no literal `MESSAGE`, no `TEXT-NNN` assignment, comma-`SELECT` host vars, etc.) **and** — under `--fixture` — every referenced FM / `AUTHORITY-CHECK` object / `TEXT-NNN` / message number has a concrete committed signature/sibling row (an incomplete RFC snapshot can no longer green-wash a run). |
| Skeleton diff | `scripts/diff-abap-skeleton.mjs ... --case` | The generated program still **covers** its spec: no dependency, traceability pair, message, selection field, or text symbol was silently dropped or re-mapped between generator changes. |

The two scripts each also ship a `--selftest` that gates their rule engine on
seeded snippets. These fixtures are the complementary half: they gate the gates
against **real artifacts**, so an actual generator regression fails CI. Both the
self-tests and these fixture steps run in `.github/workflows/validate.yml`.

## Layout

Each case is one directory: a "work folder" holding the generated `.abap` plus
the sibling/manifest files the generator emits next to it, and (for skeleton
cases) a `case.json` expected skeleton.

```
tests/fixtures/
  clean_ZMMRMAT099R01/            # passes BOTH gates (exit 0)
    ZMMRMAT099R01.abap
    ZMMRMAT099R01.messages.txt        NNN<TAB>TYPE<TAB>text
    ZMMRMAT099R01.text_elements.txt   [SELECTION_TEXTS] + [TEXT_SYMBOLS] blocks
    ZMMRMAT099R01.deps.txt            STANDARD_TABLES / BAPIS / AUTHZ_OBJECTS sections
    ZMMRMAT099R01.traceability.txt    [spec id] -> object->method (line N)
    _authz_signatures.txt             header + OBJCT<TAB>POSITION<TAB>FIELD
    _fm_signatures.txt                header + FM_NAME<TAB>SECTION<TAB>PARAM<TAB>...
    _selection_definition.txt         header + one row per selection field
    case.json                         expected skeleton (schema sapdev.skeleton/1)

  broken_lint_ZMMRMAT100R01/      # FAILS the contract lint (exit 1)
    ZMMRMAT100R01.abap                literal MESSAGE (LITERAL_MESSAGE) +
    _authz_signatures.txt             _fm_signatures.txt INTENTIONALLY ABSENT
                                      -> SNAPSHOT_INCOMPLETE under --fixture

  broken_skeleton_ZMMRMAT101R01/  # FAILS the skeleton diff (exit 1)
    ZMMRMAT101R01.abap                .abap is clean; the regression is in the
    ZMMRMAT101R01.deps.txt            manifest: MAKT dropped (dep miss) +
    ZMMRMAT101R01.traceability.txt    Validation #1 re-mapped (trace-pair miss)
    ZMMRMAT101R01.messages.txt        case.json still encodes the correct skeleton
    ZMMRMAT101R01.text_elements.txt
    case.json
```

### File-format notes (load-bearing)

- **Sibling `.txt` files are TAB-delimited.** The parsers split on real `\t`
  bytes (`messages.txt` matches `^\s*\d{1,3}\t`; the signature files split on
  `\t`). When adding/editing a case do **not** create these with an editor that
  inserts spaces, and do not let a literal `\t` two-char sequence land in the
  file (a known trap of the Write tool). Write them with real tab bytes, e.g.
  `printf '001\tE\ttext\n' > x.messages.txt`, then verify with `cat -A` (tabs
  show as `^I`).
- **`case.json`** is plain JSON (no tabs). Every section is optional — only what
  is present is asserted. `traceability.pairs` are matched on the stable tag id
  (text before the first `:` inside `[...]`, lowercased) plus the `object->method`
  target; line numbers in `.traceability.txt` are stripped, so they may drift
  freely from the `.abap`.
- **`--fixture`** (lint only) turns the otherwise-silent "no signature row →
  skip" into a hard `SNAPSHOT_INCOMPLETE` / `SIBLING_MISSING` error. Always pass
  it for fixture cases — that is the whole point of a fixture.

## Verify locally

From `sap-dev/`:

```bash
# clean -> exit 0 on both
node scripts/lint-abap-contract.mjs tests/fixtures/clean_ZMMRMAT099R01/ZMMRMAT099R01.abap \
  --work-folder tests/fixtures/clean_ZMMRMAT099R01 --fixture
node scripts/diff-abap-skeleton.mjs --work-folder tests/fixtures/clean_ZMMRMAT099R01 \
  --program ZMMRMAT099R01 --case tests/fixtures/clean_ZMMRMAT099R01/case.json

# broken -> exit 1 each, with the intended finding
node scripts/lint-abap-contract.mjs tests/fixtures/broken_lint_ZMMRMAT100R01/ZMMRMAT100R01.abap \
  --work-folder tests/fixtures/broken_lint_ZMMRMAT100R01 --fixture       # LITERAL_MESSAGE + SNAPSHOT_INCOMPLETE
node scripts/diff-abap-skeleton.mjs --work-folder tests/fixtures/broken_skeleton_ZMMRMAT101R01 \
  --program ZMMRMAT101R01 --case tests/fixtures/broken_skeleton_ZMMRMAT101R01/case.json   # dep + trace-pair miss
```

## Adding a case

1. Make a `tests/fixtures/<clean|broken_<gate>>_<PROGRAM>/` directory.
2. Drop the generated `<PROGRAM>.abap` plus the sibling files the gate(s) need
   (see the layout above; TAB-delimited, verify with `cat -A`).
3. For a skeleton case, add a `case.json` (`schema: "sapdev.skeleton/1"`) with
   the expected deps / traceability / messages / selection count / text symbols.
4. A **clean** case must exit 0 on the gate(s) it targets; a **broken** case must
   exit 1, and its finding should be the regression you intend to catch (quote it
   in a comment at the top of the `.abap`). Keep cases minimal.
5. Wire the new case into `.github/workflows/validate.yml` next to the existing
   fixture steps (clean cases as plain steps; broken cases must assert a non-zero
   exit so a future "fix" that stops them failing also fails CI).
