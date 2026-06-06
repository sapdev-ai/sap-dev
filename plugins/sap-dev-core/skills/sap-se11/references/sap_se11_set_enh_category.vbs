' =============================================================================
' sap_se11_set_enh_category.vbs  -  SE11: set the Enhancement Category for a
'                                       table or structure proactively, so
'                                       activation doesn't warn and SAP
'                                       doesn't pop up a forced dialog.
'
' Include via the standard pattern (callers replace %%ENH_CATEGORY_VBS%%
' with the absolute path of this file at generation time):
'
'   ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
'       .OpenTextFile("%%ENH_CATEGORY_VBS%%", 1).ReadAll()
'
' Then, AFTER Save and BEFORE Activate:
'
'   Call SetEnhancementCategory(oSession, "NOT_EXTENSIBLE", SAP_TRANSPORT)
'
' Input modes (caller picks; auto-default uses direct mode)
' ---------------------------------------------------------
'
' DIRECT-RADIO MODE -- pass an SAP-side radio name (R_*); the helper
' targets that radio 1:1 with NO multi-candidate fallback. Use when you
' need predictable on-disk behaviour and don't want the helper to guess
' a "similar" radio on a release where the name differs.
'
'   R_FINAL      -> "Cannot Be Enhanced"             (DEFAULT -- empty input)
'   R_FLAT       -> "Can be enhanced (char-like or numeric)"
'   R_CHARONLY   -> "Can be enhanced (character-like)"
'   R_DEEP       -> "Can Be Enhanced (Deep)"
'   R_NOCLASS    -> "Not classified" (legacy)
'
' CATEGORY MODE -- pass a logical category; the helper resolves it
' across SAP_BASIS releases via candidate names + position fallback.
'
'   NOT_EXTENSIBLE   -> tries R_FINAL, then older-release fallbacks
'   FLAT             -> tries R_FLAT, then older-release fallbacks
'   FLAT_NUMERIC     -> tries R_CHARONLY, then older-release fallbacks
'   DEEP             -> tries R_DEEP
'   NOT_CLASSIFIED   -> tries R_NOCLASS
'
' Default rule: when no value is supplied (empty string, missing arg, or
' an unreplaced %%...%% template token), the helper sets `R_FINAL`
' DIRECTLY (direct mode, no fallback). This is per operator instruction
' "If an empty is passed, do not set NOT_EXTENSIBLE, set it to R_FINAL"
' (2026-05-11) -- the default path bypasses the category abstraction so
' the operator can predict the on-disk SAP behaviour 1:1.
'
' Unrecognized non-R_ tokens are coerced to R_FINAL (direct mode) with
' a WARN, so a typoed argument still gives the safe behaviour.
'
' Verified evidence (S/4HANA 1909, SAP_BASIS 7.55, EN + JA logon, 2026-05-11)
' --------------------------------------------------------------------------
' Tree dumps captured by /sap-gui-object-details during create + update
' flows on ZCMST_RFC_PARAM. Both modes expose IDENTICAL paths:
'
'   wnd[0]/mbar/menu[4]                 = "Extras"
'   wnd[0]/mbar/menu[4]/menu[7]         = "Enhancement Category..."
'   wnd[1] title                        = "Maintain Enhancement Category for <NAME>"
'   wnd[1]/tbar[0]/btn[0]               = "Copy" (commits selection)
'   wnd[1]/tbar[0]/btn[12]              = Cancel (F12)
'   wnd[1]/usr/radDESED7-R_DEEP         UI pos 0   "Can Be Enhanced (Deep)"
'   wnd[1]/usr/radDESED7-R_FLAT         UI pos 1   "Can be enhanced (character-like or numeric)"
'   wnd[1]/usr/radDESED7-R_CHARONLY     UI pos 2   "Can be enhanced (character-like)"
'   wnd[1]/usr/radDESED7-R_FINAL        UI pos 3   "Cannot Be Enhanced"
'   wnd[1]/usr/radDESED7-R_NOCLASS      UI pos 4   "Not classified"
'
' DD02L.EXCLASS encoding (SAP-internal, post-save persistence layer)
' -------------------------------------------------------------------
' NOTE: UI position order <> DD02L.EXCLASS code. After save, the chosen
' radio is persisted into DD02L.EXCLASS with these codes:
'
'   " " (blank / "0")  Not classified            (R_NOCLASS)
'   "1"                Cannot Be Enhanced        (R_FINAL)
'   "2"                Can be enhanced (char/num)(R_FLAT)
'   "3"                Can be enhanced (char)    (R_CHARONLY)
'   "4"                Can be enhanced (deep)    (R_DEEP)
'
' RFC verifiers (e.g. /sap-dev-status) should read DD02L.EXCLASS and map
' it back to the radio name using THIS table, not the UI position order.
'
' Canonical create-flow sequence (Record_SE11_EnhancementCategory_03.vbs)
' ----------------------------------------------------------------------
'   1. Fill description in tabpHEAD
'   2. Fill at least one component on tabpDEF (DO NOT trailing-Enter)
'   3. setFocus on the last component's ROLLNAME cell
'   4. menu[4]/menu[7]                                     <- Extras > Enhancement Category
'   5. wnd[1]/tbar[0]/btn[0].press                         <- dismiss "not classified" info popup
'   6. wnd[1]/usr/radDESED7-R_<X>.select                   <- pick radio
'   7. wnd[1]/tbar[0]/btn[0].press                         <- Copy commits
'   8. sendVKey 11 (Ctrl+S) ; activate (Ctrl+F3 / sendVKey 27)
'
' Caller responsibilities: invoke SetEnhancementCategory AFTER component
' fill but BEFORE Check and BEFORE Save. The trailing VKEY_ENTER must be
' OMITTED -- it triggers SAP auto-validate which raises an extra info
' popup that prevents the menu flow from reaching the radio dialog.
'
' Behaviour
' ---------
' Best-effort: any failure (menu not found, dialog never appears, radio
' name missing on this release) is echoed as a WARN line and the function
' returns False. The caller proceeds to Activate, where SAP's own popup
' will surface. The function never raises a script error.
'
' Resolution strategy (3 layers)
' ------------------------------
' 1. **Fast-path** -- try wnd[0]/mbar/menu[4]/menu[7] directly (confirmed
'    on S/4HANA 1909 EN). If the resulting dialog has radDESED7-* radios,
'    we're done navigating.
' 2. **Label walk under Extras** -- normalized + substring matching across
'    EN / JA / DE / ZH labels.
' 3. **Whole-menubar scan** -- some releases / modes move Enhancement
'    Category to a different parent menu. Search every top-level menu.
'
' Once the dialog is open, radio selection follows the same 3-layer
' approach: known-good radio name (R_FINAL etc.) -> release-portability
' fallbacks (R_NOT_EXTENSIBLE etc.) -> position-based selection.
'
' Diagnostics
' -----------
' One INFO line per stage on success. On failure each layer logs a WARN
' with what it tried and a dump of what SAP actually exposed so the
' operator can extend the candidate lists for new releases.
' =============================================================================

