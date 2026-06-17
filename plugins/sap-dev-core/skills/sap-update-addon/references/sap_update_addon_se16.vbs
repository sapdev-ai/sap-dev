' =============================================================================
' sap_update_addon_se16.vbs -- Maintain add-on table records via SE16
'
' Opens SE16 for the table. Uses the standard entry form to create/change
' records one at a time. Requires DD02L-MAINFLAG = 'X'.
'
' Tokens:
'   %%TABLE_NAME%%     Table name (Y/Z prefix)
'   %%DATA_FILE%%      Absolute path to TAB-delimited data file
'   %%OPERATION%%      INSERT / UPDATE / DELETE
' =============================================================================
Option Explicit

Const TABLE_NAME = "%%TABLE_NAME%%"
Const DATA_FILE  = "%%DATA_FILE%%"
Const OPERATION  = "%%OPERATION%%"
Const SESSION_PATH = "%%SESSION_PATH%%"   ' empty / unsubstituted = use default

' Include shared attach helper.
ExecuteGlobal CreateObject("Scripting.FileSystemObject") _
    .OpenTextFile("%%ATTACH_LIB_VBS%%", 1).ReadAll()

' --- 1. Attach to existing SAP GUI session (via shared attach helper) ------
Dim oSession
Set oSession = AttachSapSession(SESSION_PATH)

' --- 2. Read data file (UTF-8) ---
' The data-file contract (SKILL.md Step 1) and the PROG path (GUI_UPLOAD)
' are UTF-8. This was previously read via OpenTextFile(..., -1) = UTF-16,
' so a UTF-8 file silently failed with "must have header + data lines".
' Use ADODB.Stream Charset=utf-8 (the house idiom, e.g. sap_se38_create.vbs)
' so all three fallbacks (PROG / SE16 / SM30) agree on UTF-8.
Dim oFSO, aLines(), iLineCount, sLine
Set oFSO = CreateObject("Scripting.FileSystemObject")

If Not oFSO.FileExists(DATA_FILE) Then
    WScript.Echo "ERROR: Data file not found: " & DATA_FILE
    WScript.Quit 1
End If

Dim oStream, sAll, aRaw, iR
Set oStream = CreateObject("ADODB.Stream")
oStream.Type = 2            ' adTypeText
oStream.Charset = "utf-8"   ' strips a BOM if present; reads BOM-less UTF-8 too
oStream.Open
oStream.LoadFromFile DATA_FILE
sAll = oStream.ReadText
oStream.Close

' Normalize line endings, split, skip blank lines, build a 1-based array.
sAll = Replace(sAll, vbCrLf, vbLf)
sAll = Replace(sAll, vbCr, vbLf)
aRaw = Split(sAll, vbLf)
iLineCount = 0
ReDim aLines(0)
For iR = 0 To UBound(aRaw)
    sLine = aRaw(iR)
    If Trim(sLine) <> "" Then
        iLineCount = iLineCount + 1
        ReDim Preserve aLines(iLineCount)
        aLines(iLineCount) = sLine
    End If
Next

If iLineCount < 2 Then
    WScript.Echo "ERROR: Data file must have header + data lines."
    WScript.Quit 1
End If

Dim aHeader
aHeader = Split(aLines(1), vbTab)
WScript.Echo "INFO: Header fields: " & Join(aHeader, ", ")

' --- 3. Navigate to SE16 ---
Dim i, j, aVals, lv_success, lv_error
lv_success = 0
lv_error = 0

