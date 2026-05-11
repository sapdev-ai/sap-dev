"""Retrofit SAP GUI Scripting VBS files with session-lock helpers.

Per language_independence_rules.md Rule 7. Idempotent — skips files that
already have `TryLockSession`.

For each entry in RETROFITS:
  1. Inserts the `%%SESSION_LOCK_VBS%%` include after the Const VKEY block.
  2. Inserts the lock block (Dim wasLocked + TryLockSession + INFO echo)
     immediately BEFORE the first regex anchor (the start of the write
     critical section).
  3. Inserts the release block (ReleaseSession + INFO echo) immediately
     BEFORE the second regex anchor (the start of the read-only verify /
     final-status section).
  4. Walks every `WScript.Quit` line between the lock and the release
     anchors and inserts `ReleaseSession oSession, wasLocked` just before
     each (preserving indentation).

Usage:
  python tools/migrate_session_lock.py            # retrofit all
  python tools/migrate_session_lock.py --dry-run  # show diff only
  python tools/migrate_session_lock.py <file>     # retrofit single file
"""
from pathlib import Path
import re
import sys


PLUGINS = Path(__file__).resolve().parent.parent / "plugins"

# Per-file retrofit boundaries. lock_anchor and release_anchor are regexes
# that match the line BEFORE which the new block is inserted.
RETROFITS = {
    # SE38 create — source paste pattern (identical to sap_se38_update.vbs which
    # was the worked example). Already retrofitted manually; entry left here so
    # the script can verify idempotency.
    "sap-dev-core/skills/sap-se38/references/sap_se38_create.vbs": {
        "lock_anchor": r"^' --- 6c\. Focus editor \(with foreground guard\)",
        "release_anchor": r"^' ------ 10\. Verify activation",
        "section_label": "paste + save + activate",
        "verify_label": "Step 10 is read-only verification",
    },
    "sap-dev-core/skills/sap-se38/references/sap_se38_update.vbs": {
        # Already retrofitted manually as the worked example.
        "lock_anchor": r"^' --- 4c\. Focus editor \(with foreground guard\)",
        "release_anchor": r"^' ------ 8\. Verify activation",
        "section_label": "paste + save + activate",
        "verify_label": "Step 8 is read-only verification",
    },

    # SE37 — FM source paste + activate
    "sap-dev-core/skills/sap-se37/references/sap_se37_create.vbs": {
        "lock_anchor": r"^' ------ 6\. Navigate to Source code tab and upload source",
        "release_anchor": r"^' ------ 11\. Final status check",
        "section_label": "source upload + save + activate + syntax check",
        "verify_label": "Step 11 is read-only status check",
    },
    "sap-dev-core/skills/sap-se37/references/sap_se37_update.vbs": {
        "lock_anchor": r"^' ------ 4\. Navigate to Source code tab and upload source",
        "release_anchor": r"^' ------ 8\. Final status check",
        "section_label": "source upload + save + activate + syntax check",
        "verify_label": "Step 8 is read-only status check",
    },

    # SE24 — class method source + activate
    "sap-dev-core/skills/sap-se24/references/sap_se24_create.vbs": {
        "lock_anchor": r"^' ------ 6\. Save \(Ctrl\+S / F11\)",
        "release_anchor": r"^' ------ 7\. Final status check",
        "section_label": "save",
        "verify_label": "Step 7 is read-only status check",
    },
    "sap-dev-core/skills/sap-se24/references/sap_se24_update.vbs": {
        "lock_anchor": r"^' ------ 6\. Upload source via menu Upload/Download",
        "release_anchor": r"^' ------ 10\. Final status check",
        "section_label": "source upload + save + activate + syntax check",
        "verify_label": "Step 10 is read-only status check",
    },

    # SE01 — TR creation/release. Uses non-standard step structure (no
    # `' ------ N.` headers); deferred for manual retrofit. See backlog.

    # SE21 — package create
    "sap-dev-core/skills/sap-se21/references/sap_se21_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^' ------ \d+\. (Read|Final|Verify)",
        "section_label": "package create + TR popup",
        "verify_label": "result read is read-only",
    },

    # SE38 attribute change — fill attribute fields + save
    "sap-dev-core/skills/sap-se38/references/sap_se38_change_attrs.vbs": {
        "lock_anchor": r"^' ------ 3\. Select Attributes radio",
        "release_anchor": r"^' ------ 6\. Read status bar",
        "section_label": "attribute change + save",
        "verify_label": "status bar read is read-only",
    },
    # SE37 attribute change — fill attribute fields + save
    "sap-dev-core/skills/sap-se37/references/sap_se37_change_attrs.vbs": {
        "lock_anchor": r"^' ------ 3\. Enter FM name and press Change",
        "release_anchor": r"^' ------ 6\. Read status bar",
        "section_label": "FM attribute change + save",
        "verify_label": "status bar read is read-only",
    },
    # SE37 reassign function group — write + activate
    "sap-dev-core/skills/sap-se37/references/sap_se37_reassign_fugr.vbs": {
        "lock_anchor": r"^' ------ 3\. Enter FM name on initial screen",
        "release_anchor": r"^' ------ 8\. Read final status bar",
        "section_label": "FM reassign + reactivate",
        "verify_label": "final status bar read is read-only",
    },
    # SE24 change props — fill properties + save
    "sap-dev-core/skills/sap-se24/references/sap_se24_change_props.vbs": {
        "lock_anchor": r"^' ------ 3\. Open the Properties dialog",
        "release_anchor": r"^' ------ 8\. Read status bar",
        "section_label": "class properties change + save",
        "verify_label": "status bar read is read-only",
    },

    # SE11 — DDIC create scripts. Each has a "Fill ... + Save + Activate" flow.
    # All use Step 3 as the first write step (after Steps 1 attach + 2 navigate)
    # and end with Steps for Save, Check, Activate, then Final/Verify.
    "sap-dev-core/skills/sap-se11/references/sap_se11_table_create.vbs": {
        "lock_anchor": r"^' ------ 3\. Fill table description",
        "release_anchor": r"^' ------ 11\. Final status",
        "section_label": "fill fields + save + technical settings + activate",
        "verify_label": "Step 11 is read-only final status",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_domain_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^' ------ \d+\. Final status",
        "section_label": "fill domain fields + save + activate",
        "verify_label": "final status is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_dataelement_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^' ------ \d+\. Final status",
        "section_label": "fill data element fields + save + activate",
        "verify_label": "final status is read-only",
    },
    # The remaining SE11 *_create files end with Activate as the last numbered
    # step; the read-only "final status" code begins with `Dim sFinalMsg`.
    "sap-dev-core/skills/sap-se11/references/sap_se11_structure_create.vbs": {
        "lock_anchor": r"^' ------ 4\. Fill description",
        "release_anchor": r"^Dim sFinalMsg",
        "section_label": "fill structure fields + save + activate",
        "verify_label": "final-status read is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_view_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^Dim sFinalMsg",
        "section_label": "fill view fields + save + activate",
        "verify_label": "final-status read is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_searchhelp_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^Dim sFinalMsg",
        "section_label": "fill search-help fields + save + activate",
        "verify_label": "final-status read is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_lockobject_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^Dim sFinalMsg",
        "section_label": "fill lock-object fields + save + activate",
        "verify_label": "final-status read is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_typegroup_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^Dim sFinalMsg",
        "section_label": "fill type-group source + save + activate",
        "verify_label": "final-status read is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_tabletype_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^Dim sFinalMsg",
        "section_label": "fill table-type fields + save + activate",
        "verify_label": "final-status read is read-only",
    },
    "sap-dev-core/skills/sap-se11/references/sap_se11_change_package.vbs": {
        "lock_anchor": r"^' ------ 3\. Select object type",
        "release_anchor": r"^' ------ 7\. Navigate back and report",
        "section_label": "package reassignment + save",
        "verify_label": "navigate-back + report is read-only",
    },

    # TCD — multi-tab business-process input. Release anchor: "Check result".
    "sap-tcd/skills/sap-bp/references/sap_bp_create.vbs": {
        "lock_anchor": r"^' ------ 3\. Navigate to BP and Create",
        "release_anchor": r"^' ------ \d+\. Check result",
        "section_label": "BP multi-tab input + save",
        "verify_label": "result check is read-only",
    },
    "sap-tcd/skills/sap-mm01/references/sap_mm01_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^' ------ \d+\. Check result",
        "section_label": "MM01 multi-view input + save",
        "verify_label": "result check is read-only",
    },
    "sap-tcd/skills/sap-va01/references/sap_va01_create.vbs": {
        "lock_anchor": r"^' ------ 3\.",
        "release_anchor": r"^' ------ \d+\. Check result",
        "section_label": "VA01 sales-order input + save",
        "verify_label": "result check is read-only",
    },
}