Option Explicit

' --- Fast-path menu indices (S/4HANA 1909 EN, confirmed 2026-05-11) --------
Const ENH_MENU_FAST_TOP  = 4   ' "Extras"
Const ENH_MENU_FAST_ITEM = 7   ' "Enhancement Category..."

' --- Public entry point ----------------------------------------------------

Function SetEnhancementCategory(oSess, sCategory, sTransport)
    SetEnhancementCategory = False
    If oSess Is Nothing Then Exit Function

    Dim sCat : sCat = NormalizeCategoryToken(sCategory)
    Dim sIn : sIn = Trim(CStr(sCategory))
    Dim sNote : sNote = ""
    If sIn = "" Or Left(UCase(sIn), 2) = "%%" Then
        sNote = " (no value supplied -> default radDESED7-R_FINAL, direct mode)"
    ElseIf IsDirectRadio(sCat) Then
        sNote = " (direct mode: target radio name, no fallback)"
    Else
        sNote = " (category mode: multi-candidate + position fallback)"
    End If
    WScript.Echo "INFO: Setting Enhancement Category (target: " & sCat & _
                 " -> radDESED7-" & PrimaryRadioForCategory(sCat) & ")" & sNote & "..."

    On Error Resume Next

    ' ------ Step 1: Open the Enhancement Category dialog ------------------
    If Not OpenEnhCategoryDialog(oSess) Then
        Err.Clear
        Exit Function
    End If

    ' ------ Step 2: Select the requested radio ----------------------------
    If Not SelectEnhCategoryRadio(oSess, sCat) Then
        Err.Clear
        Exit Function
    End If

    ' ------ Step 3: Confirm dialog (Copy = tbar[0]/btn[0]) ----------------
    Dim sActWnd : sActWnd = ActiveWindowToken(oSess)
    oSess.findById(sActWnd & "/tbar[0]/btn[0]").press
    WScript.Sleep 800
    Err.Clear

    ' ------ Step 4: Save (Ctrl+S) -----------------------------------------
    oSess.findById("wnd[0]").sendVKey 11
    WScript.Sleep 1200
    Err.Clear

    ' ------ Step 5: Handle the optional ODE / TR popup --------------------
    Call HandleTransportPopup(oSess, sTransport)

    WScript.Echo "INFO: Enhancement Category set and saved."
    SetEnhancementCategory = True
    Err.Clear
    On Error GoTo 0
End Function

