[CmdletBinding()]
param(
    [string]$Version,
    [switch]$UseExistingTrayHost,
    [string]$TrayHostArtifactDirectory
)

$ErrorActionPreference = 'Stop'

function Get-CcodBuildFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$package = Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string]$package.version
}
$Version = $Version.TrimStart('v')
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid project version for the installer: $Version"
}

$trayHostArtifact = if ([string]::IsNullOrWhiteSpace($TrayHostArtifactDirectory)) {
    Join-Path $PSScriptRoot 'generated\trayhost'
} else {
    [IO.Path]::GetFullPath($TrayHostArtifactDirectory)
}
Import-Module (Join-Path $PSScriptRoot 'TrayHostBuild.psm1') -Force
if ($UseExistingTrayHost) {
    Test-CcodTrayHostArtifact -RepositoryRoot $repoRoot -Version $Version -ArtifactDirectory $trayHostArtifact | Out-Null
} else {
    Invoke-CcodTrayHostBuild -RepositoryRoot $repoRoot -Version $Version -OutputDirectory $trayHostArtifact | Out-Null
}

$isccCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
)
$iscc = $isccCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_) } | Select-Object -First 1
if (-not $iscc) {
    throw 'Inno Setup 6 (ISCC.exe) was not found. Install it with: winget install --id JRSoftware.InnoSetup --exact'
}

$scriptPath = Join-Path $PSScriptRoot 'CodexControlOtherDevices.iss'
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

& $iscc "/DProjectVersion=$Version" "/DTrayHostArtifactDirectory=$trayHostArtifact" "/O$dist\" $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

$exe = Join-Path $dist "CodexRemote-fix-$Version-setup.exe"
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Inno Setup completed but the installer was not produced: $exe"
}

$hash = Get-CcodBuildFileSha256 -Path $exe
$sha256File = Join-Path $dist ("CodexRemote-fix-$Version-setup.exe.sha256.txt")
Set-Content -LiteralPath $sha256File -Value ("{0} *{1}" -f $hash, [IO.Path]::GetFileName($exe)) -Encoding ascii

Write-Host ''
Write-Host 'Installer build completed:' -ForegroundColor Green
Write-Host ("  Setup:    {0}" -f $exe)
Write-Host ("  SHA-256:  {0}" -f $sha256File)
Write-Host ("  Hash:     {0}" -f $hash)
Write-Host ''
