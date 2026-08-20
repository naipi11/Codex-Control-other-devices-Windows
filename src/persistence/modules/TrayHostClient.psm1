Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:CcodTrayHostAssemblyPath=$null

function Get-CcodTrayHostRuntimeRoot {
    $moduleRoot=Split-Path $PSCommandPath -Parent
    return [IO.Path]::GetFullPath((Split-Path (Split-Path (Split-Path $moduleRoot -Parent) -Parent) -Parent))
}

function Import-CcodTrayHostAssembly {
    $runtimeRoot=Get-CcodTrayHostRuntimeRoot
    $path=Join-Path $runtimeRoot 'trayhost\CodexRemote.TrayHost.exe'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'CCOD_TRAYHOST_ARTIFACT_MISSING'}
    $full=[IO.Path]::GetFullPath($path)
    if($script:CcodTrayHostAssemblyPath -cne $full){Add-Type -Path $full -ErrorAction Stop;$script:CcodTrayHostAssemblyPath=$full}
}

function Convert-CcodTrayHostColor([string]$Value) {
    switch($Value){'Green'{return [TrayColor]::Green}'Yellow'{return [TrayColor]::Yellow}'Red'{return [TrayColor]::Red}default{return [TrayColor]::Gray}}
}
function Convert-CcodTrayHostState([string]$Value) {
    switch($Value){'Inspecting'{return [TrayState]::Inspecting}'Transitioning'{return [TrayState]::Transitioning}'Active'{return [TrayState]::Active}'ActivePaused'{return [TrayState]::ActivePaused}'RendererHandoff'{return [TrayState]::RendererHandoff}'Suppressed'{return [TrayState]::Suppressed}'Recovered'{return [TrayState]::Recovered}'Error'{return [TrayState]::Error}default{return [TrayState]::Waiting}}
}

function New-CcodTrayHostSnapshot {
    param($Presentation,$Catalog,[string]$LanguageMode,[string]$SystemCultureName,[ulong]$Revision)
    $flags=[PresentationFlags]::None
    $flagMap=@{
        SessionReadyVisible=[PresentationFlags]::SessionReadyVisible;ApplyNowVisible=[PresentationFlags]::ApplyNowVisible;ApplyNowEnabled=[PresentationFlags]::ApplyNowEnabled
        ManualRetryVisible=[PresentationFlags]::ManualRetryVisible;ManualRetryEnabled=[PresentationFlags]::ManualRetryEnabled;AutomationToggleEnabled=[PresentationFlags]::AutomationToggleEnabled
        AutomationChecked=[PresentationFlags]::AutomationChecked;CandidateOptInToggleEnabled=[PresentationFlags]::CandidateOptInToggleEnabled;CandidateOptInChecked=[PresentationFlags]::CandidateOptInChecked
        OpenLogsEnabled=[PresentationFlags]::OpenLogsEnabled;UninstallEnabled=[PresentationFlags]::UninstallEnabled;Busy=[PresentationFlags]::Busy
    }
    foreach($pair in @(
        @('SessionReadyVisible','SessionReadyVisible'),@('ApplyNowVisible','ApplyNowVisible'),@('ApplyNowEnabled','ApplyNowEnabled'),
        @('ManualRetryVisible','ManualRetryVisible'),@('ManualRetryEnabled','ManualRetryEnabled'),@('AutomationToggleEnabled','AutomationToggleEnabled'),
        @('AutomationChecked','AutomationChecked'),@('CandidateOptInToggleEnabled','CandidateOptInToggleEnabled'),@('CandidateOptInChecked','CandidateOptInChecked'),
        @('OpenLogsEnabled','OpenLogsEnabled'),@('UninstallEnabled','UninstallEnabled'),@('Busy','Busy'))){
        if($Presentation.($pair[0]) -is [bool] -and $Presentation.($pair[0])){$flags=[PresentationFlags]([int]$flags -bor [int]$flagMap[$pair[1]])}
    }
    $stateKey=[string]$Presentation.StateKey
    $systemLanguage=if([string]$SystemCultureName -cmatch '^zh(?:-|$)'){$Catalog.Strings.'Menu.Chinese'}else{$Catalog.Strings.'Menu.English'}
    $follow=Get-CcodUiString -Catalog $Catalog -Key 'Menu.FollowSystem' -Arguments @($systemLanguage)
    $tooltipKey='Tooltip.'+$stateKey
    $tooltip=if($null -ne $Catalog.Strings.PSObject.Properties[$tooltipKey]){$Catalog.Strings.$tooltipKey}else{$Catalog.Strings.'Tooltip.Waiting'}
    $strings=[string[]]@(
        $Catalog.Strings.'Tray.Title',
        $Catalog.Strings.('Status.'+$stateKey),
        $Catalog.Strings.'Menu.SessionReady',
        $Catalog.Strings.'Menu.ApplyNow',
        $Catalog.Strings.'Menu.ManualRetry',
        $Catalog.Strings.'Menu.Automation',
        $Catalog.Strings.'Menu.CandidateOptIn',
        $Catalog.Strings.'Menu.Language',
        $follow,
        $Catalog.Strings.'Menu.Chinese',
        $Catalog.Strings.'Menu.English',
        $Catalog.Strings.'Menu.OpenLogs',
        $Catalog.Strings.'Menu.Uninstall',
        $Catalog.Strings.'Error.UninstallStart',
        $Catalog.Strings.'Menu.Uninstall',
        $tooltip,
        $Catalog.Strings.'Dialog.UninstallTitle',
        $Catalog.Strings.'Dialog.UninstallMessage'
    )
    $mode=if($LanguageMode -ceq 'zh-CN'){[LanguageMode]::Chinese}elseif($LanguageMode -ceq 'en-US'){[LanguageMode]::English}else{[LanguageMode]::System}
    return [PresentationSnapshot]::new($Revision,(Convert-CcodTrayHostColor $Presentation.Color),(Convert-CcodTrayHostState $stateKey),$mode,$flags,$strings)
}