' --- Category / radio normalization ----------------------------------------
'
' The helper supports TWO input modes which translate to two distinct
' selection strategies in SelectEnhCategoryRadio:
'
' (1) DIRECT-RADIO MODE -- caller already knows the exact SAP-side radio
'     name they want and the helper targets it 1:1 with NO fallback list.
'     If the named radio doesn't exist on this release, the helper fails
'     loudly rather than guessing a "close enough" candidate.
'     Inputs that select this mode:
'       - empty / unreplaced %%...%% / missing -> R_FINAL  (DEFAULT)
'       - any uppercase "R_*" token -> that radio, verbatim
'
' (2) CATEGORY MODE -- caller passes a logical category name; the helper
'     uses a release-portable multi-candidate fallback chain plus a
'     position-based last resort so it works across SAP_BASIS releases
'     even if SAP renames the radio internally.
'     Inputs that select this mode:
'       - NOT_EXTENSIBLE | FLAT | FLAT_NUMERIC | DEEP | NOT_CLASSIFIED
'         and their documented aliases (NONE, CANNOT, ANY, CHAR_LIKE, ...)
'
' Why two modes?
'
' Operator instruction 2026-05-11: "If an empty is passed, do not set
' NOT_EXTENSIBLE, set it to R_FINAL." The distinction matters because
' NOT_EXTENSIBLE is a logical concept that maps to different SAP radio
' names on different releases (R_FINAL on S/4HANA 1909, possibly
' R_NOT_EXTENSIBLE on older builds, R_NICHT on a hypothetical DE-only
' release, etc.). The default path must NOT depend on category->radio
' resolution; it must hit R_FINAL directly so the operator can predict
' the on-disk SAP behaviour 1:1.
'
' Returns one of:
'   "R_FINAL", "R_FLAT", "R_CHARONLY", "R_DEEP", "R_NOCLASS"      (direct mode)
'   "NOT_EXTENSIBLE", "FLAT", "FLAT_NUMERIC", "DEEP", "NOT_CLASSIFIED" (category mode)
'   (or any other "R_*" string the caller passes verbatim -- direct mode)
'
' Unrecognized non-R_ tokens are coerced to R_FINAL (direct mode) with a
' WARN, so a typoed argument still gives the safe behaviour.
Function NormalizeCategoryToken(sIn)
    Dim s : s = UCase(Trim(CStr(sIn)))

    ' --- Direct mode: empty / template-token / explicit R_* ---
    If s = "" Or Left(s, 2) = "%%" Or s = "%%ENHANCEMENT_CATEGORY%%" Then
        NormalizeCategoryToken = "R_FINAL"   ' default, direct (no fallback)
        Exit Function
    End If
    If Left(s, 2) = "R_" Then
        NormalizeCategoryToken = s   ' verbatim, direct (no fallback)
        Exit Function
    End If

    ' --- Category mode: logical names + aliases ---
    Select Case s
        Case "NOT_EXTENSIBLE", "NONE", "CANNOT_BE_ENHANCED", "CANNOT", "FINAL"
            NormalizeCategoryToken = "NOT_EXTENSIBLE"
        Case "FLAT", "CHAR_NUMERIC", "C_AND_N", "CHARACTER_OR_NUMERIC"
            NormalizeCategoryToken = "FLAT"
        Case "FLAT_NUMERIC", "CHAR_ONLY", "CHARONLY", "C", "CHARACTER", _
             "CHAR_LIKE", "CHARACTER_LIKE"
            NormalizeCategoryToken = "FLAT_NUMERIC"
        Case "DEEP", "ANY"
            NormalizeCategoryToken = "DEEP"
        Case "NOT_CLASSIFIED", "NOCLASS", "UNCLASSIFIED"
            NormalizeCategoryToken = "NOT_CLASSIFIED"
        Case Else
            WScript.Echo "WARN: Unrecognized Enhancement Category '" & sIn & _
                         "' -- coercing to R_FINAL (direct, no fallback)."
            NormalizeCategoryToken = "R_FINAL"
    End Select
End Function

' True iff the token is a direct radio name (R_* prefix). Direct names
' bypass the category multi-candidate fallback chain.
Function IsDirectRadio(sToken)
    IsDirectRadio = (Left(UCase(Trim(CStr(sToken))), 2) = "R_")
End Function

' Map a normalized category token to the SAP-side radio it targets first.
' For direct radio tokens (R_*), returns the token itself. Used in
' diagnostic echoes so operators can confirm what the helper will click
' before it acts.
Function PrimaryRadioForCategory(sCat)
    If IsDirectRadio(sCat) Then
        PrimaryRadioForCategory = UCase(Trim(CStr(sCat)))
        Exit Function
    End If
    Select Case sCat
        Case "NOT_EXTENSIBLE" : PrimaryRadioForCategory = "R_FINAL"
        Case "FLAT"           : PrimaryRadioForCategory = "R_FLAT"
        Case "FLAT_NUMERIC"   : PrimaryRadioForCategory = "R_CHARONLY"
        Case "DEEP"           : PrimaryRadioForCategory = "R_DEEP"
        Case "NOT_CLASSIFIED" : PrimaryRadioForCategory = "R_NOCLASS"
        Case Else             : PrimaryRadioForCategory = "R_FINAL"
    End Select
End Function

