# fork-publish.ps1 -- one-command fork publish workflow (ASCII only).
#
# What it does (in order):
#   1. stage + commit current changes (optional, message from -Message / -MessageFile)
#   2. push the source branch to the fork remote
#   3. merge the source branch into the integration branch (default fork/main, --no-ff)
#   4. build the mod jar (gradle, proxy fallback)
#   5. refresh the rolling release (tag fork-latest) and the README build block
#      via scripts/fork-release.ps1
#   6. install the jar into the local Mindustry mods directory (optional)
#
# Version numbers are NOT touched here: per the project rule a version bump belongs
# to an upstream PR only (one version per PR). Use scripts/version-bump.ps1 for that.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\fork-publish.ps1 -Message "[a0.13.0.0] fix: ..."
#   powershell -ExecutionPolicy Bypass -File scripts\fork-publish.ps1 -SkipCommit -SkipInstall
#   powershell -ExecutionPolicy Bypass -File scripts\fork-publish.ps1 -DryRun

param(
    [string]$Remote = 'rt334',
    [string]$IntegrationBranch = 'fork/main',
    [string]$SourceBranch = '',
    [string]$Message = '',
    [string]$MessageFile = '',
    [string]$ReleaseRepo = 'rt334/Silicon',
    [string]$Tag = 'fork-latest',
    [string]$ModsDir = '',
    [switch]$SkipCommit,
    [switch]$SkipBuild,
    [switch]$SkipRelease,
    [switch]$SkipReadme,
    [switch]$SkipInstall,
    [switch]$DryRun
)

# Native git/curl calls write progress to stderr; with 'Stop' PowerShell 5.1 turns
# that into a terminating NativeCommandError. Explicit LASTEXITCODE / HTTP checks are used.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $PSScriptRoot 'workflow-lib.ps1')

$startBranch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($SourceBranch -eq '') { $SourceBranch = $startBranch }
Write-Host "[fork-publish] source=$SourceBranch integration=$IntegrationBranch remote=$Remote"

# 1) commit
if (-not $SkipCommit) {
    git add -A
    $staged = git diff --cached --name-only
    if ($staged) {
        if ($Message -eq '' -and $MessageFile -eq '') { throw 'uncommitted changes found: pass -Message or -MessageFile' }
        if ($MessageFile -ne '') { Copy-Item (Get-FullPath $MessageFile) (Get-FullPath 'build/commit-msg.txt') -Force }
        else { Write-Text 'build/commit-msg.txt' $Message }
        if ($DryRun) {
            Write-Host "[fork-publish] dry run: would commit $($staged.Count) file(s)"
        } else {
            git commit -F (Get-FullPath 'build/commit-msg.txt') | Select-Object -First 2
            if ($LASTEXITCODE -ne 0) { throw 'commit failed' }
            Write-Host "[fork-publish] committed: $(git log --oneline -1)"
        }
    } else {
        Write-Host '[fork-publish] nothing to commit (working tree clean)'
    }
}

# 2) push source branch
if (-not $DryRun) {
    Write-Host "[fork-publish] pushing $SourceBranch ..."
    if (-not (Invoke-Push -Ref $SourceBranch -Remote $Remote)) { throw "push of $SourceBranch failed" }
}

# 3) merge into integration branch
if ($SourceBranch -ne $IntegrationBranch) {
    git fetch $Remote --quiet 2>$null
    $exists = git branch --list $IntegrationBranch
    if (-not $exists) {
        Write-Host "[fork-publish] creating $IntegrationBranch from $SourceBranch"
        git branch $IntegrationBranch $SourceBranch
    }
    if ($DryRun) {
        Write-Host "[fork-publish] dry run: would merge $SourceBranch into $IntegrationBranch"
    } else {
        git checkout $IntegrationBranch 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE -ne 0) { throw "cannot checkout $IntegrationBranch" }
        git merge --no-ff $SourceBranch -m "merge: $SourceBranch into $IntegrationBranch" 2>&1 | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) {
            git merge --abort 2>$null
            git checkout $startBranch 2>&1 | Select-Object -Last 1
            throw "merge conflict while merging $SourceBranch into $IntegrationBranch - resolve manually"
        }
        if (-not (Invoke-Push -Ref $IntegrationBranch -Remote $Remote)) { throw "push of $IntegrationBranch failed" }
        Write-Host "[fork-publish] $IntegrationBranch updated: $(git log --oneline -1)"
    }
}

# 4) build
if (-not $SkipBuild) {
    if ($DryRun) {
        Write-Host '[fork-publish] dry run: would run gradle jar'
    } else {
        Write-Host '[fork-publish] building jar ...'
        .\gradlew.bat jar '-Dhttps.proxyHost=127.0.0.1' '-Dhttps.proxyPort=7897' 2>&1 |
            Select-String -Pattern 'BUILD|error:|FAILURE' | Select-Object -First 5
        if ($LASTEXITCODE -ne 0) { throw 'gradle build failed' }
        Get-Item (Get-FullPath 'build/libs/SiliconDesktop.jar') |
            ForEach-Object { Write-Host "[fork-publish] jar: $($_.Length) bytes  $($_.LastWriteTime)" }
    }
}

# 5) release + README
if (-not $SkipRelease -or -not $SkipReadme) {
    $psArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'fork-release.ps1'),
        '-Repo', $ReleaseRepo,
        '-Tag', $Tag,
        '-Branch', $IntegrationBranch,
        '-PushRemote', $Remote
    )
    if ($SkipRelease) { $psArgs += '-SkipRelease' }
    if ($SkipReadme) { $psArgs += '-SkipReadme' }
    if ($DryRun) { $psArgs += '-DryRun' }
    & powershell.exe @psArgs
    if ($LASTEXITCODE -ne 0) { throw 'fork-release step failed' }
}

# 6) install into the game
if (-not $SkipInstall) {
    if ($ModsDir -eq '') { $ModsDir = Join-Path $env:APPDATA 'Mindustry\mods' }
    if (-not (Test-Path $ModsDir)) { $ModsDir = $env:APPDATA }
    $jarPath = Get-FullPath 'build/libs/SiliconDesktop.jar'
    if ($DryRun) {
        Write-Host "[fork-publish] dry run: would install jar to $ModsDir\Silicon.jar"
    } elseif (Test-Path $jarPath) {
        Copy-Item $jarPath (Join-Path $ModsDir 'Silicon.jar') -Force
        Write-Host "[fork-publish] installed jar -> $ModsDir\Silicon.jar"
    }
}

# restore the branch the user started on
if (-not $DryRun -and $SourceBranch -ne $IntegrationBranch) {
    git checkout $startBranch 2>$null | Out-Null
}

Write-Host "[fork-publish] done. version untouched (bump only for upstream PRs via scripts/version-bump.ps1)"

exit 0
