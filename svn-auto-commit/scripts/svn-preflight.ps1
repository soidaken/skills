#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only SVN preflight for a working copy: local changes, incoming changes, conflicts.
.DESCRIPTION
  Runs svn info / svn status --xml / svn status -u --xml and parses the XML, so the
  output does not depend on console locale or column layout. It never updates,
  resolves or commits, so it is safe to run before telling the user what will be committed.
.PARAMETER Path
  Any path inside the working copy (file or directory).
.PARAMETER SvnPath
  Explicit svn.exe (use find-svn.ps1 when svn is not on PATH).
.NOTES
  Exit 0 = inspected, exit 1 = failed. Output is one JSON object on stdout (ASCII only).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$SvnPath = 'svn'
)

$ErrorActionPreference = 'Continue'

function Fail {
    param([string]$Message)
    [pscustomobject]@{ ok = $false; error = $Message } | ConvertTo-Json -Compress
    exit 1
}

function Invoke-Svn {
    param([string[]]$SvnArgs)
    $out = & $SvnPath @SvnArgs 2>&1
    [pscustomobject]@{ code = $LASTEXITCODE; text = (@($out) -join "`n") }
}

function Get-InfoItem {
    param([string]$Item)
    $r = Invoke-Svn @('info', '--non-interactive', '--show-item', $Item, $Path)
    if ($r.code -ne 0) { return $null }
    return ($r.text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
}

if (-not (Get-Command $SvnPath -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $SvnPath)) {
    Fail "svn executable not found: $SvnPath. Run find-svn.ps1 first."
}
if (-not (Test-Path -LiteralPath $Path)) { Fail "path does not exist: $Path" }

$wcRoot = Get-InfoItem 'wc-root'
if (-not $wcRoot) {
    $r = Invoke-Svn @('info', '--non-interactive', $Path)
    Fail (($r.text -split "`n" | Select-Object -First 3) -join ' ')
}
# Ask for the wc-root url: $Path may be a file, which would yield a file url.
$url = (& $SvnPath info --show-item url --non-interactive $wcRoot 2>$null | Select-Object -First 1)
if ($url) { $url = $url.Trim() }
$rev = Get-InfoItem 'revision'
$rootParts = $wcRoot.TrimEnd('\', '/') -split '[\\/]'

function ConvertTo-Relative {
    param([string]$Full)
    $parts = $Full.TrimEnd('\', '/') -split '[\\/]'
    if ($parts.Count -gt $rootParts.Count) {
        return ($parts[$rootParts.Count..($parts.Count - 1)] -join '/')
    }
    return $Full
}

# Local changes (no network).
$localRun = Invoke-Svn @('status', '--xml', '--non-interactive', $wcRoot)
if ($localRun.code -ne 0) { Fail $localRun.text }
try { [xml]$localXml = $localRun.text } catch { Fail "cannot parse svn status XML: $($_.Exception.Message)" }

# Incoming changes: adds <repos-status> to each entry. Still read-only.
$remoteRun = Invoke-Svn @('status', '-u', '--xml', '--non-interactive', $wcRoot)
$remoteOk = $false
$remoteXml = $null
if ($remoteRun.code -eq 0) {
    try { [xml]$remoteXml = $remoteRun.text; $remoteOk = $true } catch { $remoteOk = $false }
}

$localChanges = @()
$unversioned = @()
$conflicted = @()
$treeConflicted = @()
foreach ($entry in @($localXml.status.target.entry)) {
    if (-not $entry) { continue }
    $rel = ConvertTo-Relative $entry.path
    $item = $entry.'wc-status'.item
    $props = $entry.'wc-status'.props
    if ($item -eq 'unversioned' -or $item -eq 'ignored') { $unversioned += $rel; continue }
    if ($item -eq 'normal') { continue }
    $localChanges += [pscustomobject]@{ status = $item; props = $props; path = $rel }
    if ($item -eq 'conflicted' -or $props -eq 'conflicted') { $conflicted += $rel }
    if ($entry.'wc-status'.'tree-conflict') { $treeConflicted += $rel }
}

$remotePending = @()
$against = $null
if ($remoteOk) {
    foreach ($entry in @($remoteXml.status.target.entry)) {
        if (-not $entry) { continue }
        # repos-status is a sibling of wc-status, not a child of it.
        if ($entry.'repos-status') {
            $remotePending += [pscustomobject]@{
                repos_status = $entry.'repos-status'.item
                props        = $entry.'repos-status'.props
                path         = (ConvertTo-Relative $entry.path)
            }
        }
    }
    if ($remoteXml.status.target.against) { $against = $remoteXml.status.target.against.revision }
}

[pscustomobject]@{
    ok               = $true
    wc_root          = $wcRoot
    url              = $url
    revision         = $rev
    against          = $against
    local_changes    = $localChanges
    unversioned      = @($unversioned | Select-Object -Unique)
    conflicted       = @($conflicted | Select-Object -Unique)
    tree_conflicted  = @($treeConflicted | Select-Object -Unique)
    remote_pending   = @($remotePending)
    remote_check_ok  = $remoteOk
    remote_check_err = if ($remoteOk) { $null } else { ($remoteRun.text -split "`n" | Select-Object -First 2) -join ' ' }
} | ConvertTo-Json -Depth 5 -Compress

if (-not $localChanges -and -not $unversioned) {
    [Console]::Error.WriteLine('Nothing to commit in this working copy.')
}
exit 0