INCLUDE_BLOCK = """
' Include shared session-lock helpers (TryLockSession / ReleaseSession).
' Per language_independence_rules.md Rule 7.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%SESSION_LOCK_VBS%%", 1).ReadAll()
"""


def make_lock_block(section_label: str) -> str:
    return (
        f"' --- Lock the SAP session UI for the {section_label} critical section ---\n"
        f"' Defence in depth (Rule 7): AppActivate guards external focus stealing;\n"
        f"' LockSessionUI guards in-session input races. Released after activation.\n"
        f"Dim wasLocked : wasLocked = TryLockSession(oSession)\n"
        f"If wasLocked Then\n"
        f"    WScript.Echo \"INFO: Session UI locked for the {section_label} critical section.\"\n"
        f"Else\n"
        f"    WScript.Echo \"INFO: LockSessionUI not available on this SAP GUI build; continuing without lock.\"\n"
        f"End If\n"
        f"\n"
    )


def make_release_block(verify_label: str) -> str:
    return (
        f"' --- Release the session UI lock; {verify_label} ---\n"
        f"ReleaseSession oSession, wasLocked\n"
        f"If wasLocked Then WScript.Echo \"INFO: Session UI lock released.\"\n"
        f"\n"
    )


def retrofit(file_path: Path, lock_anchor_re: re.Pattern, release_anchor_re: re.Pattern,
             section_label: str, verify_label: str, dry_run: bool = False) -> str:
    """Returns 'SKIPPED', 'WROTE', or 'ERROR: ...'."""
    text = file_path.read_text(encoding="utf-8-sig")
    if "TryLockSession" in text:
        return "SKIPPED (already retrofitted)"

    lines = text.splitlines(keepends=True)

    # 1. Find the LAST `Const VKEY_*` line; insert include after the trailing
    # Const block. Some scripts (e.g. sap_se11_change_package.vbs) only have
    # VKEY_ENTER, not VKEY_F11_SAVE — so we use any VKEY_* as the marker.
    last_vkey_idx = None
    for i, ln in enumerate(lines):
        if re.match(r"^Const VKEY_", ln):
            last_vkey_idx = i
    if last_vkey_idx is None:
        return "ERROR: no `Const VKEY_*` line found"
    include_idx = last_vkey_idx + 1
    # Step past any further Const lines that may follow VKEY_*.
    while include_idx < len(lines) and re.match(r"^Const ", lines[include_idx]):
        include_idx += 1

    # 2. Find lock anchor — insert lock block before this line.
    lock_idx = None
    for i, ln in enumerate(lines):
        if i <= include_idx:
            continue
        if lock_anchor_re.search(ln):
            lock_idx = i
            break
    if lock_idx is None:
        return f"ERROR: lock anchor not found ({lock_anchor_re.pattern!r})"

    # 3. Find release anchor — insert release block before this line.
    release_idx = None
    for i, ln in enumerate(lines):
        if i <= lock_idx:
            continue
        if release_anchor_re.search(ln):
            release_idx = i
            break
    if release_idx is None:
        return f"ERROR: release anchor not found ({release_anchor_re.pattern!r})"

    # 4. Find every `WScript.Quit` between lock_idx and release_idx; record
    # them as (line_index, indent) so we can insert a release call before each.
    quit_inserts = []  # list of (line_idx, indent_str)
    for i in range(lock_idx + 1, release_idx):
        m = re.match(r"^(\s*)WScript\.Quit\b", lines[i])
        if m:
            quit_inserts.append((i, m.group(1)))

    # ---- Apply insertions in reverse order so earlier indices stay valid ----
    new_lines = list(lines)

    # 4. Insert release-before-quit (highest indices first)
    for idx, indent in reversed(quit_inserts):
        new_lines.insert(idx, f"{indent}ReleaseSession oSession, wasLocked\n")

    # 3. Insert release block (before release_idx — which has shifted by len(quit_inserts) ... wait, no:
    #    quit_inserts are AFTER lock_idx and BEFORE release_idx, so insertions there
    #    pushed release_idx forward. Recompute release_idx by counting added lines).
    release_block = make_release_block(verify_label)
    new_lines.insert(release_idx + len(quit_inserts), release_block)

    # 2. Insert lock block (before lock_idx — unaffected by later insertions)
    lock_block = make_lock_block(section_label)
    new_lines.insert(lock_idx, lock_block)

    # 1. Insert include (before include_idx — unaffected by later insertions)
    new_lines.insert(include_idx, INCLUDE_BLOCK)

    new_text = "".join(new_lines)

    if dry_run:
        # Print a small summary.
        return (f"DRY-RUN ok: lock at line ~{lock_idx + 1}, release at line ~{release_idx + 1}, "
                f"{len(quit_inserts)} in-lock Quits wrapped")

    file_path.write_text(new_text, encoding="utf-8")
    return (f"WROTE: lock at line ~{lock_idx + 1}, release at line ~{release_idx + 1}, "
            f"{len(quit_inserts)} in-lock Quits wrapped")