' --- Category -> (position, primary_radio, [release_fallbacks]) -----------
'
' Position is the 0-based index of the radio in the dialog's radDESED7-*
' children order. SAP orders them "most flexible -> least flexible" on
' every release observed (S/4HANA 1909 confirmed live; older releases via
' release notes). Used as a locale-independent fallback when none of the
' explicit candidate names resolve on this release.
'
' Returns Array(position_int, candidate_name_array).
Function GetCategoryMapping(sCat)
    Dim pos, cands
    Select Case sCat
        Case "DEEP"
            pos = 0
            cands = Array("R_DEEP", "R_ANY", "R_TIEF", "R_D")
        Case "FLAT"
            pos = 1
            cands = Array("R_FLAT", "R_C_AND_N", "R_CHAR_NUM", "R_CHARNUM", "R_CN")
        Case "FLAT_NUMERIC"
            pos = 2
            ' R_CHARONLY is the verified S/4HANA 1909 name (2026-05-11).
            ' R_FLAT_NUMERIC / R_C / R_CHAR are older-release fallbacks.
            cands = Array("R_CHARONLY", "R_FLAT_NUMERIC", "R_C", "R_CHAR", "R_CH")
        Case "NOT_EXTENSIBLE"
            pos = 3
            ' R_FINAL is the verified S/4HANA 1909 name (2026-05-11) -- SAP's
            ' internal name for "the structure is FINAL / cannot be
            ' extended further". The R_NOT_EXTENSIBLE / R_NONE / R_NICHT /
            ' R_NO_EXT entries are older-release fallbacks.
            cands = Array("R_FINAL", "R_NOT_EXTENSIBLE", "R_NONE", _
                          "R_NICHT", "R_NO_EXT", "R_NOEXT", _
                          "R_NOT_EXT", "R_KEINE", "R_CANNOT", _
                          "R_C_E", "R_NE")
        Case "NOT_CLASSIFIED"
            pos = 4
            cands = Array("R_NOCLASS", "R_UNCLASSIFIED", "R_NICHT_KLASS")
        Case Else
            ' Should never reach here -- NormalizeCategoryToken already
            ' coerced unknowns to NOT_EXTENSIBLE.
            pos = 3
            cands = Array("R_FINAL", "R_NOT_EXTENSIBLE")
    End Select
    GetCategoryMapping = Array(pos, cands)
End Function

' --- Open the Enhancement Category dialog ---------------------------------
'
' Tries three navigation strategies in order. Returns True iff the active
' window is the radio dialog after navigation (verified by probing for
' any radDESED7-* component).
Function OpenEnhCategoryDialog(oSess)
    OpenEnhCategoryDialog = False
    On Error Resume Next

    Dim oMbar : Set oMbar = oSess.findById("wnd[0]/mbar")
    If Err.Number <> 0 Or oMbar Is Nothing Then
        WScript.Echo "WARN: Menu bar not found; skipping Enhancement Category step."
        Err.Clear
        Exit Function
    End If

    ' --- Strategy 1: fast-path via known indices (S/4HANA 1909 EN) -------
    Dim oFast : Set oFast = Nothing
    Set oFast = oSess.findById("wnd[0]/mbar/menu[" & ENH_MENU_FAST_TOP & _
                               "]/menu[" & ENH_MENU_FAST_ITEM & "]")
    If Err.Number = 0 And Not (oFast Is Nothing) Then
        If TrySelectMenuItem(oSess, oFast, "fast-path indices [" & _
                ENH_MENU_FAST_TOP & "][" & ENH_MENU_FAST_ITEM & "]") Then
            OpenEnhCategoryDialog = True
            Exit Function
        End If
    End If
    Err.Clear

    ' --- Strategy 2: label walk under "Extras" ---------------------------
    Dim aExtras
    aExtras = Array( _
        "Extras", "Extra", _
        "Zus" & ChrW(228) & "tze", _
        ChrW(36861) & ChrW(21152), _
        ChrW(38468) & ChrW(21152), _
        ChrW(25313) & ChrW(24373), _
        ChrW(12518) & ChrW(12540) & ChrW(12486) & ChrW(12451) & ChrW(12522) & ChrW(12486) & ChrW(12451), _
        ChrW(12458) & ChrW(12503) & ChrW(12471) & ChrW(12519) & ChrW(12531) _
    )

    Dim aEhCat
    aEhCat = Array( _
        "Enhancement Category", "Enhancement", _
        "Erweiterungskategorie", "Erweiterung", _
        ChrW(25313) & ChrW(24373) & ChrW(12459) & ChrW(12486) & ChrW(12468) & ChrW(12522), _
        ChrW(25313) & ChrW(24373), _
        ChrW(22686) & ChrW(24378) & ChrW(31867) & ChrW(21035), _
        ChrW(22686) & ChrW(24378) _
    )

    Dim oExtras : Set oExtras = FindMenuByLabels(oMbar, aExtras)
    If Not (oExtras Is Nothing) Then
        Dim oCat : Set oCat = FindMenuByLabels(oExtras, aEhCat)
        If Not (oCat Is Nothing) Then
            If TrySelectMenuItem(oSess, oCat, "label walk under Extras") Then
                OpenEnhCategoryDialog = True
                Exit Function
            End If
        Else
            WScript.Echo "INFO: Extras menu found but 'Enhancement Category' not under it. Available Extras submenu items:"
            DumpMenuChildren oExtras, "  "
        End If
        Err.Clear
    Else
        WScript.Echo "INFO: Extras menu not located by label. Falling back to whole-menubar scan."
    End If

    ' --- Strategy 3: whole-menubar scan for any submenu Enhancement Category
    Dim iTop, oTop, oScanCat
    For iTop = 0 To oMbar.Children.Count - 1
        Set oTop = oMbar.Children.Item(iTop)
        Err.Clear
        Set oScanCat = Nothing
        Set oScanCat = FindMenuByLabels(oTop, aEhCat)
        If Err.Number = 0 And Not (oScanCat Is Nothing) Then
            WScript.Echo "INFO: Found 'Enhancement Category' under top-level menu [" & _
                         iTop & "] '" & oTop.Text & "'."
            If TrySelectMenuItem(oSess, oScanCat, "whole-menubar scan") Then
                OpenEnhCategoryDialog = True
                Exit Function
            End If
        End If
        Err.Clear
    Next

    WScript.Echo "WARN: Could not locate 'Enhancement Category' under any top-level menu. Menubar dump:"
    DumpMenuChildren oMbar, "  "
    Err.Clear
    On Error GoTo 0
