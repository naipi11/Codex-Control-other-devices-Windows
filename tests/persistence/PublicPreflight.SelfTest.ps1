$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\CompatibilityProbe.psm1') -Force

try {
    Invoke-CcodTest 'formats every package-entry failure as an auditable public reason' {
        foreach ($case in @(
            [pscustomobject]@{ Code = 'PACKAGE_METADATA_INVALID'; Message = 'Package metadata is incomplete.' },
            [pscustomobject]@{ Code = 'PACKAGE_EXECUTABLE_MISSING'; Message = 'Package executable is missing.' },
            [pscustomobject]@{ Code = 'PACKAGE_ASAR_MISSING'; Message = 'Package asar is missing.' }
        )) {
            $formatted = Get-CcodPublicProbeResult -Probe $case -CheckerPath 'C:\Runtime\check-package.mjs'
            Assert-CcodEqual $case.Code $formatted.Code "public formatter retains $($case.Code)"
            Assert-CcodEqual $case.Message $formatted.Message "public formatter retains $($case.Code) message"
            Assert-CcodTrue ($formatted.Reasons.Count -gt 0) "public formatter reports a reason for $($case.Code)"
        }
    }
} catch {
    Write-Error $_
    exit 1
}
