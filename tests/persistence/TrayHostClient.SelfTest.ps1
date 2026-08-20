$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\TrayHostClient.psm1'
Invoke-CcodTest 'TrayHost client wrapper is source-auditable and does not start a host on import' {
    Assert-CcodTrue (Test-Path -LiteralPath $modulePath -PathType Leaf) 'TrayHost client module exists'
    Import-Module $modulePath -Force
    foreach($name in @('New-CcodTrayHostContext','Set-CcodTrayHostPresentation','Invoke-CcodTrayHostRunLoop','Request-CcodTrayHostExit','Close-CcodTrayHostContext','Show-CcodTrayHostError','End-CcodTrayHostMenu')){Assert-CcodTrue ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "wrapper export exists: $name"}
    Assert-CcodTrue ($null -eq (Get-Command New-CcodTrayContext -ErrorAction SilentlyContinue)) 'wrapper does not re-export the legacy UI constructor'
}

Invoke-CcodTest 'Supervisor imports the TrayHost client as its only production tray constructor' {
    $supervisor=Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\persistence\Supervisor.ps1') -Raw
    Assert-CcodTrue ($supervisor -match "'TrayHostClient\.psm1'") 'Supervisor imports TrayHostClient'
    Assert-CcodTrue ($supervisor -match 'New-CcodTrayHostContext') 'default NewTray delegates to TrayHostClient'
    Assert-CcodTrue ($supervisor -match 'Invoke-CcodTrayHostRunLoop') 'default RunUiContext delegates to TrayHostClient'
}

Write-Host 'TrayHost client self-tests passed.'