End Function

' --- Select a menu item and verify the radio dialog opened -----------------
'
' Click the menu item, then walk up to N intermediate popups until either
' the radio dialog (radDESED7-*) appears OR the chain dead-ends.
'
' Why a popup chain: when EXCLASS=0 (not yet classified) on a freshly-
' saved structure, SE11 shows a SEQUENCE before opening the radio dialog
' on JA / DE / some 7.55 builds:
'
'   1. Info popup     "Enhancement category has not been maintained ..."
'      -> needs Enter (sendVKey 0)
'   2. SPOP Yes/No    "Maintain enhancement category now?"
'      -> needs btnSPOP-OPTION1 (Yes); Enter does NOT dismiss SPOP popups
'   3. Radio dialog   wnd[1]/usr/radDESED7-*
'
' The previous implementation tried Enter once then gave up, leaving the
' SPOP unanswered and the helper unable to reach the radios.
'
' This walker handles each popup by detecting its fingerprint:
'   - radDESED7-* present     -> success, exit
'   - btnSPOP-OPTION1 present -> press Yes
'   - else                    -> Enter (info popup)
' Returns True iff the radio dialog is on screen after walking.
Function TrySelectMenuItem(oSess, oMenuItem, sLabel)
    TrySelectMenuItem = False
    On Error Resume Next
    oMenuItem.select
    WScript.Sleep 700
    If Err.Number <> 0 Then
        Err.Clear
        Exit Function
    End If

    ' Walk up to 5 chained popups looking for the radio dialog.
    '
    ' Confirmed popup chain on S/4HANA 1909 JA (2026-05-11, user screenshot):
    '   1. Information popup -- body: "<NAME> is not classified - select an
    '      enhancement category (see documentation)". Single OK button via
    '      `wnd[1]/tbar[0]/btn[0]` (green checkmark). sendVKey 0 (Enter) on
    '      the active window does NOT reliably dismiss this popup if focus
    '      is on the help button or the body area, so we explicitly press
    '      btn[0]. WScript.Sleep 1200 between dismiss and re-probe so SAP
    '      can finish rendering the radio dialog before our HasEnhCatRadios
    '      check fires.
    '   2. (radio dialog appears with R_DEEP pre-selected as SAP default)
    '
    ' Other popup classes the walker handles:
    '   - SPOP Yes/No: needs explicit btnSPOP-OPTION1; Enter is a no-op.
    Dim iWalk, sActWnd, sPopupId, oSpopYes, oOkBtn
    For iWalk = 1 To 5
        If HasEnhCatRadios(oSess) Then
            WScript.Echo "INFO: Enhancement Category dialog opened via " & sLabel & _
                         " (popup walk depth=" & (iWalk - 1) & ")."
            TrySelectMenuItem = True
            Exit Function
        End If

        sActWnd = oSess.ActiveWindow.Id
        If Right(sActWnd, 6) = "wnd[0]" Then
            WScript.Echo "INFO: " & sLabel & " returned to wnd[0] without opening the radio dialog."
            Exit Function
        End If
        sPopupId = ActiveWindowToken(oSess)

        ' --- SPOP Yes/No (e.g. "save first?") --------------------------
        Set oSpopYes = Nothing
        Err.Clear
        Set oSpopYes = oSess.findById(sPopupId & "/usr/btnSPOP-OPTION1")
        If Err.Number = 0 And Not (oSpopYes Is Nothing) Then
            WScript.Echo "INFO: Popup walk " & iWalk & " on " & sActWnd & _
                         ": SPOP Yes/No; pressing OPTION1 (Yes)."
            oSpopYes.press
            WScript.Sleep 1200
            Err.Clear
        Else
            Err.Clear
            ' --- Generic info popup: prefer toolbar btn[0] (Continue) --
            ' Press the explicit OK button rather than sendVKey 0. On
            ' some popups Enter goes to the help icon instead of OK.
            Set oOkBtn = Nothing
            Err.Clear
            Set oOkBtn = oSess.findById(sPopupId & "/tbar[0]/btn[0]")
            If Err.Number = 0 And Not (oOkBtn Is Nothing) Then
                WScript.Echo "INFO: Popup walk " & iWalk & " on " & sActWnd & _
                             ": info popup; pressing tbar[0]/btn[0] (Continue)."
                oOkBtn.press
                WScript.Sleep 1200
                Err.Clear
            Else
                Err.Clear
                WScript.Echo "INFO: Popup walk " & iWalk & " on " & sActWnd & _
                             ": no btn[0]; falling back to Enter (sendVKey 0)."
                oSess.ActiveWindow.sendVKey 0
                WScript.Sleep 1200
                Err.Clear
            End If
        End If
    Next

    WScript.Echo "INFO: " & sLabel & " did not produce the radio dialog after 5-popup walk (active=" & _
                 oSess.ActiveWindow.Id & "); trying next strategy."
    Err.Clear
    On Error GoTo 0
