# track-forks.ps1 -- track other developers' Silicon forks: sync their branches
# locally, download their release jars, or build a jar from their source, so any
# of them can be dropped into the game for local testing. ASCII only (see
# version-bump.ps1 header); localized text lives in scripts/tracked-forks.json.
#
# Repository list: scripts/tracked-forks.json  (name / repo / branch / remote / label)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1                 # sync + status table
#   powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action list    # status only (no fetch)
#   powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action jar   -Name arc
#   powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action build -Name arc
#   powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action install -Name arc
#   powershell -ExecutionPolicy Bypass -File scripts\track-forks.ps1 -Action diff  -Name arc
#
# Notes:
#   - Tracking branches live only on this machine as <prefix><name> (default track/<name>).
#     Other people's code is deliberately NOT mirrored into our fork (no upstream license).
#   - 'build' uses a throwaway git worktree, so your current working tree is never touched.
#   - 'install' backs up the current mods jar first.

param(
    [ValidateSet('sync', 'list', 'jar', 'build', 'install', 'diff')][string]$Action = 'sync',
    [string]$Name = '',
    [string]$ConfigFile = 'scripts/tracked-forks.json',
    [string]$ModsDir = '',
    [int]$CommitCount = 8,
    [switch]$NoFetch
)

# Native git/curl calls write progress to stderr; with 'Stop' PowerShell 5.1 turns
# that into a terminating NativeCommandError. Explicit LASTEXITCODE checks are used.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. (Join-Path $PSScriptRoot 'workflow-lib.ps1')

$cfg = (Read-Text $ConfigFile) | ConvertFrom-Json
$prefix = $cfg.localBranchPrefix
$jarDir = Get-FullPath $cfg.jarDir
if (-not (Test-Path $jarDir)) { New-Item -ItemType Directory -Path $jarDir -Force | Out-Null }
$gcurl = Get-Curl
$token = Get-Token

function Get-Entry([string]$n) {
    $e = $cfg.forks | Where-Object { $_.name -eq $n }
    if (-not $e) { throw "unknown fork name '$n' (see $ConfigFile)" }
    return $e
}

function Ensure-Remote($entry) {
    $url = "https://github.com/$($entry.repo).git"
    $existing = git remote get-url $entry.remote 2>$null
    if (-not $existing) {
        git remote add $entry.remote $url 2>&1 | Out-Null
        Write-Host "[track] added remote $($entry.remote) -> $url"
    } elseif ($existing -ne $url) {
        git remote set-url $entry.remote $url 2>&1 | Out-Null
    }
}

function Sync-Entry($entry, [switch]$Quiet) {
    Ensure-Remote $entry
    $local = "$prefix$($entry.name)"
    $ref = "$($entry.remote)/$($entry.branch)"
    if (-not $Quiet) { Write-Host "[track] fetching $($entry.repo)#$($entry.branch) ..." }
    if (-not (Invoke-Fetch -Remote $entry.remote -Branch $entry.branch -Quiet:$Quiet)) {
        Write-Host "[track] WARN: fetch failed for $($entry.name)"
        return $false
    }
    # mirror the remote tip into a local tracking branch (force: it is a mirror)
    git update-ref "refs/heads/$local" "refs/remotes/$ref" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "[track] WARN: cannot update $local"; return $false }
    return $true
}

