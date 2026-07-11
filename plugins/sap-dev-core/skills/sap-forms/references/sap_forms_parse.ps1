# =============================================================================
# sap_forms_parse.ps1  -  offline form parser for /sap-forms explain (NO SAP)
#
# smartform : parse a downloaded SmartForm XML (<SMARTFORM> root) into a node tree
#             (pages / windows / text / code / condition nodes + field references)
#             -> <name>_form_tree.md + <name>_textnodes.tsv.
# sapscript : parse an RSTXSCRP ITF export (line-based /: control format) into
#             windows / paragraph+character formats / text elements.
# Malformed input -> FORMS_EXPORT_INVALID (never a silent success).
# Exit 0 ran, 1 FORMS_EXPORT_INVALID, 2 input error.
# =============================================================================

[CmdletBinding()]
param(
    [string] $Kind = 'smartform',   # smartform | sapscript
    [string] $InFile = '',
    [string] $Name = '',
    [string] $OutDir = ''
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = (Get-Location).Path }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if (-not $Name -and $InFile) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($InFile) }

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $InFile -or -not (Test-Path $InFile)) { Write-Host "STATUS: INPUT_ERROR reason=infile_missing"; exit 2 }

    if ($Kind -eq 'smartform') {
        $xml = $null
        try { $raw = [System.IO.File]::ReadAllText($InFile); $xml = [xml]$raw } catch { Write-Host "STATUS: FORMS_EXPORT_INVALID detail=xml_parse_failed"; exit 1 }
        # SmartForm text-carrying node tags (schema varies; match by local name substrings)
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add("# SmartForm: $Name"); $md.Add(""); $md.Add("Node tree (pages / windows / text / code / condition):"); $md.Add("")
        $tsv = New-Object System.Collections.Generic.List[string]; $tsv.Add("depth`ttag`tname`tkind`tdetail")
        $counts = @{ PAGE=0; WINDOW=0; TEXT=0; CODE=0; COND=0; OTHER=0 }
        function Walk { param($node,[int]$depth)
            if ($node.NodeType -ne 'Element') { return }
            $tag = $node.LocalName
            $nm = ''
            foreach ($an in @('NAME','INAME','FNAME','ID')) { $v=$node.GetAttribute($an); if ($v) { $nm=$v; break } }
            if (-not $nm) { foreach ($cn in @('NAME','INAME')) { $c=$node.SelectSingleNode($cn); if ($c -and $c.InnerText) { $nm=$c.InnerText; break } } }
            $kind='OTHER'
            switch -Regex ($tag.ToUpper()) {
                'PAGE'      { $kind='PAGE' }
                'WINDOW'    { $kind='WINDOW' }
                '^TEXT|TDLINE|ITF' { $kind='TEXT' }
                'CODE|FLOW|PROGRAM' { $kind='CODE' }
                'COND|IF_|CHECK'    { $kind='COND' }
            }
            if ($counts.ContainsKey($kind)) { $counts[$kind]++ }
            if ($kind -in @('PAGE','WINDOW','TEXT','CODE','COND') -or $depth -le 3) {
                $indent = ('  ' * [Math]::Min($depth,8))
                if ($nm -or $kind -ne 'OTHER') { $md.Add("$indent- **$kind** ``$tag`` $nm") }
                $tsv.Add("$depth`t$tag`t$nm`t$kind`t")
            }
            foreach ($ch in $node.ChildNodes) { Walk $ch ($depth+1) }
        }
        Walk $xml.DocumentElement 0
        $md.Add(""); $md.Add("**Summary:** pages=$($counts.PAGE) windows=$($counts.WINDOW) text=$($counts.TEXT) code=$($counts.CODE) condition=$($counts.COND)")
        [System.IO.File]::WriteAllText((Join-Path $OutDir "$($Name)_form_tree.md"), ($md -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $OutDir "$($Name)_textnodes.tsv"), ($tsv -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("PARSE: kind=smartform name=$Name pages=$($counts.PAGE) windows=$($counts.WINDOW) text=$($counts.TEXT) code=$($counts.CODE) cond=$($counts.COND) nodes=$($tsv.Count-1)")
        Write-Host "STATUS: OK"; exit 0
    }
    elseif ($Kind -eq 'sapscript') {
        $lines = [System.IO.File]::ReadAllLines($InFile)
        if ($lines.Count -eq 0) { Write-Host "STATUS: FORMS_EXPORT_INVALID detail=empty_itf"; exit 1 }
        $windows=@(); $paraFmts=@{}; $charFmts=@{}; $elements=@()
        foreach ($ln in $lines) {
            # ITF export control lines: /: WINDOW, /: PARAGRAPH, /* ELEMENT, etc.
            if ($ln -match '^/:\s*WINDOW\s+(\S+)') { $windows += $matches[1] }
            elseif ($ln -match '^/:\s*(?:PARAGRAPH|PA)\s+(\S+)') { $paraFmts[$matches[1]]=$true }
            elseif ($ln -match '^/:\s*(?:CHARACTER|CH)\s+(\S+)') { $charFmts[$matches[1]]=$true }
            elseif ($ln -match '^/E\s+(\S+)|/:\s*ELEMENT\s+(\S+)') { $e=if($matches[1]){$matches[1]}else{$matches[2]}; if($e){$elements+=$e} }
        }
        if ($windows.Count -eq 0 -and $paraFmts.Count -eq 0 -and $elements.Count -eq 0) { Write-Host "STATUS: FORMS_EXPORT_INVALID detail=no_itf_structures (not an RSTXSCRP export?)"; exit 1 }
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add("# SAPscript: $Name"); $md.Add(""); $md.Add("- Windows: $(@($windows | Select-Object -Unique) -join ', ')")
        $md.Add("- Paragraph formats: $(@($paraFmts.Keys | Sort-Object) -join ', ')")
        $md.Add("- Character formats: $(@($charFmts.Keys | Sort-Object) -join ', ')")
        $md.Add("- Text elements: $(@($elements | Select-Object -Unique | Select-Object -First 40) -join ', ')")
        [System.IO.File]::WriteAllText((Join-Path $OutDir "$($Name)_form_tree.md"), ($md -join "`r`n")+"`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("PARSE: kind=sapscript name=$Name windows=$(@($windows|Select-Object -Unique).Count) para=$($paraFmts.Count) char=$($charFmts.Count) elements=$(@($elements|Select-Object -Unique).Count)")
        Write-Host "STATUS: OK"; exit 0
    }
    else { Write-Host "STATUS: INPUT_ERROR reason=unknown_kind"; exit 2 }
}
