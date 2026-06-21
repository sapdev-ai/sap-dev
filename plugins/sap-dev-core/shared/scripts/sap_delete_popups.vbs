' =============================================================================
' sap_delete_popups.vbs  -  Shared post-delete popup walker for SAP GUI deletes.
'
' ONE locale-independent active-window walker shared by the delete VBS of
' sap-se37 / sap-se11 / sap-se24 / sap-se38 / sap-se21. After a Shift+F2
' (or application-toolbar) delete, SAP can chain several modals depending on
' the object + system; this walker dispatches each one by DDIC control id ONLY
' (never window title / button text), so it is correct under any logon language.
'
' Include it by deriving the path from the already-substituted attach-lib token
' (both files live in shared/scripts/, so no extra generator token is needed):
'
'   Dim oDpFso, sDpDir
'   Set oDpFso = CreateObject("Scripting.FileSystemObject")
'   sDpDir = oDpFso.GetParentFolderName("%%ATTACH_LIB_VBS%%")
'   ExecuteGlobal oDpFso.OpenTextFile(oDpFso.BuildPath(sDpDir, "sap_delete_popups.vbs"), 1).ReadAll()
'
' Then call it after pressing Delete:
'
'   Dim dpRes : dpRes = WalkDeletePopups(oSession, OBJDIR_PKG, OBJDIR_LANG, SAP_TRANSPORT)
'   If dpRes = "ABORT_EMPTY_TR" Then
'       WScript.Echo "ERROR: SAP prompted for a transport request but TRANSPORT is empty."
'       WScript.Echo "       Resolve a TR via /sap-transport-request and re-run."
'       ReleaseSession oSession, wasLocked
'       WScript.Quit 1
'   End If
'
' Popups handled, in priority order, dispatched by DDIC control id (cap 10):
'   * SAPLSETX original-vs-logon language  -> ctxtRSETX-MASTERLANG / btnPUSH1
'   * "Create Object Directory Entry"      -> ctxtKO007-L_DEVCLASS  (ECC6)
'        (fill empty package from objdirPkg + 1-char objdirLang, else accept
'         the pre-filled package, else Local Object btn[7])
'   * Transport-request prompt             -> ctxtKO008-TRKORR
'        (fill sapTr + Enter; if sapTr is empty -> return "ABORT_EMPTY_TR")
'   * Generic confirm                      -> btnSPOP-OPTION1 (Yes) then
'        btnBUTTON_1 then tbar[0]/btn[0] (Continue) then Enter
'
' Returns: ""               all popups handled (or none appeared)
'          "ABORT_EMPTY_TR" a TR popup appeared but sapTr was empty (the caller
'                           must release its session lock + WScript.Quit 1)
'
' NOTE: this is a pure FUNCTION LIBRARY -- it receives an already-attached
' oSession as a parameter and does NOT bind the Scripting engine, declare
' SESSION_PATH, include the attach lib, or call AttachSapSession. It is
' therefore not a "driving" VBS under the parallel-safe-attach contract (same
' shape as sap_session_lock.vbs) and lives in shared/scripts/, outside the
' skills/<skill>/references/ scan scope of scripts/check-consistency.mjs.
'
' Branches are each gated by a specific DDIC control id, so a branch only acts
' when its control is actually present; the union (KO007 + btnBUTTON_1 + ...)
' is a strict superset of every per-skill loop it replaces and cannot misfire
' on a screen that lacks the control.
' =============================================================================

