#Requires -Version 5.1
<#
.SYNOPSIS
  For every conflicted file, list the revisions and authors behind the conflict.
.DESCRIPTION
  Read-only. Walks the conflicted entries of a working copy and, for each one,
  reports the incoming revisions between the file's BASE and HEAD together with
  their authors, dates and first log line. Use this to tell the user "who changed
  this file" before asking them how to resolve it.
.PARAMETER Path
  Any path inside the working copy.
.PARAMETER SvnPath
  Explicit svn.exe (use find-svn.ps1 when svn is not on PATH).
.PARAMETER History
  How many revisions of each conflicted file to report (default 10, newest first).
.NOTES
  Exit 0 = reported (possibly zero conflicts), exit 1 = failed.
  Output is one JSON object on stdout (ASCII only).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$SvnPath = 'svn',
    [int]$History = 10
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

if (-not (Get-Command $SvnPath -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $SvnPath)) {
    Fail "svn executable not found: $SvnPath. Run find-svn.ps1 first."
}
if (-not (Test-Path -LiteralPath $Path)) { Fail "path does not exist: $Path" }

$rootRun = Invoke-Svn @('info', '--show-item', 'wc-root', '--non-interactive', $Path)
if ($rootRun.code -ne 0) { Fail (($rootRun.text -split "`n" | Select-Object -First 2) -join ' ') }
$wcRoot = ($rootRun.text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
$rootParts = $wcRoot.TrimEnd('\', '/') -split '[\\/]'

function ConvertTo-Relative {
    param([string]$Full)
    $parts = $Full.TrimEnd('\', '/') -split '[\\/]'
    if ($parts.Count -gt $rootParts.Count) {
        return ($parts[$rootParts.Count..($parts.Count - 1)] -join '/')
    }
    return $Full
}

$statusRun = Invoke-Svn @('status', '--xml', '--non-interactive', $wcRoot)
if ($statusRun.code -ne 0) { Fail $statusRun.text }
try { [xml]$status = $statusRun.text } catch { Fail "cannot parse svn status XML: $($_.Exception.Message)" }

$files = @()
foreach ($entry in @($status.status.target.entry)) {
    if (-not $entry) { continue }
    $item = $entry.'wc-status'.item
    $props = $entry.'wc-status'.props
    if ($item -ne 'conflicted' -and $props -ne 'conflicted') { continue }

    $rel = ConvertTo-Relative $entry.path
    $kind = 'text'
    if ($entry.'wc-status'.'tree-conflict') { $kind = 'tree' }
    elseif ($props -eq 'conflicted') { $kind = 'property' }

    $authors = @()
    # A conflicted file is already at HEAD, so BASE:HEAD would collapse to one revision.
    # Take the newest N revisions of the file instead: that lists everyone who touched it.
    $logRun = Invoke-Svn @('log', '--xml', '-r', 'HEAD:1', '-l', "$History", '--non-interactive', $entry.path)
    if ($logRun.code -eq 0) {
        try {
            [xml]$log = $logRun.text
            foreach ($e in @($log.log.logentry)) {
                if (-not $e) { continue }
                $msg = ''
                if ($e.msg) { $msg = ($e.msg -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim() }
                $authors += [pscustomobject]@{
                    revision = $e.revision
                    author   = $e.author
                    date     = $e.date
                    message  = $msg
                }
            }
        } catch { }
    }

    $lastAuthor = (& $SvnPath info --show-item last-changed-author --non-interactive $entry.path 2>$null | Select-Object -First 1)
    $lastRev = (& $SvnPath info --show-item last-changed-revision --non-interactive $entry.path 2>$null | Select-Object -First 1)

    $files += [pscustomobject]@{
        path                 = $rel
        conflict_type        = $kind
        last_changed_author  = if ($lastAuthor) { $lastAuthor.Trim() } else { $null }
        last_changed_revision = if ($lastRev) { $lastRev.Trim() } else { $null }
        recent_revisions     = @($authors)
        authors              = @($authors | ForEach-Object { $_.author } | Select-Object -Unique)
        log_ok               = ($logRun.code -eq 0)
    }
}

[pscustomobject]@{
    ok             = $true
    wc_root        = $wcRoot
    conflict_count = $files.Count
    files          = $files
} | ConvertTo-Json -Depth 6 -Compress

if ($files.Count -eq 0) { [Console]::Error.WriteLine('No conflicted files in this working copy.') }
exit 0