function Show-Status() {
    Write-Host ''
    Write-Host ('{0,-10} {1,-34} {2,-9} {3,-11} {4,-6} {5}' -f 'name', 'repo', 'tip', 'date', 'vs-up', 'label')
    Write-Host ('-' * 110)
    foreach ($e in $cfg.forks) {
        $local = "$prefix$($e.name)"
        $sha = (git rev-parse --short $local 2>$null)
        if (-not $sha) { Write-Host ('{0,-10} {1,-34} {2,-9} {3,-11} {4,-6} {5}' -f $e.name, $e.repo, '-', '-', '-', $cfg.strings.notSynced); continue }
        $date = (git log -1 "--pretty=%ad" --date=short $local)
        $delta = git rev-list --count "test..$local" 2>$null
        $subj = (git log -1 "--pretty=%s" $local)
        if ($subj.Length -gt 34) { $subj = $subj.Substring(0, 33) + '...' }
        Write-Host ('{0,-10} {1,-34} {2,-9} {3,-11} {4,-6} {5}' -f $e.name, $e.repo, $sha, $date, "+$delta", $e.label)
    }
    Write-Host ''
    Write-Host "[track] jars in $($cfg.jarDir):"
    $jars = Get-ChildItem $jarDir -Filter '*.jar' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $jars) { Write-Host '  (none yet - use -Action jar or -Action build)' }
    foreach ($j in $jars) { Write-Host ("  {0}  {1} bytes  {2}" -f $j.Name, $j.Length, $j.LastWriteTime) }
}

function Get-ReleaseJar($entry, [switch]$Quiet) {
    $api = "https://api.github.com/repos/$($entry.repo)/releases"
    $headers = @()
    if ($token -ne '') { $headers += "Authorization: Bearer $token" }
    $headers += 'User-Agent: silicon-track-forks'
    $out = Join-Path $cfg.jarDir "$($entry.name)-releases.json"
    $full = Get-FullPath $out

    $base = @('-sS', '-o', $full, '-w', '%{http_code}')
    foreach ($hd in $headers) { $base += @('-H', $hd) }
    $code = & $gcurl @base $api 2>$null
    if ("$code" -ne '200') {
        # proxy fallback: GitHub is reached either directly or through the local proxy
        $proxied = @('-sS', '--proxy', 'http://127.0.0.1:7897', '-o', $full, '-w', '%{http_code}')
        foreach ($hd in $headers) { $proxied += @('-H', $hd) }
        $code = & $gcurl @proxied $api 2>$null
        if ("$code" -ne '200') { Write-Host "[track] releases API HTTP $code for $($entry.repo)"; return $null }
    }

    $rels = (Read-Text $out) | ConvertFrom-Json
    if (-not $rels -or $rels.Count -eq 0) { return $null }
    $rel = $rels | Where-Object { -not $_.draft } | Select-Object -First 1
    $asset = $rel.assets | Where-Object { $_.name -like '*.jar' -and $_.name -notlike '*source*' } | Select-Object -First 1
    if (-not $asset) { return $null }

    $target = Get-FullPath (Join-Path $jarDir ("{0}-{1}-{2}" -f $entry.name, $rel.tag_name, $asset.name))
    if (-not $Quiet) { Write-Host "[track] downloading $($rel.tag_name) / $($asset.name) ..." }

    $dl = @('-sS', '-L', '-o', $target, '-w', '%{http_code}')
    if ($token -ne '') { $dl += @('-H', "Authorization: Bearer $token", '-H', 'Accept: application/octet-stream') }
    $dl += @('-H', 'User-Agent: silicon-track-forks')
    $code2 = & $gcurl @dl $asset.url 2>$null
    if ("$code2" -ne '200') {
        $proxyDl = @('-sS', '-L', '--proxy', 'http://127.0.0.1:7897', '-o', $target, '-w', '%{http_code}')
        if ($token -ne '') { $proxyDl += @('-H', "Authorization: Bearer $token", '-H', 'Accept: application/octet-stream') }
        $proxyDl += @('-H', 'User-Agent: silicon-track-forks')
        $code2 = & $gcurl @proxyDl $asset.url 2>$null
    }
    if ("$code2" -ne '200') { Write-Host "[track] download HTTP $code2"; return $null }
    Write-Host "[track] $($cfg.strings.downloaded): $target"
    return $target
}

