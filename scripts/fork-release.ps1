# fork-release.ps1 -- refresh the fork's rolling GitHub release and the README
# build block. ASCII only; all localized strings come from workflow-strings.json.
#
# Used by both:
#   - scripts/fork-publish.ps1 (local end-to-end publish)
#   - .github/workflows/fork-publish.yml (CI, runs on push to fork/main)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\fork-release.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\fork-release.ps1 -SkipRelease -DryRun

param(
    [string]$Repo = 'rt334/Silicon',
    [string]$Tag = 'fork-latest',
    [string]$Jar = 'build/libs/SiliconDesktop.jar',
    [string]$AssetName = 'Silicon.jar',
    [string]$Branch = '',
    [string]$StringsFile = 'scripts/workflow-strings.json',
    [string]$ModFile = 'mod.hjson',
    [string]$ReadmeFile = 'README.md',
    [string]$Token = '',
    [string]$WorkDir = 'build',
    [int]$CommitCount = 10,
    [switch]$SkipRelease,
    [switch]$SkipReadme,
    [switch]$NoPush,
    [switch]$DryRun
)

# Native git/curl calls write progress to stderr; with 'Stop' PowerShell 5.1 turns
# that into a terminating NativeCommandError. Explicit LASTEXITCODE / HTTP checks are used.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'workflow-lib.ps1')

$strings = (Read-Text $StringsFile) | ConvertFrom-Json
$gcurl = Get-Curl
$sha = (git rev-parse --short HEAD).Trim()
$date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
if ($Branch -eq '') { $Branch = (git rev-parse --abbrev-ref HEAD).Trim() }

$modVersion = 'unknown'
$mm = [regex]::Match((Read-Text $ModFile), '(?m)^version:\s*(\S+)\s*$')
if ($mm.Success) { $modVersion = $mm.Groups[1].Value }

$commits = (git log -n $CommitCount --pretty=format:'- %h %s') -join "`n"
$releaseUrl = "https://github.com/$Repo/releases/tag/$Tag"

$map = @{
    branch     = $Branch
    sha        = $sha
    date       = $date
    modVersion = $modVersion
    asset      = $AssetName
    tag        = $Tag
    releaseUrl = $releaseUrl
    commits    = $commits
}
$notes = Render $strings.releaseNotes $map
$title = Render $strings.releaseTitle $map

Write-Host "[fork-release] repo=$Repo tag=$Tag branch=$Branch sha=$sha mod=$modVersion"

$token = ''

