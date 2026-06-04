' =============================================================================
' sap_update_addon_se16.vbs — Maintain add-on table records via SE16
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

' --- 2. Read data file ---
Dim oFSO, oFile, sLine, aLines(), iLineCount
Set oFSO = CreateObject("Scripting.FileSystemObject")

If Not oFSO.FileExists(DATA_FILE) Then
    WScript.Echo "ERROR: Data file not found: " & DATA_FILE
    WScript.Quit 1
End If

Set oFile = oFSO.OpenTextFile(DATA_FILE, 1, False, -1)
iLineCount = 0
ReDim aLines(0)
Do While Not oFile.AtEndOfStream
    sLine = oFile.ReadLine
    If Trim(sLine) <> "" Then
        iLineCount = iLineCount + 1
        ReDim Preserve aLines(iLineCount)
        aLines(iLineCount) = sLine
    End If
Loop
oFile.Close

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
        ' Press "Create Entries" button (toolbar or menu Table > Create Entries)
        On Error Resume Next
        oSession.findById("wnd[0]/tbar[1]/btn[18]").Press  ' Create Entries
        WScript.Sleep 500
        If Err.Number <> 0 Then
            Err.Clear
            ' Try menu: Table > Create Entry
            oSession.findById("wnd[0]/mbar/menu[1]/menu[5]").Select
            WScript.Sleep 500
        End If
        Err.Clear
        On Error GoTo 0

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
WScript.Echo ChrW(&H6210) & ChrW(&H529F) & ": " & lv_success & "  " & ChrW(&H30A8) & ChrW(&H30E9) & ChrW(&H30FC) & ": " & lv_error  ' 成功 / エラー (success / error) -- ChrW() keeps the labels intact regardless of the .vbs file encoding
WScript.Echo "========================================="
WScript.Echo "SUCCESS: SE16 maintenance completed."