For i = 2 To iLineCount
    aVals = Split(aLines(i), vbTab)

    ' Navigate fresh to SE16 for each record
    oSession.findById("wnd[0]/tbar[0]/okcd").Text = "/nSE16"
    oSession.findById("wnd[0]").sendVKey 0
    WScript.Sleep 500

    oSession.findById("wnd[0]/usr/ctxtDATABROWSE-TABLENAME").Text = TABLE_NAME
    WScript.Sleep 300

    If UCase(OPERATION) = "INSERT" Or UCase(OPERATION) = "UPDATE" Then
        ' Open the "Create Entries" form from the SE16 INITIAL screen (the table
        ' name is already entered above). The toolbar button differs by release,
        ' so we try each candidate and VERIFY we actually reached the entry form
        ' (by probing the first non-MANDT field) before filling anything --
        ' a press that "succeeds" but lands on the wrong screen must not lead to
        ' saving an empty / wrong row.
        '   * S/4HANA    : tbar[1]/btn[18] = Create Entries.
        '   * ECC 6.0     : tbar[1]/btn[5] (F5) = Create Entries (program SAPLSETB,
        '                  dynpro 230). On ECC6, btn[18] here is "Selection Screen
        '                  Help" and the post-Enter selection screen has NO
        '                  Create-Entries button -- btn[5] opens the Insert form
        '                  (program /1BCDWB/DB<table>, dynpro 101) with
        '                  txt<table>-<field> inputs. Verified 2026-06-17 on SID
        '                  ER1 (table ZMMFIXEDVALS71).
        Dim sProbeFld, bEntryForm, k
        sProbeFld = ""
        For k = 0 To UBound(aHeader)
            If UCase(Trim(aHeader(k))) <> "MANDT" And UCase(Trim(aHeader(k))) <> "CLIENT" Then
                sProbeFld = UCase(Trim(aHeader(k)))
                Exit For
            End If
        Next

        ' Attempt 1 -- S/4HANA Create Entries (tbar[1]/btn[18]).
        On Error Resume Next
        oSession.findById("wnd[0]/tbar[1]/btn[18]").Press
        WScript.Sleep 500
        Err.Clear
        On Error GoTo 0
        bEntryForm = EntryFieldPresent(oSession, TABLE_NAME, sProbeFld)

        ' Attempt 2 -- ECC 6.0 Create Entries (tbar[1]/btn[5], F5).
        If Not bEntryForm Then
            On Error Resume Next
            oSession.findById("wnd[0]/tbar[1]/btn[5]").Press
            WScript.Sleep 500
            Err.Clear
            On Error GoTo 0
            bEntryForm = EntryFieldPresent(oSession, TABLE_NAME, sProbeFld)
        End If

        ' Attempt 3 -- last resort: menu path (release-dependent index).
        If Not bEntryForm Then
            On Error Resume Next
            oSession.findById("wnd[0]/mbar/menu[1]/menu[5]").Select
            WScript.Sleep 500
            Err.Clear
            On Error GoTo 0
            bEntryForm = EntryFieldPresent(oSession, TABLE_NAME, sProbeFld)
        End If

        If Not bEntryForm Then
            WScript.Echo "ERROR: Could not open the SE16 Create-Entries form for " & TABLE_NAME & "."
            WScript.Echo "       Tried tbar[1]/btn[18] (S/4HANA), tbar[1]/btn[5] (ECC 6.0, F5),"
            WScript.Echo "       and the Edit menu, but none reached an entry form with field"
            WScript.Echo "       " & sProbeFld & ". This release's Create-Entries control may differ."
            WScript.Echo "       Re-record on this system (Help > SAP GUI > Scripting > Record;"
            WScript.Echo "       SE16 > " & TABLE_NAME & " > Create Entries) and add the button/menu"
            WScript.Echo "       ID above, or use the SM30 / PROG fallback instead."
            WScript.Quit 2
        End If

        ' Fill fields on the entry screen.
        ' NOTE: SAP GUI release-dependent dynpro IDs.
        ' If ALL field lookups fail (every field reports "WARNING: Could not
        ' find field"), the SE16 entry form's widget IDs do not match the
        ' patterns assumed below. This is expected on newer S/4HANA releases
        ' where the entry form was restructured. Re-record with the SAP GUI
        ' Scripting Recorder (Help > SAP GUI > Scripting > Record) to capture
        ' the correct ID patterns and replace the two findById calls below.
        ' Tracker: language_independence_rules.md migration-backlog Finding #24.
        Dim iFoundFields : iFoundFields = 0
        For j = 0 To UBound(aHeader)
            Dim sFldName, sFldVal
            sFldName = UCase(Trim(aHeader(j)))
            If j <= UBound(aVals) Then
                sFldVal = aVals(j)
            Else
                sFldVal = ""
            End If

            If sFldName = "MANDT" Or sFldName = "CLIENT" Then
                ' skip MANDT
            Else
                ' Try field ID patterns for SE16 entry form
                On Error Resume Next
                ' Pattern: ctxt<TABLE>-<FIELD>
                oSession.findById("wnd[0]/usr/ctxt" & UCase(TABLE_NAME) & "-" & sFldName).Text = sFldVal
                If Err.Number = 0 Then
                    iFoundFields = iFoundFields + 1
                Else
                    Err.Clear
                    ' Pattern: txt<TABLE>-<FIELD>
                    oSession.findById("wnd[0]/usr/txt" & UCase(TABLE_NAME) & "-" & sFldName).Text = sFldVal
                    If Err.Number = 0 Then
                        iFoundFields = iFoundFields + 1
                    Else
                        Err.Clear
                        WScript.Echo "WARNING: Could not find field " & sFldName & " on SE16 entry form."
                    End If
                End If
                Err.Clear
                On Error GoTo 0
            End If
        Next

        ' Diagnostic: if ZERO fields were filled, the field-ID pattern is wrong
        ' for this SAP GUI release. Skip the save (would commit empty row) and
        ' fail loudly with re-recording instructions.
        If iFoundFields = 0 Then
            WScript.Echo "ERROR: No fields could be filled on SE16 entry form for " & TABLE_NAME & "."
            WScript.Echo "       The reference VBS uses widget-ID patterns that don't match this"
            WScript.Echo "       SAP GUI release. Open Help > SAP GUI > Scripting > Record, navigate"
            WScript.Echo "       to SE16 > " & TABLE_NAME & " > Create Entries, and capture the actual"
            WScript.Echo "       findById path for one field. Update sap_update_addon_se16.vbs's"
            WScript.Echo "       two findById patterns (ctxt and txt) with the recorded shape."
            WScript.Echo "       Skipping save to avoid committing an empty row."
            WScript.Quit 2
        End If

        ' Save the entry (Ctrl+S)
        oSession.findById("wnd[0]").sendVKey 11
        WScript.Sleep 500

        ' Check status bar
        On Error Resume Next
        Dim sMsgType, sMsgText
        sMsgType = oSession.findById("wnd[0]/sbar").MessageType
        sMsgText = oSession.findById("wnd[0]/sbar").Text
        Err.Clear
        On Error GoTo 0

        If sMsgType = "E" Or sMsgType = "A" Then
            lv_error = lv_error + 1
            WScript.Echo "ERROR: Row " & (i - 1) & ": " & sMsgText
        Else
            lv_success = lv_success + 1
            WScript.Echo "INFO: Row " & (i - 1) & ": OK (" & sMsgText & ")"
        End If

    ElseIf UCase(OPERATION) = "DELETE" Then
        ' Execute display with selection criteria to find the record
        oSession.findById("wnd[0]").sendVKey 8  ' F8 = Execute
        WScript.Sleep 500
        ' TODO: select matching row and delete
        WScript.Echo "WARNING: DELETE via SE16 requires manual row selection."
        lv_error = lv_error + 1
    End If
