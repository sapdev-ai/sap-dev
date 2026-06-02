# examples/ — standalone before/after pairs (optional)

Large or multi-file before/after remediation examples live here, named:

```
<pattern_id>_<NN>.before.abap
<pattern_id>_<NN>.after.abap
```

e.g. `MATDOC_STOCK_01.before.abap` / `MATDOC_STOCK_01.after.abap`.

**Prefer inline examples.** Short before/after snippets should stay in the
recipe (`recipes/<pattern_id>.md`, the *Before / After example* section). Use
this folder only when an example is too long to embed or needs several files,
and reference it from the recipe by relative path.

This folder is intentionally empty in the seed pack.
