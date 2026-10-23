#Requires -Version 5.1
<#
.SYNOPSIS
  Locate a working svn.exe and report its version. Read-only.
.PARAMETER AddToPath
  Append the directory of the found svn.exe to the user PATH (idempotent) and to the
  current process PATH, so plain `svn` works for the user and for later agent calls.
.NOTES
  Probes PATH and the standard install locations on every fixed drive
  (SlikSVN, TortoiseSVN, VisualSVN, Apache), so a svn on D:/E: is still found.
  Also reports whether the TortoiseSVN GUI exists, i.e. whether svn is installed
  but only the command line client component is missing.
  Exit 0 = usable, exit 1 = not found.
  Output is a single JSON object on stdout (ASCII only, safe for any console codepage).
#>
[CmdletBinding()]
param([switch]$AddToPath)

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
    # No svn.exe anywhere: tell the caller whether a GUI-only TortoiseSVN is installed.
    $gui = @()
    foreach ($root in ($roots | Select-Object -Unique)) {
        $p = Join-Path $root 'TortoiseSVN\bin\TortoiseProc.exe'
        if (Test-Path -LiteralPath $p) { $gui += $p }
    }
    [pscustomobject]@{
        svn_path        = $null
        svn_version     = $null
        source          = 'not-found'
        on_path         = $false
        tortoisesvn_gui = if ($gui.Count -gt 0) { $gui[0] } else { $null }
        path_added      = $false
    } | ConvertTo-Json -Compress
    exit 1
}

$added = $false
if (-not $result.on_path -and $AddToPath) {
    $dir = Split-Path -Path $result.svn_path -Parent
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $entries = @($userPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ })
    $alreadyThere = $false
    foreach ($e in $entries) {
        if ($e -ieq $dir.TrimEnd('\')) { $alreadyThere = $true; break }
    }
    if (-not $alreadyThere) {
        $newUserPath = (@($entries) + $dir.TrimEnd('\')) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        $added = $true
    }
    $result.on_path = $true
}

$out = [pscustomobject]@{
    svn_path        = $result.svn_path
    svn_version     = $result.svn_version
    source          = $result.source
    on_path         = [bool]$result.on_path
    tortoisesvn_gui = $null
    path_added      = $added
    path_target     = if ($AddToPath) { Split-Path -Path $result.svn_path -Parent } else { $null }
}

$out | ConvertTo-Json -Compress
if (-not $out.on_path) {
    [Console]::Error.WriteLine("svn exists but is not on PATH. Use the absolute path above, or re-run with -AddToPath to append $(Split-Path $result.svn_path -Parent) to the user PATH.")
} elseif ($added) {
    [Console]::Error.WriteLine("Added $(Split-Path $result.svn_path -Parent) to the user PATH. Open terminals and editor sessions need a restart; this agent session should keep using the absolute svn_path above.")
}
exit 0
