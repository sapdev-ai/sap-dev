"""Offline spec sanity check — Step 2a.5 of the abap-developer agent.

Runs the eight checks defined in the agent body. Returns exit 0 if all
checks pass (or only WARN), 1 if any STOP-level check fails. Prints a
table of results for the agent's transcript.

Usage:
  python tools/sanity_check_spec.py <work_folder>
"""
import sys
import io
from pathlib import Path
from collections import Counter

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

if len(sys.argv) < 2:
    raise SystemExit("usage: sanity_check_spec.py <work_folder>")

WORK = Path(sys.argv[1]).resolve()
if not WORK.exists() or not WORK.is_dir():
    raise SystemExit(f"not a directory: {WORK}")

# Find {doc_name} from the _raw.txt file
raw = next(WORK.glob("*_raw.txt"), None)
if not raw:
    raise SystemExit(f"no *_raw.txt in {WORK}")
DOC = raw.name[:-len("_raw.txt")]

def f(suffix):
    p = WORK / f"{DOC}{suffix}"
    return p if p.exists() else None

def read_kv(path):
    """Read FIELD\\tVALUE pairs into a dict."""
    out = {}
    if not path:
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        if "\t" in line:
            k, v = line.split("\t", 1)
            out[k.strip()] = v.strip()
    return out