End Function

' --- Select the requested radio (already-selected -> name -> position) ----
Function SelectEnhCategoryRadio(oSess, sCat)
    SelectEnhCategoryRadio = False
    On Error Resume Next

    Dim sActWnd : sActWnd = ActiveWindowToken(oSess)

    ' ============ DIRECT-RADIO MODE (R_* input, no fallback) ============
    ' Per operator instruction 2026-05-11: when an empty / template-token /
    ' unrecognized value is passed, the default lands on R_FINAL directly
    ' (NormalizeCategoryToken returns "R_FINAL", not "NOT_EXTENSIBLE"). An
    ' explicit R_* token (e.g. "R_FLAT", "R_DEEP") behaves the same way:
    ' the helper targets that single radio and refuses to silently
    ' substitute a different one. This guarantees predictable on-disk
    ' behaviour regardless of release-specific radio renames.
    If IsDirectRadio(sCat) Then
        Dim sName : sName = UCase(Trim(CStr(sCat)))
        Dim oDirect : Set oDirect = Nothing
        Err.Clear
        Set oDirect = oSess.findById(sActWnd & "/usr/radDESED7-" & sName)
        If Err.Number = 0 And Not (oDirect Is Nothing) Then
            If oDirect.Selected Then
                WScript.Echo "INFO: radDESED7-" & sName & _
                             " already selected; no change needed."
            Else
                oDirect.select
                WScript.Echo "INFO: Selected radDESED7-" & sName & " (direct mode)."
            End If
            SelectEnhCategoryRadio = True
            Exit Function
        End If
        Err.Clear

        ' Direct mode: do NOT fall back to other radio names. Surface
        ' loudly so the operator sees exactly what was missing.
        WScript.Echo "WARN: Direct-mode target radDESED7-" & sName & _
                     " does NOT exist on this SAP release. Available radios:"
        DumpRadiosInActiveWindow oSess, "  "
        WScript.Echo "WARN: Cancelling dialog (F12); no substitute radio will be selected in direct mode."
        oSess.findById(sActWnd).sendVKey 12   ' F12 = Cancel
        WScript.Sleep 500
        Err.Clear
        Exit Function
    End If

    ' ============ CATEGORY MODE (multi-candidate + position fallback) ===
    Dim mapping : mapping = GetCategoryMapping(sCat)
    Dim iWantPos : iWantPos = mapping(0)
    Dim aCands   : aCands   = mapping(1)

    ' --- Layer A: skip-select if the right radio is already selected ----
    Dim oTry : Set oTry = Nothing
    Dim iC
    For iC = 0 To UBound(aCands)
        Set oTry = Nothing
        Err.Clear
        Set oTry = oSess.findById(sActWnd & "/usr/radDESED7-" & aCands(iC))
        If Err.Number = 0 And Not (oTry Is Nothing) Then
            If oTry.Selected Then
                WScript.Echo "INFO: radDESED7-" & aCands(iC) & " already selected (" & sCat & "); no change needed."
                SelectEnhCategoryRadio = True
                Exit Function
            End If
            Exit For   ' first matching name found unselected -> Layer B will set it
        End If
        Err.Clear
    Next

    ' --- Layer B: try each candidate name; select first that resolves ---
    For iC = 0 To UBound(aCands)
        Set oTry = Nothing
        Err.Clear
        Set oTry = oSess.findById(sActWnd & "/usr/radDESED7-" & aCands(iC))
        If Err.Number = 0 And Not (oTry Is Nothing) Then
            oTry.select
            WScript.Echo "INFO: Selected radDESED7-" & aCands(iC) & " (" & sCat & ")."
            SelectEnhCategoryRadio = True
            Exit Function
        End If
        Err.Clear
    Next

    ' --- Layer C: position-based fallback ------------------------------
    WScript.Echo "INFO: No radDESED7-* matched explicit candidates for '" & sCat & "'."
    WScript.Echo "      Falling back to position-based selection (index " & iWantPos & ")."

    Dim oUsr : Set oUsr = Nothing
    Set oUsr = oSess.findById(sActWnd & "/usr")
    If Err.Number = 0 And Not (oUsr Is Nothing) Then
        Dim iCh, oCh, sIdCh, aRadList()
        ReDim aRadList(-1)
        Dim iRad : iRad = -1
        For iCh = 0 To oUsr.Children.Count - 1
            Set oCh = oUsr.Children.Item(iCh)
            sIdCh = oCh.Id
            If InStr(sIdCh, "/radDESED7-") > 0 Then
                iRad = iRad + 1
                ReDim Preserve aRadList(iRad)
                Set aRadList(iRad) = oCh
            End If
        Next
        If iWantPos >= 0 And iWantPos <= UBound(aRadList) Then
            aRadList(iWantPos).select
            WScript.Echo "INFO: Selected radio by position " & iWantPos & _
                         " (id=" & aRadList(iWantPos).Id & ", " & sCat & ")."
            SelectEnhCategoryRadio = True
            Exit Function
        End If
    End If
    Err.Clear

    WScript.Echo "WARN: Position fallback also failed for '" & sCat & "'. Available radios:"
    DumpRadiosInActiveWindow oSess, "  "
    WScript.Echo "WARN: Cancelling dialog (F12)."
    oSess.findById(sActWnd).sendVKey 12   ' F12 = Cancel
    WScript.Sleep 500
    Err.Clear
    On Error GoTo 0