Function WalkDeletePopups(oSession, objdirPkg, objdirLang, sapTr)
    WalkDeletePopups = ""

    Dim dpLang
    dpLang = objdirLang
    If dpLang = "" Then dpLang = "E"

    Dim iPop, sActWnd, sActPrefix, posWnd, bHandled
    Dim oML, oDevc, oObjLang, oTr, oYes, oBtn1, oCont
    For iPop = 1 To 10
        sActWnd = ""
        On Error Resume Next
        sActWnd = oSession.ActiveWindow.Id
        On Error GoTo 0
        If sActWnd = "" Then Exit For
        If Right(sActWnd, 6) = "wnd[0]" Then Exit For
        posWnd = InStrRev(sActWnd, "/wnd[")
        If posWnd > 0 Then sActPrefix = Mid(sActWnd, posWnd + 1) Else sActPrefix = "wnd[1]"
        bHandled = False

        ' (a) SAPLSETX original-vs-logon-language popup.
        On Error Resume Next
        Set oML = Nothing
        Set oML = oSession.findById(sActPrefix & "/usr/ctxtRSETX-MASTERLANG")
        If Err.Number = 0 And Not (oML Is Nothing) Then
            oSession.findById(sActPrefix & "/usr/btnPUSH1").press
            WScript.Echo "INFO: SAPLSETX original-language popup on " & sActPrefix & " -- 'Maint. in orig. lang.'"
            WScript.Sleep 1500 : bHandled = True
        End If
        Err.Clear
        On Error GoTo 0

        ' (b) "Create Object Directory Entry" (SAPLSTRD / KO007) -- ECC6.
        If Not bHandled Then
            On Error Resume Next
            Set oDevc = Nothing
            Set oDevc = oSession.findById(sActPrefix & "/usr/ctxtKO007-L_DEVCLASS")
            If Err.Number = 0 And Not (oDevc Is Nothing) Then
                If oDevc.Text = "" And objdirPkg <> "" Then
                    oDevc.Text = objdirPkg
                    Set oObjLang = Nothing
                    Set oObjLang = oSession.findById(sActPrefix & "/usr/ctxtKO007-L_MSTLANG")
                    If Err.Number = 0 And Not (oObjLang Is Nothing) Then
                        If oObjLang.Text = "" Then oObjLang.Text = dpLang
                    End If
                    Err.Clear
                    oSession.findById(sActPrefix & "/tbar[0]/btn[0]").press
                    WScript.Echo "INFO: Object Directory Entry on " & sActPrefix & " -- package " & objdirPkg & ", Continue."
                ElseIf oDevc.Text = "" Then
                    oSession.findById(sActPrefix & "/tbar[0]/btn[7]").press
                    WScript.Echo "INFO: Object Directory Entry on " & sActPrefix & " -- empty package, none supplied; Local Object."
                Else
                    oSession.findById(sActPrefix & "/tbar[0]/btn[0]").press
                    WScript.Echo "INFO: Object Directory Entry on " & sActPrefix & " -- accepted pre-filled package, Continue."
                End If
                WScript.Sleep 1500 : bHandled = True
            End If
            Err.Clear
            On Error GoTo 0
        End If

        ' (c) Transport-request prompt.
        If Not bHandled Then
            On Error Resume Next
            Set oTr = Nothing
            Set oTr = oSession.findById(sActPrefix & "/usr/ctxtKO008-TRKORR")
            If Err.Number = 0 And Not (oTr Is Nothing) Then
                On Error GoTo 0
                If sapTr = "" Then
                    WalkDeletePopups = "ABORT_EMPTY_TR"
                    Exit Function
                End If
                oTr.Text = sapTr
                oSession.findById(sActPrefix).sendVKey 0   ' Enter
                WScript.Echo "INFO: Filled transport " & sapTr & " on " & sActPrefix & "."
                WScript.Sleep 1500 : bHandled = True
            End If
            Err.Clear
            On Error GoTo 0
        End If

        ' (d) Generic confirm: Yes (SPOP) / btnBUTTON_1 / Continue / Enter.
        If Not bHandled Then
            On Error Resume Next
            Set oYes = Nothing
            Set oYes = oSession.findById(sActPrefix & "/usr/btnSPOP-OPTION1")
            If Err.Number = 0 And Not (oYes Is Nothing) Then
                oYes.press
                WScript.Echo "INFO: Confirmed popup " & iPop & " on " & sActPrefix & " (Yes)."
            Else
                Err.Clear
                Set oBtn1 = Nothing
                Set oBtn1 = oSession.findById(sActPrefix & "/usr/btnBUTTON_1")
                If Err.Number = 0 And Not (oBtn1 Is Nothing) Then
                    oBtn1.press
                    WScript.Echo "INFO: Confirmed popup " & iPop & " on " & sActPrefix & " (btnBUTTON_1)."
                Else
                    Err.Clear
                    Set oCont = Nothing
                    Set oCont = oSession.findById(sActPrefix & "/tbar[0]/btn[0]")
                    If Err.Number = 0 And Not (oCont Is Nothing) Then
                        oCont.press
                        WScript.Echo "INFO: Confirmed popup " & iPop & " on " & sActPrefix & " (Continue)."
                    Else
                        Err.Clear
                        oSession.findById(sActPrefix).sendVKey 0   ' Enter
                        WScript.Echo "INFO: Confirmed popup " & iPop & " on " & sActPrefix & " (Enter)."
                    End If
                End If
            End If
            Err.Clear
            On Error GoTo 0
            WScript.Sleep 1200
        End If
    Next
    If iPop > 10 Then
        WScript.Echo "WARN: Popup loop hit cap; SAP may have left a modal on screen."
    End If
End Function