function Build-Jar($entry) {
    $local = "$prefix$($entry.name)"
    $sha = (git rev-parse --short $local 2>$null)
    if (-not $sha) { throw "tracking branch $local missing - run -Action sync first" }
    $wt = Join-Path (Split-Path -Parent $root) ("track-build-" + $entry.name)
    if (Test-Path $wt) { git worktree remove --force $wt 2>&1 | Out-Null; Remove-Item -Recurse -Force $wt -ErrorAction SilentlyContinue }
    Write-Host "[track] worktree $wt @ $local"
    git worktree add --detach $wt $local 2>&1 | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "cannot create worktree for $local" }
    Push-Location $wt
    $built = $false
    try {
        if (Test-Path 'gradlew.bat') {
            # Never pipe gradle into Select-Object -First N: truncating the pipeline
            # kills the native process and turns a good build into a false failure.
            $log = Join-Path $wt 'gradle-build.log'
            & .\gradlew.bat jar '-Dhttps.proxyHost=127.0.0.1' '-Dhttps.proxyPort=7897' *> $log
            $code = $LASTEXITCODE
            if (Test-Path $log) { Get-Content $log | Select-String -Pattern 'BUILD|FAILURE|error:' | Select-Object -Last 5 }
            if ($code -eq 0) { $built = $true }
        } else {
            Write-Host '[track] no gradlew in that branch'
        }
    } finally {
        Pop-Location
    }
    if (-not $built) {
        git worktree remove --force $wt 2>&1 | Out-Null
        throw "build failed for $($entry.name) - see gradle output above"
    }
    # build.gradle names the jar "${project.name}Desktop.jar", and project.name is the
    # checkout folder name - so in a worktree it is NOT SiliconDesktop.jar. Take whichever
    # jar the build produced.
    $libs = Join-Path $wt 'build\libs'
    $jar = Get-ChildItem $libs -Filter '*.jar' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*source*' -and $_.Name -notlike '*-javadoc*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $jar) {
        git worktree remove --force $wt 2>&1 | Out-Null
        throw "no jar produced in $libs"
    }
    $target = Join-Path $jarDir ("{0}-{1}.jar" -f $entry.name, $sha)
    Copy-Item $jar.FullName (Get-FullPath $target) -Force
    git worktree remove --force $wt 2>&1 | Out-Null
    Write-Host "[track] $($cfg.strings.built): $target (from $($jar.Name))"
    return $target
}

function Install-Jar($entry) {
    $jars = Get-ChildItem $jarDir -Filter "$($entry.name)-*.jar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*backup*' } | Sort-Object LastWriteTime -Descending
    if (-not $jars) { throw "no jar for $($entry.name) yet - run -Action jar or -Action build" }
    $jar = $jars[0]
    if ($ModsDir -eq '') { $ModsDir = Join-Path $env:APPDATA 'Mindustry\mods' }
    if (-not (Test-Path $ModsDir)) { throw "mods dir not found: $ModsDir" }
    $modJar = Join-Path $ModsDir 'Silicon.jar'
    if (Test-Path $modJar) {
        $bak = Join-Path $jarDir ('backup-before-install-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.jar')
        Copy-Item $modJar (Get-FullPath $bak) -Force
        Write-Host "[track] $($cfg.strings.backup): $bak"
    }
    Copy-Item $jar.FullName $modJar -Force
    Write-Host "[track] $($cfg.strings.installed): $($jar.Name) -> $modJar"
    Write-Host "[track] restart the game to test it; restore with: Copy-Item $bak $modJar"
}

switch ($Action) {
    'sync' {
        foreach ($e in $cfg.forks) { Sync-Entry $e | Out-Null }
        Show-Status
    }
    'list' { Show-Status }
    'diff' {
        $e = Get-Entry $Name
        $local = "$prefix$($e.name)"
        Write-Host "[track] commits in $local not in test (up to $CommitCount):"
        git log --oneline -n $CommitCount "test..$local"
    }
    'jar' {
        $e = Get-Entry $Name
        Sync-Entry $e -Quiet | Out-Null
        $got = Get-ReleaseJar $e
        if (-not $got) { Write-Host "[track] $($cfg.strings.noRelease)" }
    }
    'build' {
        $e = Get-Entry $Name
        Sync-Entry $e | Out-Null
        Build-Jar $e | Out-Null
    }
    'install' {
        $e = Get-Entry $Name
        Install-Jar $e
    }
}

exit 0