function New-CcodTrayHostContext {
    param($CommandQueue,$OnTick,$Catalog,[string]$LanguageMode,[string]$SystemCultureName)
    Import-CcodTrayHostAssembly
    $runtimeRoot=Get-CcodTrayHostRuntimeRoot;$runtimeId=Split-Path $runtimeRoot -Leaf;$exe=Join-Path $runtimeRoot 'trayhost\CodexRemote.TrayHost.exe'
    $initialPresentation=[pscustomobject][ordered]@{Color='Gray';StateKey='Waiting';SessionReadyVisible=$false;ApplyNowVisible=$false;ApplyNowEnabled=$false;ManualRetryVisible=$false;ManualRetryEnabled=$false;AutomationToggleEnabled=$true;AutomationChecked=$false;CandidateOptInToggleEnabled=$true;CandidateOptInChecked=$false;OpenLogsEnabled=$true;UninstallEnabled=$true;Busy=$false}
    $initial=New-CcodTrayHostSnapshot $initialPresentation $Catalog $LanguageMode $SystemCultureName ([ulong]1)
    $process=[Diagnostics.Process]::GetCurrentProcess()
    try{
        $options=[TrayHostStartOptions]::new();$options.ExePath=$exe;$options.RuntimeId=$runtimeId;$options.ParentPid=$process.Id;$options.ParentCreationFileTimeUtc=$process.StartTime.ToFileTimeUtc();$options.InitialPresentation=$initial
        $client=[TrayHostParentClient]::Start($options)
    }finally{$process.Dispose()}
    return [pscustomobject][ordered]@{Client=$client;CommandQueue=$CommandQueue;OnTick=$OnTick;Catalog=$Catalog;LanguageMode=$LanguageMode;SystemCultureName=$SystemCultureName;CurrentRevision=[ulong]1;MenuOpen=$false;Exited=$false;LastError=$null;ApplicationContext=[pscustomobject]@{}}
}

