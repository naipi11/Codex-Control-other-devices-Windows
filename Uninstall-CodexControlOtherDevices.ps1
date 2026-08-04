[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallRoot,
    [switch]$KeepCurrentSpecialSession,
    [switch]$BackupDeviceKeyStore,
    [switch]$RemoveDeviceKeyStore
)

$ErrorActionPreference = 'Stop'

function Resolve-CcodUninstallerModule {
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $checkoutModule = [IO.Path]::GetFullPath((Join-Path $ScriptRoot 'src\persistence\modules\InstallLifecycle.psm1'))
    if (Test-Path -LiteralPath $checkoutModule -PathType Leaf) {
        return $checkoutModule
    }
    $activePath = Join-Path $ScriptRoot 'active.json'
    if (Test-Path -LiteralPath $activePath -PathType Leaf) {
        try {
            $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $active -and $active.activeRuntime -is [string] -and $active.activeRuntime -cmatch '^[A-Za-z0-9._-]{1,96}$') {
                $runtimeModule = [IO.Path]::GetFullPath((Join-Path $ScriptRoot "runtime\$($active.activeRuntime)\src\persistence\modules\InstallLifecycle.psm1"))
                if (Test-Path -LiteralPath $runtimeModule -PathType Leaf) {
                    return $runtimeModule
                }
            }
        } catch {
        }
    }
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new('InstallLifecycle.psm1 could not be located. Run this uninstaller from the checkout or from the installed root.'),
        'CCOD_UNINSTALLER_MODULE_MISSING',
        [Management.Automation.ErrorCategory]::ObjectNotFound,
        $ScriptRoot
    )
}

$script:UninstallerModule = Resolve-CcodUninstallerModule -ScriptRoot $PSScriptRoot
Import-Module $script:UninstallerModule -Force

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'
}

$receipt = Invoke-CcodUninstall `
    -InstallRoot $InstallRoot `
    -KeepCurrentSpecialSession:([bool]$KeepCurrentSpecialSession) `
    -BackupDeviceKeyStore:([bool]$BackupDeviceKeyStore) `
    -RemoveDeviceKeyStore:([bool]$RemoveDeviceKeyStore)

Write-Host ''
Write-Host 'Codex Control other devices - uninstall result' -ForegroundColor Cyan
Write-Host ('  Outcome:          {0}' -f $receipt.Outcome)
if ($receipt.BackupPath) {
    Write-Host ("  Key backup:       {0}" -f $receipt.BackupPath)
}
if ($receipt.KeptDeviceKeyStore) {
    Write-Host '  Device key store: preserved' -ForegroundColor Green
}
if ($RemoveDeviceKeyStore) {
    Write-Host '  Device key store: removed locally' -ForegroundColor Yellow
    Write-Host '  Server authorization is NOT revoked by this local removal; revoke the device in Codex.' -ForegroundColor Yellow
}
if ($KeepCurrentSpecialSession) {
    Write-Host '  The special Codex session was left running unmonitored.' -ForegroundColor Yellow
    Write-Host '  Its renderer CDP endpoint remains open on 127.0.0.1 with no tray supervision.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'The persistent tray supervisor, runtime, state, and logs were removed.' -ForegroundColor Green
Write-Host ''
