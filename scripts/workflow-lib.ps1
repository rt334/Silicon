# workflow-lib.ps1 -- shared helpers for the fork publish workflow. ASCII only.
#
# Why the custom push: invoking git from inside a script can break Git Credential
# Manager when its helper path contains spaces (".../Git Credential Manager/...").
# We therefore disable the helper for our pushes and authenticate with an
# Authorization: Basic header derived from the token (kept out of logs by a
# scrubber). A plain push is used as fallback when no token is available.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
    $full = Get-FullPath $path
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($full, $text, $script:Utf8NoBom)
}

function Render([string]$template, [hashtable]$map) {
    $out = $template
    foreach ($k in $map.Keys) { $out = $out.Replace('{' + $k + '}', [string]$map[$k]) }
    return $out
}

function Get-Curl {
    foreach ($c in @('C:\Program Files\Git\mingw64\bin\curl.exe', 'C:\Program Files\Git\usr\bin\curl.exe')) {
        if (Test-Path $c) { return $c }
    }
    return 'curl'
}

function Get-Token {
    param([string]$Explicit = '')
    if ($Explicit -ne '') { return $Explicit }
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    $fill = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
    $line = $fill | Select-String '^password=' | Select-Object -First 1
    if ($line) { return $line.Line.Substring(9) }
    return ''
}

function Get-RemoteSlug {
    param([string]$Remote = 'origin')
    $url = (git remote get-url $Remote 2>$null)
    if (-not $url) { return '' }
    $m = [regex]::Match($url, 'github\.com[:/](?<slug>[^/]+/[^/]+?)(\.git)?$')
    if ($m.Success) { return $m.Groups['slug'].Value }
    return ''
}

function Invoke-Push {
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [string]$Remote = 'origin',
        [string]$Token = '',
        [int]$Attempts = 4,
        [switch]$Force
    )
    $tok = Get-Token -Explicit $Token
    $slug = Get-RemoteSlug -Remote $Remote
    $forceArg = @()
    if ($Force) { $forceArg = @('--force-with-lease') }

    for ($i = 1; $i -le $Attempts; $i++) {
        $out = $null
        if ($tok -ne '' -and $slug -ne '') {
            $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$tok"))
            $out = git -c credential.helper= -c "http.extraHeader=Authorization: Basic $basic" `
                push @forceArg $Remote $Ref 2>&1
        } else {
            $out = git push @forceArg $Remote $Ref 2>&1
        }
        $code = $LASTEXITCODE
        $safe = @($out | ForEach-Object { $_.ToString().Replace($tok, '***') })
        if ($code -eq 0) {
            Write-Host "[push] $Ref -> $Remote ok"
            return $true
        }
        Write-Host "[push] attempt $i failed: $(($safe | Select-Object -Last 1))"
        Start-Sleep -Seconds 8
    }
    return $false
}
