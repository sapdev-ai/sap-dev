' =============================================================================
' sap_settings_lib.vbs — settings.json + settings.local.json merge helper.
' =============================================================================
' Two-file model:
'   settings.json         — TRACKED, schema + descriptions + defaults
'   settings.local.json   — GITIGNORED, per-developer values that override
'
' Read path  : merge settings.local.json over settings.json (per-key override
'              of the .value field).
' Write path : ALL writes go to settings.local.json. Never mutate
'              settings.json from a skill.
'
' VBS does not ship a JSON parser; ScriptControl + JScript is used so the
' single dependency is built into Windows. Returned objects are JScript
' objects; access fields with the JScript-style obj.<key>.value indirection.
'
' USAGE (include via ExecuteGlobal):
'
'     ExecuteGlobal FSO.OpenTextFile("<...>\sap_settings_lib.vbs", 1).ReadAll()
'     Dim cfg : Set cfg = GetSapSettings()
'     Dim pwd : pwd = GetSapSettingValue("sap_password", "")
'     Call SetSapUserSetting("sap_password", "dpapi:...")
' =============================================================================

Dim g_SapSettingsCache       : Set g_SapSettingsCache = Nothing
Dim g_SapSettingsLocalPath   : g_SapSettingsLocalPath  = ""
Dim g_SapSettingsMainPath    : g_SapSettingsMainPath   = ""
Dim g_SapSettingsScriptDir   : g_SapSettingsScriptDir  = ""
Dim g_SapSettingsJscript     : Set g_SapSettingsJscript = Nothing

Sub _SapSettings_Init(sScriptPath)
    If g_SapSettingsMainPath <> "" Then Exit Sub
    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    g_SapSettingsScriptDir = oFSO.GetParentFolderName(sScriptPath)
    Dim sCoreRoot : sCoreRoot = oFSO.GetParentFolderName(oFSO.GetParentFolderName(g_SapSettingsScriptDir))
    g_SapSettingsMainPath  = oFSO.BuildPath(sCoreRoot, "settings.json")
    g_SapSettingsLocalPath = oFSO.BuildPath(sCoreRoot, "settings.local.json")

    Set g_SapSettingsJscript = CreateObject("ScriptControl")
    g_SapSettingsJscript.Language = "JScript"
    g_SapSettingsJscript.AddCode "function _parse(s){return s?eval('('+s+')'):{};} " & _
                                 "function _stringify(o){return JSON.stringify(o,null,2);} " & _
                                 "function _ensureUC(o){if(!o.userConfig){o.userConfig={};}return o;} " & _
                                 "function _mergeValue(main,key,localEntry){" & _
                                 "  if(!localEntry)return;" & _
                                 "  if(main.userConfig[key]){" & _
                                 "    if(localEntry.value!==undefined){main.userConfig[key].value=localEntry.value;}" & _
                                 "  } else {main.userConfig[key]=localEntry;}" & _
                                 "}" & _
                                 "function _mergeAll(main,local){" & _
                                 "  _ensureUC(main); if(!local||!local.userConfig)return main;" & _
                                 "  for(var k in local.userConfig){_mergeValue(main,k,local.userConfig[k]);}" & _
                                 "  return main;" & _
                                 "}" & _
                                 "function _setVal(local,key,val){" & _
                                 "  _ensureUC(local);" & _
                                 "  if(local.userConfig[key]){local.userConfig[key].value=val;}" & _
                                 "  else{local.userConfig[key]={value:val};}" & _
                                 "  return local;" & _
                                 "}"
End Sub

Function _SapSettings_ReadFile(sPath)
    Dim oFSO : Set oFSO = CreateObject("Scripting.FileSystemObject")
    If Not oFSO.FileExists(sPath) Then
        _SapSettings_ReadFile = ""
        Exit Function
    End If
    Dim oStream : Set oStream = CreateObject("ADODB.Stream")
    oStream.Type = 2 : oStream.Charset = "utf-8" : oStream.Open
    oStream.LoadFromFile sPath
    _SapSettings_ReadFile = oStream.ReadText
    oStream.Close
End Function

Sub _SapSettings_WriteFile(sPath, sText)
    Dim oStream : Set oStream = CreateObject("ADODB.Stream")
    oStream.Type = 2 : oStream.Charset = "utf-8" : oStream.Open
    oStream.WriteText sText
    ' Strip the BOM ADODB writes by default (Position 3 then SaveToFile binary).
    oStream.Position = 0
    Dim oBin : Set oBin = CreateObject("ADODB.Stream")
    oBin.Type = 1 : oBin.Open
    oStream.CopyTo oBin
    oStream.Close
    oBin.Position = 3 ' skip UTF-8 BOM
    Dim oOut : Set oOut = CreateObject("ADODB.Stream")
    oOut.Type = 1 : oOut.Open
    oBin.CopyTo oOut
    oBin.Close
    oOut.SaveToFile sPath, 2 ' overwrite
    oOut.Close
End Sub

Sub ResetSapSettingsCache()
    Set g_SapSettingsCache = Nothing
End Sub

Function GetSapSettings()
    If Not g_SapSettingsCache Is Nothing Then
        Set GetSapSettings = g_SapSettingsCache
        Exit Function
    End If
    _SapSettings_Init WScript.ScriptFullName

    Dim sMain  : sMain  = _SapSettings_ReadFile(g_SapSettingsMainPath)
    Dim sLocal : sLocal = _SapSettings_ReadFile(g_SapSettingsLocalPath)

    Dim oMain  : Set oMain  = g_SapSettingsJscript.Run("_parse", sMain)
    Dim oLocal : Set oLocal = g_SapSettingsJscript.Run("_parse", sLocal)
    Dim oMerged : Set oMerged = g_SapSettingsJscript.Run("_mergeAll", oMain, oLocal)

    Set g_SapSettingsCache = oMerged
    Set GetSapSettings = oMerged
End Function

Function GetSapSettingValue(sKey, sDefault)
    Dim cfg : Set cfg = GetSapSettings()
    On Error Resume Next
    Dim entry : Set entry = cfg.userConfig.Item(sKey)
    If Err.Number <> 0 Then Err.Clear : entry = Empty
    On Error Goto 0
    If IsEmpty(entry) Or IsNull(entry) Or entry Is Nothing Then
        GetSapSettingValue = sDefault
        Exit Function
    End If
    Dim v : v = entry.value
    If IsNull(v) Or IsEmpty(v) Or v = "" Then
        GetSapSettingValue = sDefault
    Else
        GetSapSettingValue = CStr(v)
    End If
End Function

Sub SetSapUserSetting(sKey, sValue)
    _SapSettings_Init WScript.ScriptFullName
    Dim sLocal : sLocal = _SapSettings_ReadFile(g_SapSettingsLocalPath)
    Dim oLocal : Set oLocal = g_SapSettingsJscript.Run("_parse", sLocal)
    Dim oUpdated : Set oUpdated = g_SapSettingsJscript.Run("_setVal", oLocal, sKey, sValue)
    Dim sJson : sJson = g_SapSettingsJscript.Run("_stringify", oUpdated)
    _SapSettings_WriteFile g_SapSettingsLocalPath, sJson
    ResetSapSettingsCache
End Sub
