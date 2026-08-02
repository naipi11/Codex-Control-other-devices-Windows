[CmdletBinding()]
param(
    [switch]$BackupDeviceKeyStore,
    [switch]$DoNotRestart
)

$ErrorActionPreference='Stop'
$runtimeManifestModule=Join-Path $PSScriptRoot 'src\persistence\modules\RuntimeManifest.psm1'
if(-not (Test-Path -LiteralPath $runtimeManifestModule -PathType Leaf)){throw 'Codex Control other devices support files are incomplete. Run the installer from a complete checkout.'}
Import-Module $runtimeManifestModule -Force

function Resolve-CcodResetInstalledController {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $activePath=Join-Path $InstallRoot 'active.json'
    if(-not (Test-Path -LiteralPath $activePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Codex Control other devices is not installed. Run Install-CodexControlOtherDevices.ps1 first; this checkout wrapper will not create persistent checkout state.'),'CCOD_INSTALL_REQUIRED',[Management.Automation.ErrorCategory]::ObjectNotFound,$InstallRoot)}
    $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot;$runtime=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
    $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $active.activeRuntime
    if(-not $validation.Valid){throw "Installed runtime validation failed: $($validation.Code). Repair or reinstall Codex Control other devices."}
    $controller=Join-Path $runtime 'src\persistence\SessionController.ps1';$stateModule=Join-Path $runtime 'src\persistence\modules\StateStore.psm1'
    if(-not (Test-Path -LiteralPath $controller -PathType Leaf) -or -not (Test-Path -LiteralPath $stateModule -PathType Leaf)){throw 'The verified active runtime lacks required reset files. Repair or reinstall.'}
    [pscustomobject]@{RuntimeId=$active.activeRuntime;Controller=[IO.Path]::GetFullPath($controller);StateModule=[IO.Path]::GetFullPath($stateModule)}
}

function New-CcodResetControllerArguments {
    param([string]$Controller,[bool]$DoNotRestart)
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Controller,'-Action','Recover')
    if($DoNotRestart){$arguments+=@('-RestartOrdinary:$false')}
    return $arguments
}

function Invoke-CcodResetInstalledController {
    param($Resolved,[string[]]$Arguments)
    $powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
    $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-reset-$([guid]::NewGuid().ToString('N')).err")))
    try{$stdout=@(& $powershell @Arguments 2>$stderrPath);$exitCode=$LASTEXITCODE}finally{if([IO.File]::Exists($stderrPath)){[IO.File]::Delete($stderrPath)}}
    $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
    if($lines.Count -ne 1){throw 'Installed controller did not return exactly one machine-readable result line.'}
    try{$result=$lines[0]|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Installed controller returned invalid JSON.'}
    if($exitCode -ne 0 -or $result.ok -ne $true){throw "Session reset failed safely: $($result.error.code) $($result.error.message)"}
    return $result
}

function Move-CcodResetDeviceKeyStore {
    param([string]$StateModule)
    Import-Module $StateModule -Force;$store=Resolve-CcodDeviceKeyStorePath
    if(-not (Test-Path -LiteralPath $store -PathType Leaf)){return $null}
    $base="$store.backup.$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))";$destination=$base;$suffix=0
    while(Test-Path -LiteralPath $destination){$suffix++;$destination="$base.$suffix"}
    Move-Item -LiteralPath $store -Destination $destination
    return $destination
}

if($MyInvocation.InvocationName -ne '.'){
    $installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexControlOtherDevices'))
    $resolved=Resolve-CcodResetInstalledController -InstallRoot $installRoot;$arguments=New-CcodResetControllerArguments -Controller $resolved.Controller -DoNotRestart ([bool]$DoNotRestart)
    $result=Invoke-CcodResetInstalledController -Resolved $resolved -Arguments $arguments;$backup=$null
    if($BackupDeviceKeyStore){$backup=Move-CcodResetDeviceKeyStore -StateModule $resolved.StateModule}
    Write-Host ''
    Write-Host 'The runtime fix is no longer active.' -ForegroundColor Green
    if($backup){Write-Host "The encrypted device-key store was moved to: $backup";Write-Host 'This local move does not revoke server-side authorization; revoke the device in Codex first.' -ForegroundColor Yellow}
    if($DoNotRestart){Write-Host 'Codex Desktop was left closed.'}else{Write-Host 'Codex Desktop was returned to an ordinary session.'}
    Write-Host ''
}
