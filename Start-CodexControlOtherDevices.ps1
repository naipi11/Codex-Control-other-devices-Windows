[CmdletBinding()]
param(
    [ValidateRange(0,65535)][int]$RendererDebugPort=0,
    [ValidateRange(0,65535)][int]$MainInspectorPort=0,
    [ValidateRange(10,120)][int]$TimeoutSeconds=30
)

$ErrorActionPreference='Stop'
$runtimeManifestModule=Join-Path $PSScriptRoot 'src\persistence\modules\RuntimeManifest.psm1'
if(-not (Test-Path -LiteralPath $runtimeManifestModule -PathType Leaf)){throw 'Codex Control other devices support files are incomplete. Run the installer from a complete checkout.'}
Import-Module $runtimeManifestModule -Force

function Resolve-CcodStartInstalledController {
    param([Parameter(Mandatory)][string]$InstallRoot)
    $activePath=Join-Path $InstallRoot 'active.json'
    if(-not (Test-Path -LiteralPath $activePath -PathType Leaf)){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Codex Control other devices is not installed. Run Install-CodexControlOtherDevices.ps1 first; this checkout wrapper will not create persistent checkout state.'),'CCOD_INSTALL_REQUIRED',[Management.Automation.ErrorCategory]::ObjectNotFound,$InstallRoot)}
    $active=Read-CcodActiveRuntime -InstallRoot $InstallRoot
    $runtime=[IO.Path]::GetFullPath((Join-Path (Join-Path $InstallRoot 'runtime') $active.activeRuntime))
    $validation=Test-CcodRuntimeManifest -RuntimeDirectory $runtime -ExpectedRuntimeId $active.activeRuntime
    if(-not $validation.Valid){throw "Installed runtime validation failed: $($validation.Code). Repair or reinstall Codex Control other devices."}
    $controller=Join-Path $runtime 'src\persistence\SessionController.ps1'
    if(-not (Test-Path -LiteralPath $controller -PathType Leaf)){throw 'The verified active runtime does not contain SessionController.ps1. Repair or reinstall.'}
    [pscustomobject]@{RuntimeId=$active.activeRuntime;Controller=[IO.Path]::GetFullPath($controller)}
}

function New-CcodStartControllerArguments {
    param([string]$Controller,[int]$RendererDebugPort,[int]$MainInspectorPort,[int]$TimeoutSeconds)
    $arguments=[Collections.Generic.List[string]]::new();foreach($value in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Controller,'-Action','Apply','-ExistingOnly:$false','-TimeoutMilliseconds',[string]($TimeoutSeconds*1000))){$arguments.Add($value)}
    if($RendererDebugPort -ne 0){$arguments.Add('-RendererPort');$arguments.Add([string]$RendererDebugPort)}
    if($MainInspectorPort -ne 0){$arguments.Add('-MainPort');$arguments.Add([string]$MainInspectorPort)}
    return $arguments.ToArray()
}

function Invoke-CcodStartInstalledController {
    param($Resolved,[string[]]$Arguments)
    $powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
    $stderrPath=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ccod-start-$([guid]::NewGuid().ToString('N')).err")))
    try{$stdout=@(& $powershell @Arguments 2>$stderrPath);$exitCode=$LASTEXITCODE}finally{if([IO.File]::Exists($stderrPath)){[IO.File]::Delete($stderrPath)}}
    $lines=@($stdout|ForEach-Object{[string]$_}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})
    if($lines.Count -ne 1){throw 'Installed controller did not return exactly one machine-readable result line.'}
    try{$result=$lines[0]|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Installed controller returned invalid JSON.'}
    if($result.transactionId -isnot [string] -or $result.outcome -isnot [string]){throw 'Installed controller result is incomplete.'}
    if($exitCode -ne 0 -or $result.ok -ne $true){throw "Session activation failed safely: $($result.error.code) $($result.error.message)"}
    return $result
}

if($MyInvocation.InvocationName -ne '.'){
    $installRoot=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexControlOtherDevices'))
    $resolved=Resolve-CcodStartInstalledController -InstallRoot $installRoot
    $arguments=New-CcodStartControllerArguments -Controller $resolved.Controller -RendererDebugPort $RendererDebugPort -MainInspectorPort $MainInspectorPort -TimeoutSeconds $TimeoutSeconds
    $result=Invoke-CcodStartInstalledController -Resolved $resolved -Arguments $arguments
    Write-Host ''
    Write-Host 'Codex Control other devices is enabled for this app session.' -ForegroundColor Green
    Write-Host 'Open Settings > Connections > Control other devices.'
    if($null -ne $result.logFile){Write-Host "Diagnostics: $($result.logFile)"}
    Write-Host 'Launch Codex normally or run Reset-CodexControlOtherDevices.ps1 to disable the runtime fix.'
    Write-Host ''
}