function Set-CcodTrayHostPresentation {
    param($Context,$Presentation,$Catalog,[string]$LanguageMode,[string]$SystemCultureName)
    if($null -eq $Context -or $null -eq $Context.Client){throw 'CCOD_TRAYHOST_CONTEXT_INVALID'}
    $revision=[ulong]([ulong]$Context.CurrentRevision + [ulong]1)
    $snapshot=New-CcodTrayHostSnapshot $Presentation $Catalog $LanguageMode $SystemCultureName $revision
    if(-not $Context.Client.TryPublish($snapshot)){throw 'CCOD_TRAYHOST_PRESENTATION_FAILED'}
    $Context.Catalog=$Catalog;$Context.LanguageMode=$LanguageMode;$Context.SystemCultureName=$SystemCultureName;$Context.CurrentRevision=$revision
}

function Receive-CcodTrayHostEvents {
    param($Context)
    while($true){
        $event=$null
        if(-not $Context.Client.TryDequeueEvent([ref]$event)){break}
        if($null -eq $event){continue}
        switch($event.Kind.ToString()){
            'PresentationAck'{}
            'Action' {
                $kind=switch($event.Command){ApplyNow{'ApplyNow'}ManualRetry{'ManualRetry'}SetAutomation{'SetAutomationEnabled'}SetCandidateOptIn{'SetCandidateCompatibleOptIn'}SetLanguageSystem{'SetUiLanguage'}SetLanguageChinese{'SetUiLanguage'}SetLanguageEnglish{'SetUiLanguage'}OpenLogs{'OpenLogs'}ConfirmUninstall{'Uninstall'}default{$null}}
                if($null -ne $kind){$value=$null;if($kind -ceq 'SetAutomationEnabled'){$value=[bool]$event.BoolValue}elseif($kind -ceq 'SetCandidateCompatibleOptIn'){$value=[bool]$event.BoolValue}elseif($kind -ceq 'SetUiLanguage'){$value=switch($event.Command){SetLanguageSystem{'System'}SetLanguageChinese{'zh-CN'}default{'en-US'}};$queueValue=[pscustomobject][ordered]@{Kind=$kind;Value=$value;EnqueuedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)};[void]$Context.CommandQueue.Enqueue($queueValue);continue};$queueValue=[pscustomobject][ordered]@{Kind=$kind;Value=$value;EnqueuedAtUtc=[DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)};[void]$Context.CommandQueue.Enqueue($queueValue)}
            }
            'Exited' {$Context.Exited=$true}
            'Fault' {$Context.LastError=$event.ErrorCode;$Context.Exited=$true}
        }
    }
}

function Invoke-CcodTrayHostRunLoop {
    param($Context)
    while(-not $Context.Exited){
        Receive-CcodTrayHostEvents $Context
        if($Context.Exited){break}
        & $Context.OnTick $false
        Receive-CcodTrayHostEvents $Context
        if($Context.Exited){break}
        [void]$Context.Client.WaitForActivity([TimeSpan]::FromMilliseconds(250))
    }
}

function Request-CcodTrayHostExit { param($Context) if($null -ne $Context -and $null -ne $Context.Client){[void]$Context.Client.BeginShutdown([ShutdownReason]::SupervisorExit,[ulong]$Context.CurrentRevision);$Context.Exited=$true} }
function Close-CcodTrayHostContext { param($Context) if($null -ne $Context -and $null -ne $Context.Client){$Context.Client.Dispose();$Context.Client=$null};if($null -ne $Context){$Context.Exited=$true} }
function Show-CcodTrayHostError { param($Context,$Catalog,$Key) if($null -ne $Context){$Context.LastError=$Key} }
function End-CcodTrayHostMenu { param($Context) return $true }

Export-ModuleMember -Function New-CcodTrayHostContext,Set-CcodTrayHostPresentation,Invoke-CcodTrayHostRunLoop,Request-CcodTrayHostExit,Close-CcodTrayHostContext,Show-CcodTrayHostError,End-CcodTrayHostMenu