def patch_skill_md(vbs_relpath: str, dry_run: bool = False) -> str:
    """Find the SKILL.md token-replacement block matching this retrofitted VBS
    and insert a `%%SESSION_LOCK_VBS%%` replacement before its Set-Content.

    The matching is by Get-Content of the retrofitted VBS file, not by the
    Set-Content's run-name (which may be generic like `sap_se11_create_run.vbs`).
    For each Get-Content of `<vbs>.vbs`, walk forward to the next Set-Content
    of any `*_run.vbs` and insert the new token-replace line before it.

    Idempotent — skips a block that already has the SESSION_LOCK_VBS token.
    """
    vbs_basename = Path(vbs_relpath).name  # e.g. "sap_se37_create.vbs"
    skill_dir = (PLUGINS / vbs_relpath).parent.parent
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.exists():
        return f"  SKILL.md not found at {skill_md.name}"

    text = skill_md.read_text(encoding="utf-8-sig")

    # Find Get-Content of the retrofitted VBS file.
    get_content_re = re.compile(
        r"Get-Content\s+['\"][^'\"]*\\references\\" + re.escape(vbs_basename) + r"['\"]",
        re.IGNORECASE,
    )
    set_content_re = re.compile(
        r"^(?P<indent>\s*)Set-Content\s+['\"][^'\"]*_run\.vbs['\"]",
        re.MULTILINE,
    )

    get_matches = list(get_content_re.finditer(text))
    if not get_matches:
        return f"  no Get-Content for {vbs_basename} in {skill_md.name}"

    # For each Get-Content, find the NEXT Set-Content. Insert before it.
    new_text = text
    inserted = 0

    # Process in reverse order to keep offsets valid.
    for gm in reversed(get_matches):
        sm = set_content_re.search(new_text, pos=gm.end())
        if not sm:
            continue
        line_start = new_text.rfind("\n", 0, sm.start()) + 1
        # Idempotency: if the immediate block (between gm and sm) already
        # mentions SESSION_LOCK_VBS, skip.
        if "%%SESSION_LOCK_VBS%%" in new_text[gm.end():sm.end()]:
            continue
        indent = sm.group("indent")
        token_line = (
            f"{indent}$content = $content -replace "
            f"'%%SESSION_LOCK_VBS%%','<SAP_DEV_CORE_SHARED_DIR>\\scripts\\sap_session_lock.vbs'\n"
        )
        new_text = new_text[:line_start] + token_line + new_text[line_start:]
        inserted += 1

    if inserted == 0:
        return f"  {skill_md.name}: already has SESSION_LOCK_VBS for {vbs_basename}"

    if dry_run:
        return f"  DRY-RUN {skill_md.name}: would insert {inserted} token line(s) for {vbs_basename}"

    skill_md.write_text(new_text, encoding="utf-8")
    return f"  {skill_md.name}: inserted {inserted} token line(s) for {vbs_basename}"


def main() -> int:
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]

    if args:
        targets = {a: RETROFITS.get(a) for a in args}
    else:
        targets = RETROFITS

    failed = 0
    for rel, cfg in targets.items():
        path = PLUGINS / rel
        if not path.exists():
            print(f"  MISSING: {rel}")
            failed += 1
            continue
        if not cfg or "lock_anchor" not in cfg:
            print(f"  TODO: {rel} (no boundary config)")
            continue
        try:
            result = retrofit(
                path,
                re.compile(cfg["lock_anchor"]),
                re.compile(cfg["release_anchor"]),
                cfg["section_label"],
                cfg["verify_label"],
                dry_run=dry_run,
            )
            print(f"{rel}: {result}")
            if result.startswith("ERROR"):
                failed += 1
                continue
            # Patch the matching SKILL.md token-replacement block.
            md_result = patch_skill_md(rel, dry_run=dry_run)
            print(md_result)
        except Exception as e:
            print(f"  ERROR: {rel}: {e}")
            failed += 1

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