def read_tsv(path):
    """Read header + data rows. Returns (headers, rows-as-dicts)."""
    if not path:
        return [], []
    lines = [ln for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
    if not lines:
        return [], []
    headers = lines[0].split("\t")
    rows = []
    for ln in lines[1:]:
        cells = ln.split("\t")
        # Skip section markers like "== INPUTS ==" or empty header repeats
        if cells[0].startswith("==") or cells == headers:
            continue
        row = {h: (cells[i] if i < len(cells) else "") for i, h in enumerate(headers)}
        rows.append(row)
    return headers, rows

results = []  # list of (severity, check, message)

def add(severity, check, msg):
    results.append((severity, check, msg))


# === Check 1: Program ID present and Z*/Y* namespace ===
pgm = read_kv(f("_PGM_summary.txt"))
# Try both EN and JA keys
program_id = (pgm.get("Program ID") or pgm.get("プログラム ID") or "").strip()
if not program_id:
    add("STOP", "program_id_present", "no Program ID in _PGM_summary.txt")
elif not (program_id.upper().startswith("Z") or program_id.upper().startswith("Y")):
    add("STOP", "program_id_namespace", f"Program ID {program_id!r} not in Z*/Y* namespace")
else:
    add("OK", "program_id", f"Program ID = {program_id}")


# === Check 2: Determine PROG_TYPE ===
ptype_raw = (pgm.get("Program type") or pgm.get("プログラム種別") or "").strip()
# Examples: "1 : Executable Report" / "1 : 実行可能プログラム" / "M" / "F" / "K"
if ptype_raw.startswith("1") or "executable" in ptype_raw.lower() or "実行" in ptype_raw:
    prog_type = "Report"
elif ptype_raw.startswith("M") or "module pool" in ptype_raw.lower():
    prog_type = "ModulePool"
elif ptype_raw.startswith("F") or "function" in ptype_raw.lower() or "ファンクション" in ptype_raw:
    prog_type = "FunctionGroup"
elif ptype_raw.startswith("K") or "class" in ptype_raw.lower() or "クラス" in ptype_raw:
    prog_type = "Class"
elif ptype_raw.startswith("I") or "include" in ptype_raw.lower():
    prog_type = "Include"
else:
    prog_type = "Unknown"
add("OK", "prog_type", f"PROG_TYPE = {prog_type} (from {ptype_raw!r})")


# === Check 3: FM/Class needs Interface Contract ===
iface_path = f("_interface.txt")
if prog_type in ("FunctionGroup", "Class"):
    if not iface_path:
        add("STOP", "interface_required", f"{prog_type} needs Interface Contract; _interface.txt missing")
    else:
        # Count rows excluding section markers and headers
        text = iface_path.read_text(encoding="utf-8")
        data_rows = [
            ln for ln in text.splitlines()
            if ln.strip() and not ln.startswith("==") and "\t" in ln
            and not ln.startswith("NAME\t") and not ln.startswith("MSG_CLASS\t")
        ]
        if not data_rows:
            add("STOP", "interface_has_rows", f"{prog_type} needs Interface Contract rows; _interface.txt has none")
        else:
            add("OK", "interface_has_rows", f"_interface.txt has {len(data_rows)} data row(s)")
else:
    add("SKIP", "interface_required", f"PROG_TYPE={prog_type} — Interface Contract optional")


# === Check 4: Report needs Selection Definition ===
seldef_path = f("_selection_definition.txt")
seldef_headers, seldef_rows = read_tsv(seldef_path)
if prog_type == "Report":
    if not seldef_rows:
        add("STOP", "seldef_required", "Report needs Selection Definition; _selection_definition.txt has no rows")
    else:
        add("OK", "seldef_required", f"Selection Definition has {len(seldef_rows)} row(s)")
else:
    add("SKIP", "seldef_required", f"PROG_TYPE={prog_type} — Selection Definition optional")


# === Check 5: Every Selection Definition row has NAME_EN ===
if seldef_rows:
    missing = [r for r in seldef_rows if not r.get("NAME_EN", "").strip()]
    if missing:
        names_ja = ", ".join(r.get("NAME_JA", "?")[:20] for r in missing[:5])
        add("WARN", "seldef_name_en", f"{len(missing)}/{len(seldef_rows)} Selection Definition rows have blank NAME_EN ({names_ja}...). Agent will derive ASCII identifier from NAME_JA")


# === Check 6: TSV NO/No. columns have unique values ===
for tsv_name, label in [
    ("_selection_definition.txt", "Selection Definition"),
    ("_file_mapping_in.txt", "File Mapping (In)"),
    ("_file_mapping_out.txt", "File Mapping (Out)"),
]:
    headers, rows = read_tsv(f(tsv_name))
    no_col = next((h for h in headers if h.upper() in ("NO", "NO.")), None)
    if not no_col or not rows:
        continue
    nos = [r[no_col].strip() for r in rows if r[no_col].strip()]
    counts = Counter(nos)
    dups = {k: v for k, v in counts.items() if v > 1}
    if dups:
        add("WARN", f"unique_no_{tsv_name}", f"{label}: duplicate {no_col!r} values: {dups}")


# === Check 7: MODE_UNIT_TESTS=TRUE requires golden tests ===
# For this agent run, we proceed with defaults (MODE_UNIT_TESTS=False default).
# But still check for emptiness as info.
golden_headers, golden_rows = read_tsv(f("_golden.txt"))
if not golden_rows:
    add("WARN", "golden_tests", "_golden.txt has no rows — generated unit tests (if requested) will be skeleton-only")
else:
    add("OK", "golden_tests", f"_golden.txt has {len(golden_rows)} test scenario(s)")


# === Check 8: All DDIC names match Z*/Y* namespace ===
def check_namespace(path, name_col, label):
    headers, rows = read_tsv(path)
    bad = []
    for r in rows:
        nm = r.get(name_col, "").strip().upper()
        if nm and not (nm.startswith("Z") or nm.startswith("Y")):
            bad.append(nm)
    if bad:
        add("STOP", f"namespace_{label}", f"{label}: non-customer-namespace name(s): {bad}")

check_namespace(f("_domains.txt"), "DOMAIN_NAME", "domain")
check_namespace(f("_dataElements.txt"), "DTEL_NAME", "data_element")
# Tables: only check table-metadata block (first block); the FIELDS block has SAP-standard data elements as values which is fine.
tbl_path = f("_tables.txt")
if tbl_path:
    text = tbl_path.read_text(encoding="utf-8")
    blocks = text.split("\n\n")
    if blocks:
        first_block = blocks[0]
        lines = [ln for ln in first_block.splitlines() if ln.strip()]
        if lines and "TABLE_NAME" in lines[0]:
            for ln in lines[1:]:
                tname = ln.split("\t")[0].strip().upper()
                if tname and not (tname.startswith("Z") or tname.startswith("Y")):
                    add("STOP", "namespace_table", f"table {tname!r} not in Z*/Y* namespace")


# === Print results ===
sev_color = {"OK": " ", "WARN": "?", "STOP": "!", "SKIP": "-"}
print()
print(f"=== Spec Sanity Check — {WORK.name} ===")
print(f"{'Severity':9s}  {'Check':32s}  Message")
print("-" * 100)
for sev, check, msg in results:
    print(f"  [{sev_color[sev]}] {sev:5s}  {check:32s}  {msg}")
print()
n_stop = sum(1 for s, _, _ in results if s == "STOP")
n_warn = sum(1 for s, _, _ in results if s == "WARN")
n_ok = sum(1 for s, _, _ in results if s == "OK")
print(f"Summary: {n_ok} OK, {n_warn} WARN, {n_stop} STOP")
sys.exit(1 if n_stop else 0)
