# version-bump.ps1 -- Silicon version bump helper (ASCII only on purpose:
# PowerShell 5.1 fails to parse .ps1 files containing non-ASCII text in some
# console codepages. All localized strings live in scripts/workflow-strings.json).
#
# Version format: a0.X.Y.Z
#   -Type block   -> a0.(X+1).0.0   (block added/changed: major digit +1, rest reset)
#   -Type feature -> a0.X.(Y+1).0   (feature only: minor digit +1, patch reset)
#   -Type bug     -> a0.X.Y.(Z+1)   (bug fix: patch digit +1)
#
# Rule: the version number is bumped ONLY when preparing a PR against the main
# repository (SiliconMod/Silicon). One PR = one version. Fork-only commits keep
# the current version untouched.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type feature
#   powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type block -EntryFile build\entry.md
#   powershell -ExecutionPolicy Bypass -File scripts\version-bump.ps1 -Type bug -DryRun

param(
    [Parameter(Mandatory = $true)][ValidateSet('block', 'feature', 'bug')][string]$Type,
    [string]$ModFile = 'mod.hjson',
    [string]$ReadmeFile = 'README.md',
    [string]$StringsFile = 'scripts/workflow-strings.json',
    [string]$EntryFile = '',
    [switch]$DryRun,
    [switch]$NoReadme
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-FullPath([string]$path) {
    if ([IO.Path]::IsPathRooted($path)) { return $path }
    return (Join-Path (Get-Location).Path $path)
}

function Read-Text([string]$path) {
    $full = Get-FullPath $path
    if (-not (Test-Path $full)) { throw "file not found: $path" }
    return [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
}

function Write-Text([string]$path, [string]$text) {
    [IO.File]::WriteAllText((Get-FullPath $path), $text, $Utf8NoBom)
}

$modText = Read-Text $ModFile
$m = [regex]::Match($modText, '(?m)^version:\s*a0\.(\d+)\.(\d+)\.(\d+)\s*$')
if (-not $m.Success) { throw "cannot parse version from $ModFile (expected: version: a0.X.Y.Z)" }

$X = [int]$m.Groups[1].Value
$Y = [int]$m.Groups[2].Value
$Z = [int]$m.Groups[3].Value
$old = "a0.$X.$Y.$Z"

switch ($Type) {
    'block' { $X = $X + 1; $Y = 0; $Z = 0 }
    'feature' { $Y = $Y + 1; $Z = 0 }
    'bug' { $Z = $Z + 1 }
}
$new = "a0.$X.$Y.$Z"

Write-Host "[version-bump] type=$Type  $old -> $new"

if ($DryRun) {
    Write-Host '[version-bump] dry run: nothing written'
    exit 0
}

$newModText = $modText.Remove($m.Index, $m.Length).Insert($m.Index, "version: $new")
Write-Text $ModFile $newModText

if (-not $NoReadme -and (Test-Path $ReadmeFile)) {
    $strings = (Read-Text $StringsFile) | ConvertFrom-Json
    $readme = Read-Text $ReadmeFile

    $entryLines = @()
    if ($EntryFile -ne '' -and (Test-Path $EntryFile)) {
        $entryLines = (Read-Text $EntryFile) -split "`r?`n"
    } else {
        $entryLines = @($strings.placeholderBullet)
    }

    $heading = "### $new" + $strings.latestSuffix
    $block = (@($heading) + $entryLines) -join "`n"

    # newest existing entry: first '### a0.' heading
    $head = [regex]::Match($readme, '(?m)^### a0\.\d+\.\d+\.\d+.*$')
    if ($head.Success) {
        # drop the "latest" suffix from the previous newest entry
        $oldHeading = $head.Value
        $cleaned = $oldHeading.Replace([string]$strings.latestSuffix, '')
        $readme = $readme.Remove($head.Index, $head.Length).Insert($head.Index, $block + "`n`n" + $cleaned)
    } else {
        # no existing version entry: append at the end
        $readme = $readme.TrimEnd() + "`n`n" + $block + "`n"
    }
    Write-Text $ReadmeFile $readme
    Write-Host "[version-bump] README updated: new entry '$new' inserted, previous entry suffix cleaned"
}

Write-Host "[version-bump] done. Remember: this bump belongs to an upstream PR (one version per PR)."