End Function

' --- Helpers ---------------------------------------------------------------

' Return a normalized "wnd[N]" prefix (e.g. "wnd[1]") for the active window.
Function ActiveWindowToken(oSess)
    Dim sId : sId = oSess.ActiveWindow.Id
    Dim p   : p   = InStrRev(sId, "/wnd[")
    If p > 0 Then
        ActiveWindowToken = Mid(sId, p + 1)
        Dim q : q = InStr(ActiveWindowToken, "]")
        If q > 0 Then ActiveWindowToken = Left(ActiveWindowToken, q)
    Else
        p = InStrRev(sId, "wnd[")
        Dim q2 : q2 = InStr(p, sId, "]")
        ActiveWindowToken = Mid(sId, p, q2 - p + 1)
    End If
    If ActiveWindowToken = "" Then ActiveWindowToken = "wnd[1]"
End Function

' True if the active window contains the Enhancement Category radio dialog.
'
' Uses direct findById probes on the documented radio names rather than
' children enumeration. Verified live (operator recording 2026-05-11) that
' wnd[1]/usr/radDESED7-R_FINAL resolves cleanly when the radio dialog is
' open. Children enumeration sometimes returns 0 items mid-render (SAP
' renders the GuiBox first, then populates the radios), which made the
' previous version miss the dialog and fall back to dismissing it as an
' info popup.
Function HasEnhCatRadios(oSess)
    HasEnhCatRadios = False
    Dim sActWnd : sActWnd = ActiveWindowToken(oSess)
    Dim aProbes : aProbes = Array("R_FINAL", "R_DEEP", "R_FLAT", "R_CHARONLY", "R_NOCLASS")
    Dim oRad, i
    On Error Resume Next
    For i = 0 To UBound(aProbes)
        Set oRad = Nothing
        Err.Clear
        Set oRad = oSess.findById(sActWnd & "/usr/radDESED7-" & aProbes(i))
        If Err.Number = 0 And Not (oRad Is Nothing) Then
            HasEnhCatRadios = True
            Exit Function
        End If
    Next
    Err.Clear
    On Error GoTo 0
End Function

' Find a menu / submenu child by .Text matching any label in the list.
'
' Matching is lenient: both candidate and haystack are normalized first
' (see NormalizeMenuLabel) and the comparison is bidirectional InStr --
' "extras" matches "&Extras", "Extras(&E)", "Extras...", "  Extras  ".
' Returns Nothing on no match.
Function FindMenuByLabels(oParent, aLabels)
    Set FindMenuByLabels = Nothing
    Dim iCh, iLbl, sTxt, sNorm, sLblNorm
    On Error Resume Next
    Dim aNormLabels()
    ReDim aNormLabels(UBound(aLabels))
    For iLbl = 0 To UBound(aLabels)
        aNormLabels(iLbl) = NormalizeMenuLabel(aLabels(iLbl))
    Next
    For iCh = 0 To oParent.Children.Count - 1
        sTxt = oParent.Children.Item(iCh).Text
        If Err.Number = 0 Then
            sNorm = NormalizeMenuLabel(sTxt)
            For iLbl = 0 To UBound(aNormLabels)
                sLblNorm = aNormLabels(iLbl)
                If sLblNorm <> "" And sNorm <> "" Then
                    If InStr(sNorm, sLblNorm) > 0 Or InStr(sLblNorm, sNorm) > 0 Then
                        Set FindMenuByLabels = oParent.Children.Item(iCh)
                        Exit Function
                    End If
                End If
            Next
        End If
        Err.Clear
    Next
    Err.Clear
    On Error GoTo 0