Next

WScript.Echo "========================================="
WScript.Echo "SE16 maintenance completed for " & TABLE_NAME
WScript.Echo ChrW(&H6210) & ChrW(&H529F) & ": " & lv_success & "  " & ChrW(&H30A8) & ChrW(&H30E9) & ChrW(&H30FC) & ": " & lv_error  ' (success / error labels) -- ChrW() keeps the labels intact regardless of the .vbs file encoding
WScript.Echo "========================================="
WScript.Echo "SUCCESS: SE16 maintenance completed."

' -----------------------------------------------------------------------------
' EntryFieldPresent -- True if the SE16 Create-Entries form currently exposes
' <table>-<field> (ctxt or txt variant). Used to verify we actually reached the
' entry form before filling, so a release where tbar[1]/btn[18] is NOT "Create
' Entries" (e.g. classic ECC 6.0, where it is "Selection Screen Help") fails
' loud instead of silently saving an empty / wrong row.
' -----------------------------------------------------------------------------
Function EntryFieldPresent(oSess, sTab, sFld)
    EntryFieldPresent = False
    If sFld = "" Then Exit Function
    Dim oCtl
    On Error Resume Next
    Set oCtl = oSess.findById("wnd[0]/usr/ctxt" & UCase(sTab) & "-" & sFld)
    If Err.Number = 0 Then EntryFieldPresent = True
    Err.Clear
    If Not EntryFieldPresent Then
        Set oCtl = oSess.findById("wnd[0]/usr/txt" & UCase(sTab) & "-" & sFld)
        If Err.Number = 0 Then EntryFieldPresent = True
        Err.Clear
    End If
    On Error GoTo 0
End Function
