#Requires -Version 5.1
<#
.SYNOPSIS
  Locate a working svn.exe and report its version. Read-only.
.NOTES
  Probes PATH and the standard install locations on every fixed drive
  (SlikSVN, TortoiseSVN, VisualSVN, Apache), so a svn on D:/E: is still found.
  Exit 0 = usable, exit 1 = not found.
  Output is a single JSON object on stdout (ASCII only, safe for any console codepage).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Resolve-SvnVersion {
    param([string]$Exe)
    try {
        $v = & $Exe --version --quiet 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return ($v | Select-Object -First 1).Trim() }
    } catch { }
    return $null
}

$found = @()

# 1) PATH first: that is what the agent will actually invoke.
$onPath = Get-Command svn.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($onPath) {
    $found += [pscustomobject]@{ path = $onPath.Source; source = 'PATH'; on_path = $true }
}

# 2) Well-known install roots (SlikSVN / TortoiseSVN / VisualSVN / Apache).
$subPaths = @(
    'SlikSvn\bin\svn.exe'
    'TortoiseSVN\bin\svn.exe'
    'VisualSVN Server\bin\svn.exe'
    'Apache Subversion\bin\svn.exe'
    'Subversion\bin\svn.exe'
)

$roots = New-Object System.Collections.Generic.List[string]
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if ($base) { $roots.Add($base) }
}

# svn is often installed on a data drive, so probe every fixed drive too.
foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null })) {
    foreach ($folder in @('Program Files', 'Program Files (x86)', 'Soft', 'Software', 'Apps')) {
        $candidate = Join-Path $drive.Root $folder
        if (Test-Path -LiteralPath $candidate) { $roots.Add($candidate) }
    }
}

foreach ($root in ($roots | Select-Object -Unique)) {
    foreach ($sub in $subPaths) {
        $exe = Join-Path $root $sub
        if (Test-Path -LiteralPath $exe) {
            $found += [pscustomobject]@{ path = $exe; source = 'install-dir'; on_path = $false }
        }
    }
}

# 3) De-duplicate, keep the first usable binary.
$result = $null
foreach ($item in $found) {
    $version = Resolve-SvnVersion -Exe $item.path
    if ($version) {
        $result = [pscustomobject]@{
            svn_path    = $item.path
            svn_version = $version
            source      = $item.source
            on_path     = [bool]$item.on_path
        }
        break
    }
}

if (-not $result) {
    [pscustomobject]@{
        svn_path    = $null
        svn_version = $null
        source      = 'not-found'
        on_path     = $false
    } | ConvertTo-Json -Compress
    exit 1
}

$result | ConvertTo-Json -Compress
if (-not $result.on_path) {
    [Console]::Error.WriteLine("svn exists but is not on PATH. Use the absolute path above, or add $(Split-Path $result.svn_path) to PATH.")
}
exit 0