End Function

' Normalize a menu label for lenient matching:
'   lowercased, accelerators (&) stripped, "(&X)" hints stripped, whitespace
'   stripped, trailing dots/dashes/ellipsis stripped.
Function NormalizeMenuLabel(s)
    Dim t : t = s
    If IsNull(t) Then t = ""
    t = LCase(t)
    Dim iOpen, iClose
    iOpen = InStr(t, "(")
    Do While iOpen > 0
        iClose = InStr(iOpen, t, ")")
        If iClose > iOpen Then
            t = Left(t, iOpen - 1) & Mid(t, iClose + 1)
        Else
            Exit Do
        End If
        iOpen = InStr(t, "(")
    Loop
    t = Replace(t, "&", "")
    t = Replace(t, " ", "")
    t = Replace(t, vbTab, "")
    Do While Len(t) > 0
        Dim lastCh : lastCh = Right(t, 1)
        If lastCh = "." Or lastCh = "-" Or lastCh = ChrW(&H2026) Then  ' ChrW(&H2026) = ellipsis, kept ASCII (see source_encoding_policy.md)
            t = Left(t, Len(t) - 1)
        Else
            Exit Do
        End If
    Loop
    NormalizeMenuLabel = t
End Function

' Echo each child's index, id, and Text. For diagnostics when label
' matching misses on a new SAP release.
Sub DumpMenuChildren(oParent, sIndent)
    On Error Resume Next
    Dim iCh, sTxt
    For iCh = 0 To oParent.Children.Count - 1
        sTxt = oParent.Children.Item(iCh).Text
        If Err.Number <> 0 Then sTxt = "(unreadable)" : Err.Clear
        WScript.Echo sIndent & "[" & iCh & "] " & oParent.Children.Item(iCh).Id & _
                     " text='" & sTxt & "'"
    Next
    Err.Clear
    On Error GoTo 0
End Sub

' Echo every rad* component visible on the active window. For diagnostics
' when none of the candidate radDESED7-* names match this release.
Sub DumpRadiosInActiveWindow(oSess, sIndent)
    On Error Resume Next
    Dim sActWnd : sActWnd = ActiveWindowToken(oSess)
    Dim oUsr : Set oUsr = oSess.findById(sActWnd & "/usr")
    If Err.Number <> 0 Or oUsr Is Nothing Then
        Err.Clear
        Exit Sub
    End If
    Dim iCh, sId
    For iCh = 0 To oUsr.Children.Count - 1
        sId = oUsr.Children.Item(iCh).Id
        If InStr(sId, "rad") > 0 Then
            WScript.Echo sIndent & sId
        End If
    Next
    Err.Clear
    On Error GoTo 0
End Sub

' Handle the optional ODE / TR popup that may appear after Ctrl+S commits
' the enhancement-category change. Mirrors the save-time pattern used in
' table_create / structure_create.
Sub HandleTransportPopup(oSess, sTransport)
    On Error Resume Next
    Dim sActId : sActId = oSess.ActiveWindow.Id
    If Err.Number <> 0 Then Err.Clear : Exit Sub
    If Right(sActId, 6) = "wnd[0]" Then Exit Sub

    Dim sActWnd : sActWnd = ActiveWindowToken(oSess)

    ' Object Directory Entry dialog
    Dim ko007 : Set ko007 = Nothing
    Set ko007 = oSess.findById(sActWnd & "/usr/ctxtKO007-L_DEVCLASS")
    If Err.Number = 0 And Not (ko007 Is Nothing) Then
        oSess.findById(sActWnd & "/tbar[0]/btn[0]").press   ' Continue
        WScript.Sleep 1000
    Else
        Err.Clear
    End If

    ' Transport request popup
    sActId = oSess.ActiveWindow.Id
    sActWnd = ActiveWindowToken(oSess)
    If Right(sActId, 6) <> "wnd[0]" Then
        Dim ko008 : Set ko008 = Nothing
        Set ko008 = oSess.findById(sActWnd & "/usr/ctxtKO008-TRKORR")
        If Err.Number = 0 And Not (ko008 Is Nothing) Then
            If sTransport <> "" Then ko008.Text = sTransport
            oSess.findById(sActWnd & "/tbar[0]/btn[0]").press
            WScript.Sleep 800
        Else
            Err.Clear
            ' Local-object button as last resort
            Dim oLocal : Set oLocal = Nothing
            Set oLocal = oSess.findById(sActWnd & "/tbar[0]/btn[7]")
            If Err.Number = 0 And Not (oLocal Is Nothing) Then
                oLocal.press
                WScript.Sleep 800
            Else
                Err.Clear
            End If
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Sub
