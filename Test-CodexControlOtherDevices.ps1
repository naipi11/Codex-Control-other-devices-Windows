[CmdletBinding()]
param(
    [switch]$Json,
    [string[]]$NodePath
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$checker = Join-Path $projectRoot 'src\check-package.mjs'
Import-Module (Join-Path $projectRoot 'src\persistence\modules\CompatibilityProbe.psm1') -Force
$reasons = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

$result = [ordered]@{
    Ready = $false
    OperatingSystem = [System.Environment]::OSVersion.VersionString
    IsWindows = $env:OS -eq 'Windows_NT' -or $PSVersionTable.PSEdition -eq 'Desktop'
    PackageInstalled = $false
    PackageFullName = $null
    PackageFamilyName = $null
    PackageInstallLocation = $null
    PackageVersion = $null
    ExecutablePath = $null
    AppAsarPath = $null
    NodePath = $null
    NodeVersion = $null
    NodeMajor = $null
    NodeSupported = $false
    NodeCapabilities = $null
    SchemaVersion = $null
    StaticClassification = 'UnknownOrIncompatible'
    AppAsarSha256 = $null
    PackageSignatures = $null
    AffectedBuildDetected = $false
    Code = $null
    Message = $null
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

    $nodeCandidates = @($NodePath)
    if (-not $PSBoundParameters.ContainsKey('NodePath')) {
        $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($nodeCommand) {
            $nodeCandidates = @([IO.Path]::GetFullPath([string]$nodeCommand.Source))
        }
    }
    $probe = Invoke-CcodStaticProbe -NodeCandidates $nodeCandidates -CheckerPath $checker
    foreach ($name in @('PackageInstalled', 'PackageFullName', 'PackageFamilyName', 'PackageInstallLocation', 'PackageVersion', 'ExecutablePath', 'AppAsarPath', 'NodePath', 'NodeVersion', 'NodeMajor', 'NodeSupported', 'NodeCapabilities', 'SchemaVersion', 'StaticClassification', 'AppAsarSha256', 'PackageSignatures', 'AffectedBuildDetected', 'Code', 'Message')) {
        $result[$name] = $probe.$name
    }

    $formattedProbe = Get-CcodPublicProbeResult -Probe $probe -CheckerPath $checker
    foreach ($reason in $formattedProbe.Reasons) { $reasons.Add($reason) }

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
    Write-Host ('  Static class:     {0}' -f $result.StaticClassification)

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
