$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$startPath=Join-Path $repositoryRoot 'Start-CodexControlOtherDevices.ps1';$resetPath=Join-Path $repositoryRoot 'Reset-CodexControlOtherDevices.ps1'
Import-Module (Join-Path $repositoryRoot 'src\persistence\modules\PersistenceIO.psm1') -Force
. $startPath
. $resetPath

function Get-CcodScriptAst([string]$Path){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);if($errors.Count -ne 0){throw ($errors|Out-String)};return $ast}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-wrapper-selftest-'+[guid]::NewGuid().ToString('N'))
try{
    Invoke-CcodTest 'keeps exact public parameters and contains no process bridge or kill implementation' {
        $startAst=Get-CcodScriptAst $startPath;$resetAst=Get-CcodScriptAst $resetPath
        Assert-CcodEqual 'RendererDebugPort,MainInspectorPort,TimeoutSeconds' (($startAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath}) -join ',') 'Start public parameters remain exact'
        Assert-CcodEqual 'BackupDeviceKeyStore,DoNotRestart' (($resetAst.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath}) -join ',') 'Reset public parameters remain exact'
        foreach($case in @(@{Name='Start';Ast=$startAst},@{Name='Reset';Ast=$resetAst})){
            $commands=@($case.Ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()}|Where-Object{$_})
            foreach($forbidden in @('Get-Process','Stop-Process','Start-Process','Get-AppxPackage')){Assert-CcodTrue ($commands -cnotcontains $forbidden) "$($case.Name) wrapper has no $forbidden workflow"}
            $text=$case.Ast.Extent.Text;Assert-CcodTrue ($text -cnotmatch 'orchestrator\.js|main-payload|remote-debugging|--inspect') "$($case.Name) wrapper has no bridge implementation"
        }
    }

    Invoke-CcodTest 'maps Start closed-app ports and Reset DoNotRestart to direct installed controller arguments' {
        $automatic=New-CcodStartControllerArguments -Controller 'C:\installed\SessionController.ps1' -RendererDebugPort 0 -MainInspectorPort 0 -TimeoutSeconds 30
        Assert-CcodTrue (($automatic -join ',') -cmatch '-Action,Apply,-ExistingOnly:\$false') 'Start explicitly allows a closed app with existingOnly false'
        Assert-CcodTrue (($automatic -join ',') -cnotmatch 'RendererPort|MainPort') 'public zero ports map to nullable omitted controller ports'
        $explicit=New-CcodStartControllerArguments -Controller 'C:\installed\SessionController.ps1' -RendererDebugPort 41001 -MainInspectorPort 41002 -TimeoutSeconds 40
        Assert-CcodTrue (($explicit -join ',') -cmatch '-RendererPort,41001,-MainPort,41002') 'explicit public ports are preserved'
        $normal=New-CcodResetControllerArguments -Controller 'C:\installed\SessionController.ps1' -DoNotRestart $false
        Assert-CcodTrue (($normal -join ',') -cnotmatch 'RestartOrdinary') 'normal Reset uses default ordinary recovery'
        $closed=New-CcodResetControllerArguments -Controller 'C:\installed\SessionController.ps1' -DoNotRestart $true
        Assert-CcodTrue (($closed -join ',') -cmatch '-RestartOrdinary:\$false') 'DoNotRestart maps to the durable close request'
    }

    Invoke-CcodTest 'fails clearly in checkout-only mode before creating durable state' {
        $installRoot=Join-Path $root 'not-installed'
        Assert-CcodThrows {Resolve-CcodStartInstalledController -InstallRoot $installRoot} 'CCOD_INSTALL_REQUIRED'
        Assert-CcodThrows {Resolve-CcodResetInstalledController -InstallRoot $installRoot} 'CCOD_INSTALL_REQUIRED'
        Assert-CcodEqual $false (Test-Path -LiteralPath $installRoot) 'checkout-only failure creates no install state'
    }

    Invoke-CcodTest 'dispatches only to a manifest-verified active runtime' {
        $installRoot=Join-Path $root 'installed';$staging=Join-Path $installRoot 'staging';$controller=Join-Path $staging 'src\persistence\SessionController.ps1';$stateModule=Join-Path $staging 'src\persistence\modules\StateStore.psm1'
        [IO.Directory]::CreateDirectory((Split-Path $controller -Parent))|Out-Null;[IO.Directory]::CreateDirectory((Split-Path $stateModule -Parent))|Out-Null
        [IO.File]::WriteAllText($controller,'# installed controller',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stateModule,'# installed state',[Text.UTF8Encoding]::new($false))
        $manifest=New-CcodRuntimeManifest -RuntimeDirectory $staging -ProjectVersion '2.0.0';$runtime=Join-Path (Join-Path $installRoot 'runtime') $manifest.runtimeId;[IO.Directory]::CreateDirectory((Split-Path $runtime -Parent))|Out-Null;[IO.Directory]::Move($staging,$runtime)
        Write-CcodAtomicJson -Path (Join-Path $runtime 'manifest.json') -Value $manifest;Set-CcodActiveRuntime -InstallRoot $installRoot -NewRuntimeId $manifest.runtimeId|Out-Null
        $start=Resolve-CcodStartInstalledController -InstallRoot $installRoot;$reset=Resolve-CcodResetInstalledController -InstallRoot $installRoot
        Assert-CcodEqual ([IO.Path]::GetFullPath((Join-Path $runtime 'src\persistence\SessionController.ps1'))) $start.Controller 'Start targets verified active controller'
        Assert-CcodEqual $start.Controller $reset.Controller 'Reset targets the same verified runtime'
        [IO.File]::AppendAllText($start.Controller,'tampered',[Text.UTF8Encoding]::new($false))
        Assert-CcodThrows {Resolve-CcodStartInstalledController -InstallRoot $installRoot} '*'
    }
}catch{Write-Error $_;exit 1}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