if (-not $SkipRelease) {
    if (-not (Test-Path (Get-FullPath $Jar))) { throw "jar not found: $Jar (build first)" }
    $token = Get-Token -Explicit $Token
    if ($token -eq '') { throw 'no GitHub token for the release step' }
    $authHeader = "Authorization: Bearer $token"
    $uaHeader = 'User-Agent: silicon-fork-publish'
    $createFile = Join-Path $WorkDir 'rel-create.json'
    $outFile = Join-Path $WorkDir 'rel-out.json'
    $uploadFile = Join-Path $WorkDir 'rel-upload.json'
    $patchFile = Join-Path $WorkDir 'rel-patch.json'

    Write-Text $createFile (@{ tag_name = $Tag; target_commitish = $Branch; name = $title; body = $notes } | ConvertTo-Json)

    if ($DryRun) {
        Write-Host "[fork-release] dry run: would create/refresh release $Tag and upload $Jar as $AssetName"
    } else {
        $code = & $gcurl -sS -H $authHeader -H $uaHeader -H 'Content-Type: application/json' -X POST `
            -o $outFile -w '%{http_code}' --data-binary "@$createFile" `
            "https://api.github.com/repos/$Repo/releases" 2>$null
        Write-Host "[fork-release] create release: HTTP $code"

        if ("$code" -eq '201') {
            $rel = (Read-Text $outFile) | ConvertFrom-Json
        } else {
            $code2 = & $gcurl -sS -H $authHeader -H $uaHeader -o $outFile -w '%{http_code}' `
                "https://api.github.com/repos/$Repo/releases/tags/$Tag" 2>$null
            Write-Host "[fork-release] fetch release by tag: HTTP $code2"
            if ("$code2" -ne '200') { throw "cannot create or fetch release $Tag (HTTP $code / $code2)" }
            $rel = (Read-Text $outFile) | ConvertFrom-Json
        }
        if (-not $rel.id) { throw "no release id for $Tag" }

        foreach ($a in $rel.assets) {
            if ($a.name -eq $AssetName) {
                & $gcurl -sS -H $authHeader -H $uaHeader -X DELETE -o NUL `
                    -w "[fork-release] delete stale asset: HTTP %{http_code}`n" `
                    "https://api.github.com/repos/$Repo/releases/assets/$($a.id)" 2>$null
            }
        }

        $up = & $gcurl -sS -H $authHeader -H $uaHeader -H 'Content-Type: application/java-archive' `
            -o $uploadFile -w '%{http_code}' -F "data=@$(Get-FullPath $Jar)" `
            "https://uploads.github.com/repos/$Repo/releases/$($rel.id)/assets?name=$AssetName" 2>$null
        Write-Host "[fork-release] upload asset: HTTP $up"
        $u = (Read-Text $uploadFile) | ConvertFrom-Json
        Write-Host "[fork-release] asset: $($u.name) $($u.size) bytes state=$($u.state)"

        Write-Text $patchFile (@{ name = $title; body = $notes } | ConvertTo-Json)
        $codeP = & $gcurl -sS -H $authHeader -H $uaHeader -H 'Content-Type: application/json' -X PATCH `
            -o $outFile -w '%{http_code}' --data-binary "@$patchFile" `
            "https://api.github.com/repos/$Repo/releases/$($rel.id)" 2>$null
        Write-Host "[fork-release] patch release notes: HTTP $codeP"
        Write-Host "[fork-release] release: $releaseUrl"
    }
} else {
    Write-Host '[fork-release] release step skipped'
}

if (-not $SkipReadme) {
    $block = Render $strings.readmeBlock $map
    $readme = Read-Text $ReadmeFile
    $begin = '<!-- FORK-BUILD:BEGIN -->'
    $end = '<!-- FORK-BUILD:END -->'
    if ($readme.Contains($begin) -and $readme.Contains($end)) {
        $pattern = [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end)
        $readme = [regex]::Replace($readme, $pattern, $block)
    } else {
        $firstHeading = [regex]::Match($readme, '(?m)^## ')
        if ($firstHeading.Success) {
            $readme = $readme.Insert($firstHeading.Index, $block + "`n`n")
        } else {
            $readme = $readme.TrimEnd() + "`n`n" + $block + "`n"
        }
    }
    Write-Text $ReadmeFile $readme

    if ($DryRun) {
        Write-Host '[fork-release] dry run: README build block rendered (not committed)'
    } else {
        git add $ReadmeFile
        $staged = git diff --cached --name-only
        if ($staged) {
            $msgFile = Join-Path $WorkDir 'readme-commit.txt'
            $msg = (Render $strings.readmeCommitMessage @{ sha = $sha }) + ' ' + $strings.skipCi
            Write-Text $msgFile $msg
            git commit -F $msgFile | Out-Null
            Write-Host "[fork-release] README block committed ($sha)"
            if (-not $NoPush) {
                if (Invoke-Push -Ref 'HEAD' -Remote origin -Token $token) {
                    Write-Host '[fork-release] README commit pushed'
                } else {
                    Write-Host '[fork-release] WARNING: README commit not pushed (network)'
                }
            }
        } else {
            Write-Host '[fork-release] README block unchanged, nothing to commit'
        }
    }
} else {
    Write-Host '[fork-release] readme step skipped'
}

Write-Host '[fork-release] done'
