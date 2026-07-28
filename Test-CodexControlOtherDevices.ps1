[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$checker = Join-Path $projectRoot 'src\check-package.mjs'
$reasons = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

$result = [ordered]@{
    Ready = $false
    OperatingSystem = [System.Environment]::OSVersion.VersionString
    IsWindows = $env:OS -eq 'Windows_NT' -or $PSVersionTable.PSEdition -eq 'Desktop'
    PackageInstalled = $false
    PackageVersion = $null
    ExecutablePath = $null
    AppAsarPath = $null
    NodePath = $null
    NodeVersion = $null
    NodeMajor = $null
    NodeSupported = $false
    PackageSignatures = $null
    AffectedBuildDetected = $false
    Reasons = $reasons
    Warnings = $warnings
}

try {
    if (-not $result.IsWindows) {
        $reasons.Add('This workaround supports Windows only.')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME) -and
        -not [System.IO.Path]::IsPathRooted($env:CODEX_HOME)) {
        $reasons.Add('CODEX_HOME must be an absolute path so launch and rollback resolve the same key store.')
    }

    $package = Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue
    if (-not $package) {
        $reasons.Add('The Microsoft Store/MSIX OpenAI.Codex package is not installed.')
    } else {
        $result.PackageInstalled = $true
        $result.PackageVersion = $package.Version.ToString()
        $result.ExecutablePath = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        $result.AppAsarPath = Join-Path $package.InstallLocation 'app\resources\app.asar'
        $nativeDirectory = Join-Path $package.InstallLocation 'app\resources\native'

        if (-not (Test-Path -LiteralPath $result.ExecutablePath -PathType Leaf)) {
            $reasons.Add("Codex executable was not found: $($result.ExecutablePath)")
        }
        if (-not (Test-Path -LiteralPath $result.AppAsarPath -PathType Leaf)) {
            $reasons.Add("Codex app.asar was not found: $($result.AppAsarPath)")
        }
    }

    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCommand) {
        $reasons.Add('Node.js 22 or newer is required but node.exe is not on PATH.')
    } else {
        $result.NodePath = $nodeCommand.Source
        $result.NodeVersion = (& $nodeCommand.Source --version).Trim()
        $result.NodeMajor = [int](($result.NodeVersion -replace '^v', '').Split('.')[0])
        $result.NodeSupported = $result.NodeMajor -ge 22
        if (-not $result.NodeSupported) {
            $reasons.Add("Node.js 22 or newer is required; found $($result.NodeVersion).")
        }
    }

    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
        $reasons.Add("Package checker was not found: $checker")
    }

    if ($result.PackageInstalled -and $result.NodeSupported -and
        (Test-Path -LiteralPath $result.AppAsarPath -PathType Leaf) -and
        (Test-Path -LiteralPath $checker -PathType Leaf)) {
        $checkerOutput = & $result.NodePath $checker $result.AppAsarPath $nativeDirectory 2>&1
        if ($LASTEXITCODE -ne 0) {
            $reasons.Add("Could not inspect the installed Codex package: $($checkerOutput -join ' ')")
        } else {
            $packageState = ($checkerOutput -join "`n") | ConvertFrom-Json
            $result.PackageSignatures = $packageState
            $result.AffectedBuildDetected = [bool]$packageState.affected
            if (-not $result.AffectedBuildDetected) {
                $reasons.Add('The installed package does not match the known Windows controller bug signature. Refusing to inject into an unreviewed build.')
            }
        }
    }

    $warnings.Add('Account authentication cannot be verified locally. Complete any MFA, SSO, or passkey required by the account/workspace; the tested account required MFA before enrollment.')
    $warnings.Add('The renderer debug endpoint remains on 127.0.0.1 until Codex exits; run only on a trusted machine.')

    $result.Ready = $result.IsWindows -and
        $result.PackageInstalled -and
        $result.NodeSupported -and
        $result.AffectedBuildDetected -and
        $reasons.Count -eq 0
} catch {
    $reasons.Add($_.Exception.Message)
    $result.Ready = $false
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} else {
    Write-Host ''
    Write-Host 'Codex Control other devices - compatibility check' -ForegroundColor Cyan
    Write-Host ('  Ready:            {0}' -f $result.Ready)
    $packageDisplay = if ($null -eq $result.PackageVersion) { 'not found' } else { $result.PackageVersion }
    $nodeDisplay = if ($null -eq $result.NodeVersion) { 'not found' } else { $result.NodeVersion }
    Write-Host ('  Codex package:    {0}' -f $packageDisplay)
    Write-Host ('  Node.js:          {0}' -f $nodeDisplay)
    Write-Host ('  Heuristic match:  {0}' -f $result.AffectedBuildDetected)

    if ($reasons.Count -gt 0) {
        Write-Host ''
        Write-Host 'Blocking findings:' -ForegroundColor Red
        foreach ($reason in $reasons) { Write-Host "  - $reason" }
    }

    Write-Host ''
    Write-Host 'Security notes:' -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "  - $warning" }
    Write-Host ''
}

if (-not $result.Ready) { exit 1 }
