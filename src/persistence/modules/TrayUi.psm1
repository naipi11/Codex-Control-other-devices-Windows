Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'UiLocalization.psm1') -ErrorAction Stop

$script:TrayAdapterNames=@(
    'GetUtcNow','GetQueueCount','TryEnqueue','TryDequeue','GetManagedThreadId','GetApartmentState',
    'CreateUiObject','AddUiChild','SetUiProperty','GetUiProperty','SetUiVisible','StartUiTimer','StopUiTimer',
    'AttachUiCallback','DetachUiCallback','DisposeUiObject','ExitUiContext','ShowErrorDialog','ConfirmUninstall',
    'CreateBitmap','DrawBridgeIcon','GetHicon','CloneIcon','CloneIconBitmap','CreateBoldFont','DestroyIcon','DisposeIconResource',
    'NewSourceIdentifier','RegisterTrace','RegisterIntrinsic','CleanupWatcherAttempt','DetachWatcherCallback','UnregisterWatcher',
    'RemoveWatcherJob','DisposeWatcherResource'
)
$script:TrayUiLanguageModes=@('System','zh-CN','en-US')
$script:TrayUiCatalogKeys=@(
    'Tray.Title','Status.Waiting','Status.Inspecting','Status.Transitioning','Status.Active','Status.ActivePaused','Status.Suppressed','Status.Recovered','Status.Error',
    'Tooltip.Waiting','Tooltip.Inspecting','Tooltip.Transitioning','Tooltip.Active','Tooltip.ActivePaused','Tooltip.Suppressed','Tooltip.Recovered','Tooltip.Error',
    'Menu.SessionReady','Menu.ApplyNow','Menu.ManualRetry','Menu.Automation','Menu.CandidateOptIn','Menu.Language','Menu.FollowSystem','Menu.Chinese','Menu.English','Menu.OpenLogs','Menu.Uninstall',
    'Dialog.UninstallTitle','Dialog.UninstallMessage','Error.UninstallStart','Error.LanguageChange'
)
$script:TrayCleanupCodeAllowlist=@(
    'CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED','CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED','CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED',
    'CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED','CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED','CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED',
    'CCOD_TRAY_CLEANUP_CONTROL_DISPOSE_FAILED','CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED','CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED','CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED'
)
$script:WatcherCleanupCodeAllowlist=@(
    'CCOD_WATCHER_CLEANUP_ATTEMPT_FAILED',
    'CCOD_WATCHER_CLEANUP_CALLBACK_DETACH_FAILED','CCOD_WATCHER_CLEANUP_UNREGISTER_FAILED','CCOD_WATCHER_CLEANUP_JOB_REMOVE_FAILED',
    'CCOD_WATCHER_CLEANUP_RESOURCE_DISPOSE_FAILED','CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED','CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_LIMIT'
)

function Throw-CcodTrayError {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][ValidateSet('Tray','Watcher')][string]$Surface)
    $message=if($Surface -ceq 'Watcher'){'The process watcher operation failed safely.'}else{'The tray UI operation failed safely.'}
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($message),$Code,[Management.Automation.ErrorCategory]::InvalidOperation,$null
    )
}

function Test-CcodExactProperties {
    param($Value,[string[]]$Names)
    if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
    $actual=@($Value.PSObject.Properties.Name)
    if($actual.Count -ne $Names.Count){return $false}
    for($i=0;$i -lt $Names.Count;$i++){
        if($actual[$i] -cne $Names[$i] -or $Value.PSObject.Properties[$actual[$i]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){return $false}
    }
    return $true
}

function Test-CcodDiagnosticRecord {
    param($Value)
    return $Value -is [Management.Automation.ErrorRecord] -or $Value -is [Management.Automation.WarningRecord] -or
        $Value -is [Management.Automation.VerboseRecord] -or $Value -is [Management.Automation.DebugRecord] -or
        $Value -is [Management.Automation.InformationRecord]
}

function Test-CcodTrayCatalog {
    param($Catalog,[AllowNull()][string]$ExpectedMode=$null)
    try{
        if(-not (Test-CcodExactProperties $Catalog @('LanguageMode','EffectiveLocale','Strings','UsedEmergencyCatalog','ErrorCode')) -or
           $Catalog.LanguageMode -isnot [string] -or $script:TrayUiLanguageModes -cnotcontains $Catalog.LanguageMode -or
           (-not [string]::IsNullOrEmpty($ExpectedMode) -and $Catalog.LanguageMode -cne $ExpectedMode) -or
           $Catalog.EffectiveLocale -isnot [string] -or @('zh-CN','en-US') -cnotcontains $Catalog.EffectiveLocale -or
           $Catalog.UsedEmergencyCatalog -isnot [bool] -or
           ($null -ne $Catalog.ErrorCode -and ($Catalog.ErrorCode -isnot [string] -or @('','CCOD_UI_RESOURCE_INVALID') -cnotcontains $Catalog.ErrorCode)) -or
           -not (Test-CcodExactProperties $Catalog.Strings $script:TrayUiCatalogKeys)){return $false}
        foreach($key in $script:TrayUiCatalogKeys){
            $value=$Catalog.Strings.PSObject.Properties[$key].Value
            if($value -isnot [string] -or $value.Length -lt 1 -or $value.Length -gt 300 -or (Test-CcodControlCharacter $value)){return $false}
        }
        return $true
    }catch{return $false}
}

function Resolve-CcodTrayLocalizedStrings {
    param($Catalog,[string]$LanguageMode,[string]$SystemCultureName)
    if($script:TrayUiLanguageModes -cnotcontains $LanguageMode -or $SystemCultureName -isnot [string] -or
       $SystemCultureName.Length -lt 1 -or $SystemCultureName.Length -gt 85 -or (Test-CcodControlCharacter $SystemCultureName) -or
       -not (Test-CcodTrayCatalog $Catalog $LanguageMode)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $strings=[ordered]@{}
    try{
        foreach($key in $script:TrayUiCatalogKeys){$strings[$key]=Get-CcodUiString -Catalog $Catalog -Key $key}
        $systemLanguage=if($SystemCultureName -cmatch '^zh(?:-|$)'){$strings['Menu.Chinese']}else{$strings['Menu.English']}
        $strings['Menu.FollowSystem']=Get-CcodUiString -Catalog $Catalog -Key 'Menu.FollowSystem' -Arguments @($systemLanguage)
    }catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    Write-Output -NoEnumerate $strings
}

function Invoke-CcodTrayAdapterCapture {
    param([scriptblock]$Callback,[object[]]$Arguments)
    if($Callback -isnot [scriptblock]){return [pscustomobject]@{Threw=$true;Items=@();OverflowItem=$null}}
    $items=[Collections.Generic.List[object]]::new();$threw=$false;$overflowItem=$null
    $startingErrors=[object[]]@($global:Error)
    $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
    foreach($name in @('ErrorActionPreference','WarningPreference','VerbosePreference','DebugPreference','InformationPreference')){
        $variables.Add([Management.Automation.PSVariable]::new($name,'Continue'))
    }
    $invoker={param($InnerCallback,$InnerVariables,$InnerArguments)$InnerCallback.InvokeWithContext($null,$InnerVariables,[object[]]$InnerArguments)}
    try{
        & $invoker $Callback $variables $Arguments *>&1|ForEach-Object{
            if($items.Count -ge 16){$overflowItem=$_;throw 'adapter output limit exceeded'}
            $items.Add($_)
        }
    }catch{$threw=$true}
    finally{
        $errorHistoryChanged=$global:Error.Count -ne $startingErrors.Count
        if(-not $errorHistoryChanged){
            for($index=0;$index -lt $startingErrors.Count;$index++){
                if(-not [object]::ReferenceEquals($startingErrors[$index],$global:Error[$index])){$errorHistoryChanged=$true;break}
            }
        }
        if($errorHistoryChanged){$threw=$true}
        $global:Error.Clear()
        foreach($startingError in $startingErrors){[void]$global:Error.Add($startingError)}
    }
    return [pscustomobject]@{Threw=[bool]$threw;Items=@($items);OverflowItem=$overflowItem}
}

function Invoke-CcodTrayAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[int]$OutputCount,[string]$FailureCode,[string]$Surface='Tray')
    $capture=Invoke-CcodTrayAdapterCapture $Callback $Arguments
    if($capture.Threw){Throw-CcodTrayError $FailureCode $Surface}
    foreach($item in $capture.Items){if(Test-CcodDiagnosticRecord $item){Throw-CcodTrayError $FailureCode $Surface}}
    if($capture.Items.Count -ne $OutputCount){Throw-CcodTrayError $FailureCode $Surface}
    if($OutputCount -eq 1){return $capture.Items[0]}
}

function Invoke-CcodTraySideEffectAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments)
    $capture=Invoke-CcodTrayAdapterCapture $Callback $Arguments
    $succeeded=-not $capture.Threw -and $capture.Items.Count -eq 0
    foreach($item in $capture.Items){if(Test-CcodDiagnosticRecord $item){$succeeded=$false}}
    return [pscustomobject][ordered]@{Completed=[bool](-not $capture.Threw);Succeeded=[bool]$succeeded}
}

function Invoke-CcodTrayUninstallConfirmation {
    param(
        [Parameter(Mandatory)][string]$Title,[Parameter(Mandatory)][string]$Message,
        [AllowNull()][scriptblock]$ShowDialog=$null
    )
    if($null -eq $ShowDialog){
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        return [bool]([Windows.Forms.MessageBox]::Show(
            $Message,$Title,
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning,
            [Windows.Forms.MessageBoxDefaultButton]::Button2
        ) -eq [Windows.Forms.DialogResult]::Yes)
    }
    $result=& $ShowDialog $Message $Title ([Windows.Forms.MessageBoxButtons]::YesNo) ([Windows.Forms.MessageBoxIcon]::Warning) ([Windows.Forms.MessageBoxDefaultButton]::Button2)
    return [bool]($result -eq [Windows.Forms.DialogResult]::Yes)
}

function Invoke-CcodOwnedTrayAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[scriptblock]$CleanupCallback,[scriptblock]$Validator,[string]$FailureCode,[string]$Surface='Tray')
    $capture=Invoke-CcodTrayAdapterCapture $Callback $Arguments
    $outputs=@($capture.Items|Where-Object {-not (Test-CcodDiagnosticRecord $_)})
    $cleanupOutputs=@($outputs)
    if($null -ne $capture.OverflowItem -and -not (Test-CcodDiagnosticRecord $capture.OverflowItem)){$cleanupOutputs+=@($capture.OverflowItem)}
    $valid=$false
    if(-not $capture.Threw -and $capture.Items.Count -eq 1 -and $outputs.Count -eq 1){
        try{$validation=@(& $Validator $outputs[0]);$valid=$validation.Count -eq 1 -and $validation[0] -is [bool] -and $validation[0]}catch{$valid=$false}
    }
    if(-not $valid){
        $cleanupCandidates=[Collections.Generic.List[object]]::new()
        foreach($candidate in @($cleanupOutputs|Select-Object -First 17)){
            $recognizable=$false
            try{$candidateValidation=@(& $Validator $candidate);$recognizable=$candidateValidation.Count -eq 1 -and $candidateValidation[0] -is [bool] -and $candidateValidation[0]}catch{$recognizable=$false}
            $duplicate=$false
            if($recognizable){
                foreach($existing in $cleanupCandidates){
                    if([object]::ReferenceEquals($existing,$candidate) -or ($existing.GetType().IsValueType -and $existing.Equals($candidate))){$duplicate=$true;break}
                }
            }
            if($recognizable -and -not $duplicate){
                $cleanupCandidates.Add($candidate)
                $cleanupArguments=[object[]]::new(1);$cleanupArguments[0]=$candidate
                try{Invoke-CcodTrayAdapter $CleanupCallback $cleanupArguments 0 $FailureCode $Surface}catch{}
            }
        }
        Throw-CcodTrayError $FailureCode $Surface
    }
    return $outputs[0]
}

function Get-CcodTrayDefaultAdapters {
    $defaults=@{}
    $watcherAttemptJobs=@{}
    $watcherAttemptJobLimit=16
    $defaults.GetUtcNow={ [DateTimeOffset]::UtcNow }
    $defaults.GetQueueCount={param($Queue)[int]$Queue.Count}
    $defaults.TryEnqueue={param($Queue,$Value)$Queue.Enqueue($Value);$true}
    $defaults.TryDequeue={
        param($Queue)
        $value=$null
        if($Queue -is [Collections.Concurrent.ConcurrentQueue[object]]){$ok=$Queue.TryDequeue([ref]$value)}
        elseif($Queue.Count -gt 0){$value=$Queue.Dequeue();$ok=$true}else{$ok=$false}
        [pscustomobject][ordered]@{Succeeded=[bool]$ok;Value=$value}
    }
    $defaults.GetManagedThreadId={[int][Threading.Thread]::CurrentThread.ManagedThreadId}
    $defaults.GetApartmentState={[string][Threading.Thread]::CurrentThread.GetApartmentState()}
    $defaults.CreateUiObject={
        param($Kind,$Name)
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        switch($Kind){
            'ApplicationContext' {$object=New-Object Windows.Forms.ApplicationContext}
            'Timer' {$object=New-Object Windows.Forms.Timer}
            'NotifyIcon' {$object=New-Object Windows.Forms.NotifyIcon}
            'Menu' {$object=New-Object Windows.Forms.ContextMenuStrip}
            'Row' {$object=New-Object Windows.Forms.ToolStripMenuItem}
            'MenuItem' {$object=New-Object Windows.Forms.ToolStripMenuItem}
            'Separator' {$object=New-Object Windows.Forms.ToolStripSeparator}
            default {throw 'unsupported UI object kind'}
        }
        if($object.PSObject.Properties['Name']){$object.Name=$Name}
        $object
    }
    $defaults.AddUiChild={param($Parent,$Child)[void]$Parent.Items.Add($Child)}
    $defaults.SetUiProperty={param($Object,$Name,$Value)$Object.PSObject.Properties[$Name].Value=$Value}
    $defaults.GetUiProperty={param($Object,$Name)$Object.PSObject.Properties[$Name].Value}
    $defaults.SetUiVisible={param($Object,$Visible)$Object.Visible=[bool]$Visible}
    $defaults.StartUiTimer={param($Timer)$Timer.Start()}
    $defaults.StopUiTimer={param($Timer)$Timer.Stop()}
    $defaults.AttachUiCallback={
        param($Object,$EventName,$Callback)
        $handler=[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure()
        if($EventName -ceq 'Tick'){$Object.add_Tick($handler)}else{$Object.add_Click($handler)}
        [pscustomobject][ordered]@{Target=$Object;EventName=$EventName;Handler=$handler}
    }
    $defaults.DetachUiCallback={
        param($Attachment)
        if($Attachment.EventName -ceq 'Tick'){$Attachment.Target.remove_Tick($Attachment.Handler)}else{$Attachment.Target.remove_Click($Attachment.Handler)}
    }
    $defaults.DisposeUiObject={param($Object)$Object.Dispose()}
    $defaults.ExitUiContext={param($Context)$Context.ExitThread()}
    $defaults.ShowErrorDialog={
        param($Title,$Message)
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [Windows.Forms.MessageBox]::Show($Message,$Title,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
    }
    $defaults.ConfirmUninstall={param($Title,$Message)Invoke-CcodTrayUninstallConfirmation -Title $Title -Message $Message}
    $defaults.CreateBitmap={param($Color,$Size)Add-Type -AssemblyName System.Drawing -ErrorAction Stop;New-Object Drawing.Bitmap($Size,$Size)}
    $defaults.DrawBridgeIcon={
        param($Bitmap,$Color,$Size)
        $palette=@{
            Gray=[Drawing.Color]::FromArgb(255,138,144,153)
            Green=[Drawing.Color]::FromArgb(255,41,179,111)
            Yellow=[Drawing.Color]::FromArgb(255,227,160,8)
            Red=[Drawing.Color]::FromArgb(255,217,74,74)
        }
        $graphics=$null;$basePath=$null;$baseBrush=$null;$linkOnePath=$null;$linkTwoPath=$null;$linkPen=$null;$dotBrush=$null;$dotOutlinePen=$null
        try{
            $graphics=[Drawing.Graphics]::FromImage($Bitmap)
            $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.Clear([Drawing.Color]::Transparent)
            $scale=[single]($Size/32.0)

            $basePath=[Drawing.Drawing2D.GraphicsPath]::new()
            $baseX=[single](2*$scale);$baseY=[single](2*$scale);$baseWidth=[single](28*$scale);$baseHeight=[single](28*$scale);$baseCorner=[single](8*$scale)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX,$baseY,$baseCorner,$baseCorner),180,90)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX+$baseWidth-$baseCorner,$baseY,$baseCorner,$baseCorner),270,90)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX+$baseWidth-$baseCorner,$baseY+$baseHeight-$baseCorner,$baseCorner,$baseCorner),0,90)
            $basePath.AddArc([Drawing.RectangleF]::new($baseX,$baseY+$baseHeight-$baseCorner,$baseCorner,$baseCorner),90,90)
            $basePath.CloseFigure()
            $baseBrush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255,32,37,45))
            $graphics.FillPath($baseBrush,$basePath)

            $linkOnePath=[Drawing.Drawing2D.GraphicsPath]::new()
            $linkOneX=[single](6.5*$scale);$linkOneY=[single](12.5*$scale);$linkWidth=[single](14*$scale);$linkHeight=[single](8.5*$scale)
            $linkOnePath.AddArc([Drawing.RectangleF]::new($linkOneX,$linkOneY,$linkHeight,$linkHeight),90,180)
            $linkOnePath.AddLine($linkOneX+($linkHeight/2),$linkOneY,$linkOneX+$linkWidth-($linkHeight/2),$linkOneY)
            $linkOnePath.AddArc([Drawing.RectangleF]::new($linkOneX+$linkWidth-$linkHeight,$linkOneY,$linkHeight,$linkHeight),270,180)
            $linkOnePath.AddLine($linkOneX+$linkWidth-($linkHeight/2),$linkOneY+$linkHeight,$linkOneX+($linkHeight/2),$linkOneY+$linkHeight)
            $linkOnePath.CloseFigure()

            $linkTwoPath=[Drawing.Drawing2D.GraphicsPath]::new()
            $linkTwoX=[single](11.5*$scale);$linkTwoY=[single](9*$scale)
            $linkTwoPath.AddArc([Drawing.RectangleF]::new($linkTwoX,$linkTwoY,$linkHeight,$linkHeight),90,180)
            $linkTwoPath.AddLine($linkTwoX+($linkHeight/2),$linkTwoY,$linkTwoX+$linkWidth-($linkHeight/2),$linkTwoY)
            $linkTwoPath.AddArc([Drawing.RectangleF]::new($linkTwoX+$linkWidth-$linkHeight,$linkTwoY,$linkHeight,$linkHeight),270,180)
            $linkTwoPath.AddLine($linkTwoX+$linkWidth-($linkHeight/2),$linkTwoY+$linkHeight,$linkTwoX+($linkHeight/2),$linkTwoY+$linkHeight)
            $linkTwoPath.CloseFigure()

            $linkPen=[Drawing.Pen]::new([Drawing.Color]::White,[single](2.4*$scale))
            $linkPen.LineJoin=[Drawing.Drawing2D.LineJoin]::Round
            $graphics.DrawPath($linkPen,$linkOnePath)
            $graphics.DrawPath($linkPen,$linkTwoPath)

            $dotBrush=[Drawing.SolidBrush]::new($palette[$Color])
            $dotOutlinePen=[Drawing.Pen]::new([Drawing.Color]::White,[single](1.0*$scale))
            $dotBounds=[Drawing.RectangleF]::new([single](22*$scale),[single](22*$scale),[single](7*$scale),[single](7*$scale))
            $graphics.FillEllipse($dotBrush,$dotBounds)
            $graphics.DrawEllipse($dotOutlinePen,$dotBounds)
        }finally{
            if($null -ne $dotOutlinePen){$dotOutlinePen.Dispose()}
            if($null -ne $dotBrush){$dotBrush.Dispose()}
            if($null -ne $linkPen){$linkPen.Dispose()}
            if($null -ne $linkTwoPath){$linkTwoPath.Dispose()}
            if($null -ne $linkOnePath){$linkOnePath.Dispose()}
            if($null -ne $baseBrush){$baseBrush.Dispose()}
            if($null -ne $basePath){$basePath.Dispose()}
            if($null -ne $graphics){$graphics.Dispose()}
        }
    }
    $defaults.GetHicon={param($Bitmap)$Bitmap.GetHicon()}
    $defaults.CloneIcon={
        param($Hicon,$Color,$Size)
        $temporary=$null
        try{
            $temporary=[Drawing.Icon]::FromHandle($Hicon)
            $temporary.Clone()
        }finally{
            if($null -ne $temporary){$temporary.Dispose()}
        }
    }
    $defaults.CloneIconBitmap={param($Icon)$Icon.ToBitmap()}
    $defaults.CreateBoldFont={param($Font)Add-Type -AssemblyName System.Drawing -ErrorAction Stop;[Drawing.Font]::new($Font,[Drawing.FontStyle]::Bold)}
    $defaults.DestroyIcon={
        param($Hicon)
        if(-not ('CcodTrayNativeMethods' -as [type])){Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class CcodTrayNativeMethods { [DllImport("user32.dll", SetLastError=true)] public static extern bool DestroyIcon(IntPtr hIcon); }' -ErrorAction Stop}
        if(-not [CcodTrayNativeMethods]::DestroyIcon($Hicon)){throw 'DestroyIcon failed'}
    }
    $defaults.DisposeIconResource={param($Resource)$Resource.Dispose()}
    $defaults.NewSourceIdentifier={'ccod-process-'+[guid]::NewGuid().ToString('N')}
    $defaults.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $job=Register-WmiEvent -Class $ClassName -SourceIdentifier $SourceIdentifier -MessageData $Callback -Action {
            $processId=$Event.SourceEventArgs.NewEvent.ProcessID
            $name=$Event.SourceEventArgs.NewEvent.ProcessName
            & $Event.MessageData $processId $name
        }
        $jobId=[int]$job.Id
        $jobs=[Collections.Generic.Dictionary[int,bool]]::new();$jobs.Add($jobId,$true)
        $watcherAttemptJobs[$SourceIdentifier]=[pscustomobject]@{SubscriberPending=$true;Jobs=$jobs}
        [pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=$jobId;Resource=$job}
    }.GetNewClosure()
    $defaults.RegisterIntrinsic={
        param($SourceIdentifier,$Query,$Callback)
        $job=Register-WmiEvent -Query $Query -SourceIdentifier $SourceIdentifier -MessageData $Callback -Action {
            $processId=$Event.SourceEventArgs.NewEvent.TargetInstance.ProcessId
            $name=$Event.SourceEventArgs.NewEvent.TargetInstance.Name
            & $Event.MessageData $processId $name
        }
        $jobId=[int]$job.Id
        $jobs=[Collections.Generic.Dictionary[int,bool]]::new();$jobs.Add($jobId,$true)
        $watcherAttemptJobs[$SourceIdentifier]=[pscustomobject]@{SubscriberPending=$true;Jobs=$jobs}
        [pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=$jobId;Resource=$job}
    }.GetNewClosure()
    $defaults.CleanupWatcherAttempt={
        param($SourceIdentifier)
        try{
            $subscribers=@(Get-EventSubscriber -ErrorAction Stop|Where-Object {$_.SourceIdentifier -is [string] -and $_.SourceIdentifier -ceq $SourceIdentifier}|Select-Object -First ($watcherAttemptJobLimit+1))
        }catch{throw 'watcher attempt cleanup failed'}
        if($subscribers.Count -gt $watcherAttemptJobLimit){throw 'watcher attempt cleanup failed'}
        $discovered=[Collections.Generic.HashSet[int]]::new()
        foreach($subscriber in $subscribers){
            if($null -eq $subscriber.Action -or $subscriber.Action.Id -isnot [int] -or $subscriber.Action.Id -le 0 -or -not $discovered.Add([int]$subscriber.Action.Id)){
                if($null -eq $subscriber.Action -or $subscriber.Action.Id -isnot [int] -or $subscriber.Action.Id -le 0){throw 'watcher attempt cleanup failed'}
            }
        }
        $entry=if($watcherAttemptJobs.ContainsKey($SourceIdentifier)){$watcherAttemptJobs[$SourceIdentifier]}else{$null}
        if($null -eq $entry -and $subscribers.Count -eq 0){return}
        if($null -eq $entry){
            $entry=[pscustomobject]@{SubscriberPending=$false;Jobs=[Collections.Generic.Dictionary[int,bool]]::new()}
            $watcherAttemptJobs[$SourceIdentifier]=$entry
        }
        foreach($jobId in $discovered){
            if(-not $entry.Jobs.ContainsKey($jobId)){
                if($entry.Jobs.Count -ge $watcherAttemptJobLimit){throw 'watcher attempt cleanup failed'}
                $entry.Jobs.Add($jobId,$true)
            }else{$entry.Jobs[$jobId]=$true}
        }
        if($subscribers.Count -gt 0){$entry.SubscriberPending=$true}

        $failed=$false
        if($entry.SubscriberPending){
            if($subscribers.Count -gt 0){
                try{Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction Stop;$entry.SubscriberPending=$false}catch{$failed=$true}
            }else{$entry.SubscriberPending=$false}
        }
        if(-not $entry.SubscriberPending){
            foreach($jobId in @($entry.Jobs.Keys|Sort-Object)){
                if(-not $entry.Jobs[$jobId]){continue}
                try{$jobs=@(Get-Job -ErrorAction Stop|Where-Object {$_.Id -is [int] -and $_.Id -eq $jobId}|Select-Object -First 2)}catch{$failed=$true;continue}
                if($jobs.Count -eq 0){$entry.Jobs[$jobId]=$false;continue}
                if($jobs.Count -gt 1){$failed=$true;continue}
                try{Remove-Job -Id $jobId -Force -ErrorAction Stop;$entry.Jobs[$jobId]=$false}catch{$failed=$true}
            }
        }
        if($failed){throw 'watcher attempt cleanup failed'}
        $pendingJobs=@($entry.Jobs.Values|Where-Object {$_}).Count
        if(-not $entry.SubscriberPending -and $pendingJobs -eq 0){[void]$watcherAttemptJobs.Remove($SourceIdentifier)}
    }.GetNewClosure()
    $defaults.DetachWatcherCallback={param($Receipt)}
    $defaults.UnregisterWatcher={param($SourceIdentifier)Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction Stop}
    $defaults.RemoveWatcherJob={param($JobId)Remove-Job -Id $JobId -Force -ErrorAction Stop}
    $defaults.DisposeWatcherResource={param($Resource)if($Resource -is [IDisposable]){$Resource.Dispose()}}
    return $defaults
}

function Get-CcodTrayAdapters {
    param($Adapters,[string]$ErrorCode,[string]$Surface='Tray')
    if($null -ne $Adapters -and $Adapters -isnot [hashtable]){Throw-CcodTrayError $ErrorCode $Surface}
    $result=Get-CcodTrayDefaultAdapters
    if($null -ne $Adapters){
        foreach($name in $Adapters.Keys){
            if($name -isnot [string] -or $script:TrayAdapterNames -cnotcontains $name -or $Adapters[$name] -isnot [scriptblock]){Throw-CcodTrayError $ErrorCode $Surface}
            $result[$name]=$Adapters[$name]
        }
    }
    return $result
}

function Get-CcodCanonicalUtc {
    param($Adapters,[string]$FailureCode,[string]$Surface='Tray')
    $now=Invoke-CcodTrayAdapter $Adapters.GetUtcNow @() 1 $FailureCode $Surface
    if($now -isnot [DateTimeOffset] -or $now.Offset -ne [TimeSpan]::Zero){Throw-CcodTrayError $FailureCode $Surface}
    return $now.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}

function Test-CcodAdapterSet {
    param($Adapters)
    try{
        if($Adapters -isnot [hashtable] -or $Adapters.Count -ne $script:TrayAdapterNames.Count){return $false}
        foreach($key in @($Adapters.Keys)){
            if($key -isnot [string] -or $script:TrayAdapterNames -cnotcontains $key -or $Adapters[$key] -isnot [scriptblock]){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodOrderedKeys {
    param($Dictionary,[string[]]$Names)
    try{
        if($Dictionary -isnot [Collections.Specialized.OrderedDictionary] -or $Dictionary.Count -ne $Names.Count){return $false}
        $actual=@($Dictionary.Keys)
        for($index=0;$index -lt $Names.Count;$index++){if($actual[$index] -isnot [string] -or $actual[$index] -cne $Names[$index]){return $false}}
        return $true
    }catch{return $false}
}

function Test-CcodCleanupReceipt {
    param($Receipt,[ValidateSet('Closed','Stopped')][string]$Terminal,[string[]]$Allowlist)
    try{
        if($null -eq $Receipt){return $true}
        if(-not (Test-CcodExactProperties $Receipt @('SchemaVersion',$Terminal,'CleanupCodes')) -or
           $Receipt.SchemaVersion -isnot [int] -or $Receipt.SchemaVersion -ne 1 -or $Receipt.$Terminal -isnot [bool] -or -not $Receipt.$Terminal -or
           $Receipt.CleanupCodes -isnot [array]){return $false}
        $codes=@($Receipt.CleanupCodes)
        if($codes.Count -gt 16){return $false}
        foreach($code in $codes){if($code -isnot [string] -or $Allowlist -cnotcontains $code){return $false}}
        return $true
    }catch{return $false}
}

function Test-CcodContextObject {
    param($Context)
    try{
        $names=@(
            'SchemaVersion','State','OwnerManagedThreadId','CommandQueue','CommandOverflowed','CallbackFailure','QueueGate','CloseGate','OnTick','Adapters',
            'ApplicationContext','Timer','NotifyIcon','Menu','Rows','Items','LanguageItems','Separators','UnownedControls','Icons','TitleImage','TitleFont','Callbacks','CommandValues','CleanupCodes','CloseReceipt'
        )
        if(-not (Test-CcodExactProperties $Context $names) -or $Context.PSObject.TypeNames -cnotcontains 'Ccod.TrayContext'){return $false}
        if($Context.SchemaVersion -isnot [int] -or $Context.SchemaVersion -ne 1 -or $Context.State -isnot [string] -or
           @('Creating','Open','Closing','Closed') -cnotcontains $Context.State -or $Context.OwnerManagedThreadId -isnot [int] -or $Context.OwnerManagedThreadId -le 0 -or
           $null -eq $Context.CommandQueue -or $Context.CommandOverflowed -isnot [bool] -or $Context.CallbackFailure -isnot [bool] -or
           $null -eq $Context.QueueGate -or $Context.QueueGate.GetType() -ne [object] -or $null -eq $Context.CloseGate -or $Context.CloseGate.GetType() -ne [object] -or
            -not (Test-CcodAdapterSet $Context.Adapters) -or $Context.Rows -isnot [Collections.Specialized.OrderedDictionary] -or
            $Context.Items -isnot [Collections.Specialized.OrderedDictionary] -or $Context.LanguageItems -isnot [Collections.Specialized.OrderedDictionary] -or
            $Context.Separators -isnot [Collections.Specialized.OrderedDictionary] -or $Context.UnownedControls -isnot [Collections.Generic.List[object]] -or
           $Context.Icons -isnot [Collections.Specialized.OrderedDictionary] -or $Context.Callbacks -isnot [Collections.Generic.List[object]] -or
           $Context.CleanupCodes -isnot [Collections.Generic.List[string]] -or
           -not (Test-CcodOrderedKeys $Context.CommandValues @('AutomationChecked','CandidateOptInChecked','UninstallTitle','UninstallMessage')) -or
           $Context.CommandValues.AutomationChecked -isnot [bool] -or $Context.CommandValues.CandidateOptInChecked -isnot [bool] -or
           $Context.CommandValues.UninstallTitle -isnot [string] -or $Context.CommandValues.UninstallTitle.Length -lt 1 -or $Context.CommandValues.UninstallTitle.Length -gt 300 -or
           $Context.CommandValues.UninstallMessage -isnot [string] -or $Context.CommandValues.UninstallMessage.Length -lt 1 -or $Context.CommandValues.UninstallMessage.Length -gt 300 -or
           (Test-CcodControlCharacter $Context.CommandValues.UninstallTitle) -or (Test-CcodControlCharacter $Context.CommandValues.UninstallMessage) -or
           -not (Test-CcodCleanupReceipt $Context.CloseReceipt 'Closed' $script:TrayCleanupCodeAllowlist)){return $false}
        if($Context.State -ceq 'Closed'){
            if($null -ne $Context.OnTick -or $null -eq $Context.CloseReceipt){return $false}
        }elseif($Context.State -ceq 'Closing'){
            if(($null -ne $Context.OnTick -and $Context.OnTick -isnot [scriptblock]) -or $null -eq $Context.CloseReceipt){return $false}
        }elseif($Context.OnTick -isnot [scriptblock] -or $null -ne $Context.CloseReceipt){return $false}
        if($Context.State -cne 'Creating'){
            if($null -eq $Context.ApplicationContext -or $null -eq $Context.Timer -or $null -eq $Context.NotifyIcon -or $null -eq $Context.Menu -or
               -not (Test-CcodOrderedKeys $Context.Rows @('Title','Status')) -or
               -not (Test-CcodOrderedKeys $Context.Items @('SessionReady','ApplyNow','ManualRetry','SetAutomationEnabled','SetCandidateCompatibleOptIn','Language','OpenLogs','Uninstall')) -or
               -not (Test-CcodOrderedKeys $Context.LanguageItems @('System','zh-CN','en-US')) -or
               -not (Test-CcodOrderedKeys $Context.Separators @('Status','Preferences','Danger')) -or
               $null -eq $Context.TitleImage -or $null -eq $Context.TitleFont -or
               -not (Test-CcodOrderedKeys $Context.Icons @('Gray:16','Gray:32','Green:16','Green:32','Yellow:16','Yellow:32','Red:16','Red:32'))){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodWatcherObject {
    param($Watcher)
    try{
        $names=@(
            'SchemaVersion','State','Mode','Queue','OnFullReconciliationRequired','QueueGate','StopGate','FullReconciliationNeeded','OverflowEpisodeSignaled',
            'CallbackFailure','Registration','Callback','Adapters','PendingAttemptSources','CapabilityCleanupFailed','CleanupCodes','StopReceipt'
        )
        if(-not (Test-CcodExactProperties $Watcher $names) -or $Watcher.PSObject.TypeNames -cnotcontains 'Ccod.ProcessWatcher'){return $false}
        if($Watcher.SchemaVersion -isnot [int] -or $Watcher.SchemaVersion -ne 1 -or $Watcher.State -isnot [string] -or
           @('Starting','Running','Stopping','Stopped') -cnotcontains $Watcher.State -or $Watcher.Mode -isnot [string] -or
           @('ReconciliationOnly','Trace','Intrinsic') -cnotcontains $Watcher.Mode -or $null -eq $Watcher.Queue -or
           $null -eq $Watcher.QueueGate -or $Watcher.QueueGate.GetType() -ne [object] -or $null -eq $Watcher.StopGate -or $Watcher.StopGate.GetType() -ne [object] -or
           $Watcher.FullReconciliationNeeded -isnot [bool] -or $Watcher.OverflowEpisodeSignaled -isnot [bool] -or $Watcher.CallbackFailure -isnot [bool] -or
           -not (Test-CcodAdapterSet $Watcher.Adapters) -or $Watcher.PendingAttemptSources -isnot [Collections.Generic.List[string]] -or
           $Watcher.PendingAttemptSources.Count -gt 2 -or $Watcher.CapabilityCleanupFailed -isnot [bool] -or
           $Watcher.CleanupCodes -isnot [Collections.Generic.List[string]] -or
           -not (Test-CcodCleanupReceipt $Watcher.StopReceipt 'Stopped' $script:WatcherCleanupCodeAllowlist)){return $false}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($source in $Watcher.PendingAttemptSources){if($source -isnot [string] -or $source -cnotmatch '^ccod-process-[0-9a-f]{32}$' -or -not $seen.Add($source)){return $false}}
        if($null -ne $Watcher.Registration){
            if(-not (Test-CcodExactProperties $Watcher.Registration @('SourceIdentifier','JobId','Resource')) -or
               $Watcher.Registration.SourceIdentifier -isnot [string] -or $Watcher.Registration.SourceIdentifier -cnotmatch '^ccod-process-[0-9a-f]{32}$' -or
               $Watcher.Registration.JobId -isnot [int] -or $Watcher.Registration.JobId -le 0 -or $null -eq $Watcher.Registration.Resource){return $false}
        }
        if($Watcher.State -ceq 'Stopped'){
            if($null -ne $Watcher.Callback -or $null -ne $Watcher.OnFullReconciliationRequired -or $null -eq $Watcher.StopReceipt){return $false}
        }elseif($Watcher.State -ceq 'Stopping'){
            if(($null -ne $Watcher.Callback -and $Watcher.Callback -isnot [scriptblock]) -or
               ($null -ne $Watcher.OnFullReconciliationRequired -and $Watcher.OnFullReconciliationRequired -isnot [scriptblock]) -or
               $null -eq $Watcher.StopReceipt){return $false}
        }elseif($Watcher.Callback -isnot [scriptblock] -or $Watcher.OnFullReconciliationRequired -isnot [scriptblock] -or $null -ne $Watcher.StopReceipt){return $false}
        return $true
    }catch{return $false}
}

function Test-CcodContextGateHandle {
    param($Context)
    try{
        $names=@(
            'SchemaVersion','State','OwnerManagedThreadId','CommandQueue','CommandOverflowed','CallbackFailure','QueueGate','CloseGate','OnTick','Adapters',
            'ApplicationContext','Timer','NotifyIcon','Menu','Rows','Items','LanguageItems','Separators','UnownedControls','Icons','TitleImage','TitleFont','Callbacks','CommandValues','CleanupCodes','CloseReceipt'
        )
        return (Test-CcodExactProperties $Context $names) -and $Context.PSObject.TypeNames -ccontains 'Ccod.TrayContext' -and
            $null -ne $Context.CloseGate -and $Context.CloseGate.GetType() -eq [object]
    }catch{return $false}
}

function Test-CcodWatcherGateHandle {
    param($Watcher)
    try{
        $names=@(
            'SchemaVersion','State','Mode','Queue','OnFullReconciliationRequired','QueueGate','StopGate','FullReconciliationNeeded','OverflowEpisodeSignaled',
            'CallbackFailure','Registration','Callback','Adapters','PendingAttemptSources','CapabilityCleanupFailed','CleanupCodes','StopReceipt'
        )
        return (Test-CcodExactProperties $Watcher $names) -and $Watcher.PSObject.TypeNames -ccontains 'Ccod.ProcessWatcher' -and
            $null -ne $Watcher.StopGate -and $Watcher.StopGate.GetType() -eq [object]
    }catch{return $false}
}

function Add-CcodCleanupCode {
    param([Collections.Generic.List[string]]$Codes,[string]$Code)
    if(-not $Codes.Contains($Code) -and $Codes.Count -lt 16){$Codes.Add($Code)}
}

function Invoke-CcodCleanupStage {
    param([scriptblock]$Action,[Collections.Generic.List[string]]$Codes,[string]$Code,[string]$Surface='Tray')
    try{& $Action}catch{Add-CcodCleanupCode $Codes $Code}
}

function Invoke-CcodTrayCommandCallback {
    param($Context,[string]$Kind,$Sender,[AllowNull()]$ExplicitValue=$null)
    [Threading.Monitor]::Enter($Context.QueueGate)
    try{
        if($Context.State -cne 'Open'){return}
        if($null -eq $Sender){return}
        $enabled=Invoke-CcodTrayAdapter $Context.Adapters.GetUiProperty @($Sender,'Enabled') 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        if($enabled -isnot [bool] -or -not $enabled){return}
        $value=$null
        if($Kind -ceq 'SetAutomationEnabled' -or $Kind -ceq 'SetCandidateCompatibleOptIn'){
            $value=Invoke-CcodTrayAdapter $Context.Adapters.GetUiProperty @($Sender,'Checked') 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            if($value -isnot [bool]){return}
        }elseif($Kind -ceq 'SetUiLanguage'){
            if($ExplicitValue -isnot [string] -or $script:TrayUiLanguageModes -cnotcontains $ExplicitValue){return}
            $value=$ExplicitValue
        }elseif($Kind -ceq 'Uninstall'){
            $confirmed=Invoke-CcodTrayAdapter $Context.Adapters.ConfirmUninstall @($Context.CommandValues.UninstallTitle,$Context.CommandValues.UninstallMessage) 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            if($confirmed -isnot [bool] -or -not $confirmed){return}
        }
        $timestamp=Get-CcodCanonicalUtc $Context.Adapters 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $command=[pscustomobject][ordered]@{Kind=$Kind;Value=$value;EnqueuedAtUtc=$timestamp}
        $queueArgument=[object[]]::new(1);$queueArgument[0]=$Context.CommandQueue
        $count=Invoke-CcodTrayAdapter $Context.Adapters.GetQueueCount $queueArgument 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        if($count -isnot [int] -or $count -lt 0){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
        if($count -ge 256){$Context.CommandOverflowed=$true;return}
        $enqueueArguments=[object[]]::new(2);$enqueueArguments[0]=$Context.CommandQueue;$enqueueArguments[1]=$command
        $added=Invoke-CcodTrayAdapter $Context.Adapters.TryEnqueue $enqueueArguments 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        if($added -isnot [bool] -or -not $added){$Context.CommandOverflowed=$true;return}
    }catch{if($Context.State -ceq 'Open'){$Context.CallbackFailure=$true}}
    finally{[Threading.Monitor]::Exit($Context.QueueGate)}
}

function Set-CcodTrayLocalizedControlText {
    param($Context,$Strings,[string]$StateKey,[string]$FailureCode)
    $adapter=$Context.Adapters
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Rows.Title,'Text',$Strings['Tray.Title']) 0 $FailureCode 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Rows.Status,'Text',$Strings['Status.'+$StateKey]) 0 $FailureCode 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.NotifyIcon,'Text',$Strings['Tooltip.'+$StateKey]) 0 $FailureCode 'Tray'
    $keys=[ordered]@{
        SessionReady='Menu.SessionReady';ApplyNow='Menu.ApplyNow';ManualRetry='Menu.ManualRetry';SetAutomationEnabled='Menu.Automation'
        SetCandidateCompatibleOptIn='Menu.CandidateOptIn';Language='Menu.Language';OpenLogs='Menu.OpenLogs';Uninstall='Menu.Uninstall'
    }
    foreach($key in $keys.Keys){Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Items[$key],'Text',$Strings[$keys[$key]]) 0 $FailureCode 'Tray'}
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.LanguageItems.System,'Text',$Strings['Menu.FollowSystem']) 0 $FailureCode 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.LanguageItems['zh-CN'],'Text',$Strings['Menu.Chinese']) 0 $FailureCode 'Tray'
    Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.LanguageItems['en-US'],'Text',$Strings['Menu.English']) 0 $FailureCode 'Tray'
    $Context.CommandValues.UninstallTitle=$Strings['Dialog.UninstallTitle']
    $Context.CommandValues.UninstallMessage=$Strings['Dialog.UninstallMessage']
}

function Set-CcodTrayLanguageChecks {
    param($Context,[string]$LanguageMode,[string]$FailureCode)
    foreach($mode in $script:TrayUiLanguageModes){Invoke-CcodTrayAdapter $Context.Adapters.SetUiProperty @($Context.LanguageItems[$mode],'Checked',[bool]($mode -ceq $LanguageMode)) 0 $FailureCode 'Tray'}
}

function New-CcodTrayContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$CommandQueue,[Parameter(Mandatory)][AllowNull()]$OnTick,
        [Parameter(Mandatory)][AllowNull()]$Catalog,[Parameter(Mandatory)][AllowNull()]$LanguageMode,
        [Parameter(Mandatory)][AllowNull()]$SystemCultureName,[AllowNull()]$Adapters
    )
    if($null -eq $CommandQueue -or $OnTick -isnot [scriptblock]){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $adapter=Get-CcodTrayAdapters $Adapters 'CCOD_TRAY_INPUT_INVALID' 'Tray'
    try{
        $threadId=Invoke-CcodTrayAdapter $adapter.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
        $apartment=Invoke-CcodTrayAdapter $adapter.GetApartmentState @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
    }catch{Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
    if($threadId -isnot [int] -or $threadId -le 0 -or $apartment -isnot [string] -or $apartment -cne 'STA'){Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$CommandQueue
    $initialCount=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_TRAY_INPUT_INVALID' 'Tray'
    if($initialCount -isnot [int] -or $initialCount -lt 0 -or $initialCount -gt 256){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $localized=Resolve-CcodTrayLocalizedStrings $Catalog $LanguageMode $SystemCultureName
    $context=[pscustomobject][ordered]@{
        SchemaVersion=1;State='Creating';OwnerManagedThreadId=$threadId;CommandQueue=$CommandQueue
        CommandOverflowed=$false;CallbackFailure=$false;QueueGate=New-Object object;CloseGate=New-Object object;OnTick=$OnTick;Adapters=$adapter
        ApplicationContext=$null;Timer=$null;NotifyIcon=$null;Menu=$null;Rows=[ordered]@{};Items=[ordered]@{};LanguageItems=[ordered]@{};Separators=[ordered]@{}
        UnownedControls=[Collections.Generic.List[object]]::new();Icons=[ordered]@{};TitleImage=$null;TitleFont=$null
        Callbacks=[Collections.Generic.List[object]]::new();CommandValues=[ordered]@{
            AutomationChecked=$false;CandidateOptInChecked=$false
            UninstallTitle=$localized['Dialog.UninstallTitle'];UninstallMessage=$localized['Dialog.UninstallMessage']
        }
        CleanupCodes=[Collections.Generic.List[string]]::new();CloseReceipt=$null
    }
    $context.PSObject.TypeNames.Insert(0,'Ccod.TrayContext')
    try{
        $nonnull={param($value)[bool]($null -ne $value)}
        $context.ApplicationContext=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('ApplicationContext','TrayApplicationContext') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Timer=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('Timer','TrayTimer') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.NotifyIcon=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('NotifyIcon','TrayNotifyIcon') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Menu=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('Menu','TrayMenu') $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        foreach($row in @('Title','Status')){
            $control=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('Row',($row+'Row')) $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.UnownedControls.Add($control)
            $context.Rows[$row]=$control
            Invoke-CcodTrayAdapter $adapter.SetUiProperty @($control,'Enabled',$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        }
        foreach($key in @('SessionReady','ApplyNow','ManualRetry','SetAutomationEnabled','SetCandidateCompatibleOptIn','Language','OpenLogs','Uninstall')){
            $item=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('MenuItem',($key+'Item')) $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.UnownedControls.Add($item)
            $context.Items[$key]=$item
            Invoke-CcodTrayAdapter $adapter.SetUiProperty @($item,'Enabled',[bool]($key -ceq 'Language')) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            if($key -ceq 'SetAutomationEnabled' -or $key -ceq 'SetCandidateCompatibleOptIn'){
                Invoke-CcodTrayAdapter $adapter.SetUiProperty @($item,'CheckOnClick',$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                Invoke-CcodTrayAdapter $adapter.SetUiProperty @($item,'Checked',$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            }
        }
        foreach($mode in $script:TrayUiLanguageModes){
            $item=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('MenuItem',($mode+'LanguageItem')) $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.UnownedControls.Add($item);$context.LanguageItems[$mode]=$item
            Invoke-CcodTrayAdapter $adapter.SetUiProperty @($item,'Enabled',$true) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            Invoke-CcodTrayAdapter $adapter.SetUiProperty @($item,'CheckOnClick',$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            Invoke-CcodTrayAdapter $adapter.SetUiProperty @($item,'Checked',$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $transfer=Invoke-CcodTraySideEffectAdapter $adapter.AddUiChild @($context.Items.Language,$item)
            if($transfer.Completed){[void]$context.UnownedControls.Remove($item)}
            if(-not $transfer.Succeeded){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
        }
        foreach($key in @('Status','Preferences','Danger')){
            $separator=Invoke-CcodOwnedTrayAdapter $adapter.CreateUiObject @('Separator',($key+'Separator')) $adapter.DisposeUiObject $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.UnownedControls.Add($separator);$context.Separators[$key]=$separator
        }
        $topLevel=@(
            $context.Rows.Title,$context.Rows.Status,$context.Separators.Status,$context.Items.SessionReady,$context.Items.ApplyNow,$context.Items.ManualRetry,
            $context.Separators.Preferences,$context.Items.SetAutomationEnabled,$context.Items.SetCandidateCompatibleOptIn,$context.Items.Language,$context.Items.OpenLogs,
            $context.Separators.Danger,$context.Items.Uninstall
        )
        foreach($control in $topLevel){
            $transfer=Invoke-CcodTraySideEffectAdapter $adapter.AddUiChild @($context.Menu,$control)
            if($transfer.Completed){[void]$context.UnownedControls.Remove($control)}
            if(-not $transfer.Succeeded){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
        }
        foreach($color in @('Gray','Green','Yellow','Red')){
            foreach($size in @(16,32)){
                $bitmap=$null;$hicon=[IntPtr]::Zero
                try{
                    $bitmap=Invoke-CcodOwnedTrayAdapter $adapter.CreateBitmap @($color,[int]$size) $adapter.DisposeIconResource $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    Invoke-CcodTrayAdapter $adapter.DrawBridgeIcon @($bitmap,$color,[int]$size) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    $validHicon={param($value)[bool]($value -is [IntPtr] -and $value -ne [IntPtr]::Zero)}
                    $hicon=Invoke-CcodOwnedTrayAdapter $adapter.GetHicon @($bitmap) $adapter.DestroyIcon $validHicon 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    $clone=Invoke-CcodOwnedTrayAdapter $adapter.CloneIcon @($hicon,$color,[int]$size) $adapter.DisposeIconResource $nonnull 'CCOD_TRAY_CREATE_FAILED' 'Tray'
                    $context.Icons[$color+':'+$size]=$clone
                }finally{
                    $iconCleanupFailed=$false
                    if($hicon -ne [IntPtr]::Zero){try{Invoke-CcodTrayAdapter $adapter.DestroyIcon @($hicon) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'}catch{$iconCleanupFailed=$true}}
                    if($null -ne $bitmap){try{Invoke-CcodTrayAdapter $adapter.DisposeIconResource @($bitmap) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'}catch{$iconCleanupFailed=$true}}
                    # Temporary GDI cleanup must not abort tray creation after a successful clone.
                    if($iconCleanupFailed -and -not $context.Icons.Contains($color+':'+$size)){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
                }
            }
        }
        $validTitleBitmap={param($value)[bool]($null -ne $value -and -not [object]::ReferenceEquals($value,$context.Icons['Gray:16']))}.GetNewClosure()
        $context.TitleImage=Invoke-CcodOwnedTrayAdapter $adapter.CloneIconBitmap @($context.Icons['Gray:16']) $adapter.DisposeIconResource $validTitleBitmap 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $baseFont=Invoke-CcodTrayAdapter $adapter.GetUiProperty @($context.Rows.Title,'Font') 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        if($null -eq $baseFont){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
        $validBoldFont={param($value)[bool]($null -ne $value -and -not [object]::ReferenceEquals($value,$baseFont) -and $value.PSObject.Properties['Bold'] -and $value.Bold -is [bool] -and $value.Bold)}.GetNewClosure()
        $context.TitleFont=Invoke-CcodOwnedTrayAdapter $adapter.CreateBoldFont @($baseFont) $adapter.DisposeIconResource $validBoldFont 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.Rows.Title,'Image',$context.TitleImage) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.Rows.Title,'Font',$context.TitleFont) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Set-CcodTrayLocalizedControlText $context $localized 'Waiting' 'CCOD_TRAY_CREATE_FAILED'
        Set-CcodTrayLanguageChecks $context $LanguageMode 'CCOD_TRAY_CREATE_FAILED'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($context.Items.SessionReady,$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($context.Items.ApplyNow,$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($context.Items.ManualRetry,$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $invokeCommandCallback=${function:Invoke-CcodTrayCommandCallback}
        $validClickAttachment={param($value)[bool]((Test-CcodExactProperties $value @('Target','EventName','Handler')) -and $null -ne $value.Target -and $value.EventName -ceq 'Click' -and $null -ne $value.Handler)}
        foreach($kind in @('ApplyNow','ManualRetry','SetAutomationEnabled','SetCandidateCompatibleOptIn','OpenLogs','Uninstall')){
            $contextRef=$context;$kindRef=$kind;$invokeCommandCallbackRef=$invokeCommandCallback
            $callback={
                param($sender,$eventArgs)
                & $invokeCommandCallbackRef $contextRef $kindRef $sender
            }.GetNewClosure()
            $attachment=Invoke-CcodOwnedTrayAdapter $adapter.AttachUiCallback @($context.Items[$kind],'Click',$callback) $adapter.DetachUiCallback $validClickAttachment 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.Callbacks.Add($attachment)
        }
        foreach($mode in $script:TrayUiLanguageModes){
            $contextRef=$context;$modeRef=$mode;$invokeCommandCallbackRef=$invokeCommandCallback
            $callback={param($sender,$eventArgs)& $invokeCommandCallbackRef $contextRef 'SetUiLanguage' $sender $modeRef}.GetNewClosure()
            $attachment=Invoke-CcodOwnedTrayAdapter $adapter.AttachUiCallback @($context.LanguageItems[$mode],'Click',$callback) $adapter.DetachUiCallback $validClickAttachment 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            $context.Callbacks.Add($attachment)
        }
        $contextRef=$context;$invokeAdapterRef=${function:Invoke-CcodTrayAdapter}
        $tick={
            param($sender,$eventArgs)
            [Threading.Monitor]::Enter($contextRef.QueueGate)
            try{
                if($contextRef.State -cne 'Open'){return}
                $current=& $invokeAdapterRef $contextRef.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
                if($current -isnot [int] -or $current -ne $contextRef.OwnerManagedThreadId){return}
                & $invokeAdapterRef $contextRef.OnTick @() 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            }catch{if($contextRef.State -ceq 'Open'){$contextRef.CallbackFailure=$true}}
            finally{[Threading.Monitor]::Exit($contextRef.QueueGate)}
        }.GetNewClosure()
        $validTickAttachment={param($value)[bool]((Test-CcodExactProperties $value @('Target','EventName','Handler')) -and $null -ne $value.Target -and $value.EventName -ceq 'Tick' -and $null -ne $value.Handler)}
        $attachment=Invoke-CcodOwnedTrayAdapter $adapter.AttachUiCallback @($context.Timer,'Tick',$tick) $adapter.DetachUiCallback $validTickAttachment 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        $context.Callbacks.Add($attachment)
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.Timer,'Interval',[int]250) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.NotifyIcon,'ContextMenuStrip',$context.Menu) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($context.NotifyIcon,'Icon',$context.Icons['Gray:16']) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.StartUiTimer @($context.Timer) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($context.NotifyIcon,$true) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'
        [Threading.Monitor]::Enter($context.QueueGate)
        try{$context.State='Open'}finally{[Threading.Monitor]::Exit($context.QueueGate)}
        return $context
    }catch{
        $createError = $_
        try{Close-CcodTrayContext -Context $context|Out-Null}catch{}
        if ($createError.FullyQualifiedErrorId -and ($createError.FullyQualifiedErrorId -split ',')[0] -cmatch '^CCOD_') {
            throw $createError
        }
        Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'
    }
}

function Close-CcodTrayContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Context)
    if(-not (Test-CcodContextGateHandle $Context)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $closeGate=$Context.CloseGate
    try{[Threading.Monitor]::Enter($closeGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
    if(-not (Test-CcodContextObject $Context)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    if($Context.State -ceq 'Closed'){return $Context.CloseReceipt}
    if($Context.State -ceq 'Closing'){return $Context.CloseReceipt}
    $queueGate=$Context.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
        $Context.State='Closing'
        $Context.CloseReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=@()}
    }finally{[Threading.Monitor]::Exit($queueGate)}
    $codes=[Collections.Generic.List[string]]::new();$Context.CleanupCodes=$codes;$adapter=$Context.Adapters
    if($null -ne $Context.NotifyIcon){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.SetUiVisible @($Context.NotifyIcon,$false) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED'}
    if($null -ne $Context.Timer){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.StopUiTimer @($Context.Timer) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED'
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.Timer) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED'
    }
    if($null -ne $Context.NotifyIcon){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.NotifyIcon) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED'
    }
    if($null -ne $Context.Menu){
        $menuDisposal=Invoke-CcodTraySideEffectAdapter $adapter.DisposeUiObject @($Context.Menu)
        if(-not $menuDisposal.Succeeded){Add-CcodCleanupCode $codes 'CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED'}
    }
    $controls=[Collections.Generic.List[object]]::new()
    foreach($candidate in @($Context.Rows.Values)+@($Context.Items.Values)+@($Context.LanguageItems.Values)+@($Context.Separators.Values)+@($Context.UnownedControls)){
        if($null -eq $candidate){continue}
        $duplicate=$false
        foreach($existing in $controls){if([object]::ReferenceEquals($existing,$candidate)){$duplicate=$true;break}}
        if(-not $duplicate){$controls.Add($candidate)}
    }
    foreach($control in $controls){
        $isDisposed=$null
        try{
            $isDisposed=Invoke-CcodTrayAdapter $adapter.GetUiProperty @($control,'IsDisposed') 1 'CCOD_TRAY_CREATE_FAILED' 'Tray'
            if($isDisposed -isnot [bool]){Throw-CcodTrayError 'CCOD_TRAY_CREATE_FAILED' 'Tray'}
        }catch{Add-CcodCleanupCode $codes 'CCOD_TRAY_CLEANUP_CONTROL_DISPOSE_FAILED';continue}
        if(-not $isDisposed){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($control) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CONTROL_DISPOSE_FAILED'}
    }
    if($null -ne $Context.TitleImage){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeIconResource @($Context.TitleImage) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED'}
    if($null -ne $Context.TitleFont){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeIconResource @($Context.TitleFont) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CONTROL_DISPOSE_FAILED'}
    foreach($icon in @($Context.Icons.Values)){
        if($null -ne $icon){Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeIconResource @($icon) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED'}
    }
    foreach($attachment in @($Context.Callbacks)){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DetachUiCallback @($attachment) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED'
    }
    if($null -ne $Context.ApplicationContext){
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.ExitUiContext @($Context.ApplicationContext) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED'
        Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeUiObject @($Context.ApplicationContext) 0 'CCOD_TRAY_CREATE_FAILED' 'Tray'} $codes 'CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED'
    }
    $Context.OnTick=$null;$Context.Callbacks.Clear();$Context.State='Closed'
    $safeCodes=@($codes|Where-Object {$script:TrayCleanupCodeAllowlist -ccontains $_}|Select-Object -Unique)
    $Context.CloseReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=$safeCodes}
    return $Context.CloseReceipt
    }finally{[Threading.Monitor]::Exit($closeGate)}
}

function Test-CcodControlCharacter {
    param([string]$Value)
    foreach($character in $Value.ToCharArray()){if([char]::IsControl($character)){return $true}}
    return $false
}

function Assert-CcodTrayPresentation {
    param($Presentation)
    $names=@('Color','StateKey','SessionReadyVisible','ApplyNowVisible','ApplyNowEnabled','ManualRetryVisible','ManualRetryEnabled','AutomationToggleEnabled','AutomationChecked','CandidateOptInToggleEnabled','CandidateOptInChecked','OpenLogsEnabled','UninstallEnabled','Busy')
    if(-not (Test-CcodExactProperties $Presentation $names)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    if($Presentation.Color -isnot [string] -or @('Gray','Green','Yellow','Red') -cnotcontains $Presentation.Color){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    if($Presentation.StateKey -isnot [string] -or @('Waiting','Inspecting','Transitioning','Active','ActivePaused','Suppressed','Recovered','Error') -cnotcontains $Presentation.StateKey){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    foreach($name in $names[2..13]){if($Presentation.$name -isnot [bool]){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}}
}

function Set-CcodTrayPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Context,[Parameter(Mandatory)][AllowNull()]$Presentation,
        [Parameter(Mandatory)][AllowNull()]$Catalog,[Parameter(Mandatory)][AllowNull()]$LanguageMode,
        [Parameter(Mandatory)][AllowNull()]$SystemCultureName
    )
    if(-not (Test-CcodContextObject $Context)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $queueGate=$Context.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
    if($Context.State -cne 'Open'){Throw-CcodTrayError 'CCOD_TRAY_CONTEXT_CLOSED' 'Tray'}
    Assert-CcodTrayPresentation $Presentation
    $localized=Resolve-CcodTrayLocalizedStrings $Catalog $LanguageMode $SystemCultureName
    $current=Invoke-CcodTrayAdapter $Context.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
    if($current -isnot [int] -or $current -ne $Context.OwnerManagedThreadId){Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
    $adapter=$Context.Adapters
    try{
        Set-CcodTrayLocalizedControlText $Context $localized $Presentation.StateKey 'CCOD_TRAY_PRESENTATION_FAILED'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.NotifyIcon,'Icon',$Context.Icons[$Presentation.Color+':16']) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($Context.Items.SessionReady,[bool]$Presentation.SessionReadyVisible) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($Context.Items.ApplyNow,[bool]$Presentation.ApplyNowVisible) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiVisible @($Context.Items.ManualRetry,[bool]$Presentation.ManualRetryVisible) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        $enabled=[ordered]@{ApplyNow=$Presentation.ApplyNowEnabled;ManualRetry=$Presentation.ManualRetryEnabled;SetAutomationEnabled=$Presentation.AutomationToggleEnabled;SetCandidateCompatibleOptIn=$Presentation.CandidateOptInToggleEnabled;OpenLogs=$Presentation.OpenLogsEnabled;Uninstall=$Presentation.UninstallEnabled}
        foreach($kind in $enabled.Keys){Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Items[$kind],'Enabled',[bool]$enabled[$kind]) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'}
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Items.SessionReady,'Enabled',$false) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Items.Language,'Enabled',$true) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Items.SetAutomationEnabled,'Checked',[bool]$Presentation.AutomationChecked) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Invoke-CcodTrayAdapter $adapter.SetUiProperty @($Context.Items.SetCandidateCompatibleOptIn,'Checked',[bool]$Presentation.CandidateOptInChecked) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
        Set-CcodTrayLanguageChecks $Context $LanguageMode 'CCOD_TRAY_PRESENTATION_FAILED'
        $Context.CommandValues.AutomationChecked=[bool]$Presentation.AutomationChecked
        $Context.CommandValues.CandidateOptInChecked=[bool]$Presentation.CandidateOptInChecked
    }catch{Throw-CcodTrayError 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'}
    }finally{[Threading.Monitor]::Exit($queueGate)}
}

function Show-CcodTrayError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Context,[Parameter(Mandatory)][AllowNull()]$Catalog,
        [Parameter(Mandatory)][AllowNull()]$Key
    )
    if(-not (Test-CcodContextObject $Context) -or $Key -isnot [string] -or @('Error.LanguageChange','Error.UninstallStart') -cnotcontains $Key -or
       -not (Test-CcodTrayCatalog $Catalog)){Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    $queueGate=$Context.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
    try{
        if($Context.State -cne 'Open'){Throw-CcodTrayError 'CCOD_TRAY_CONTEXT_CLOSED' 'Tray'}
        $current=Invoke-CcodTrayAdapter $Context.Adapters.GetManagedThreadId @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
        $apartment=Invoke-CcodTrayAdapter $Context.Adapters.GetApartmentState @() 1 'CCOD_TRAY_THREAD_INVALID' 'Tray'
        if($current -isnot [int] -or $current -ne $Context.OwnerManagedThreadId -or $apartment -isnot [string] -or $apartment -cne 'STA'){Throw-CcodTrayError 'CCOD_TRAY_THREAD_INVALID' 'Tray'}
        try{$title=Get-CcodUiString -Catalog $Catalog -Key 'Tray.Title';$message=Get-CcodUiString -Catalog $Catalog -Key $Key}catch{Throw-CcodTrayError 'CCOD_TRAY_INPUT_INVALID' 'Tray'}
        Invoke-CcodTrayAdapter $Context.Adapters.ShowErrorDialog @($title,$message) 0 'CCOD_TRAY_PRESENTATION_FAILED' 'Tray'
    }finally{[Threading.Monitor]::Exit($queueGate)}
}

function Start-CcodProcessWatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Queue,[Parameter(Mandatory)][AllowNull()]$OnFullReconciliationRequired,[AllowNull()]$Adapters)
    if($null -eq $Queue -or $OnFullReconciliationRequired -isnot [scriptblock]){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    $adapter=Get-CcodTrayAdapters $Adapters 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
    $watcher=[pscustomobject][ordered]@{
        SchemaVersion=1;State='Starting';Mode='ReconciliationOnly';Queue=$Queue;OnFullReconciliationRequired=$OnFullReconciliationRequired
        QueueGate=New-Object object;StopGate=New-Object object;FullReconciliationNeeded=$false;OverflowEpisodeSignaled=$false;CallbackFailure=$false
        Registration=$null;Callback=$null;Adapters=$adapter;PendingAttemptSources=[Collections.Generic.List[string]]::new();CapabilityCleanupFailed=$false
        CleanupCodes=[Collections.Generic.List[string]]::new();StopReceipt=$null
    }
    $watcher.PSObject.TypeNames.Insert(0,'Ccod.ProcessWatcher')
    $queueArgument=[object[]]::new(1);$queueArgument[0]=$Queue
    $initialCount=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
    if($initialCount -isnot [int] -or $initialCount -lt 0 -or $initialCount -gt 256){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    $watcherRef=$watcher;$getCanonicalUtcRef=${function:Get-CcodCanonicalUtc};$invokeAdapterRef=${function:Invoke-CcodTrayAdapter};$throwTrayErrorRef=${function:Throw-CcodTrayError}
    $traceClass='Win32_ProcessStartTrace'
    $intrinsicQuery=[string]::Join("`r`n",@(
        'SELECT * FROM __InstanceCreationEvent WITHIN 1',
        "WHERE TargetInstance ISA 'Win32_Process'",
        "AND TargetInstance.Name = 'ChatGPT.exe'"
    ))
    $callback={
        param($ProcessId,$ProcessName)
        [Threading.Monitor]::Enter($watcherRef.QueueGate)
        try{
            if($watcherRef.State -cne 'Running'){return}
            if($ProcessName -isnot [string] -or $ProcessName -cne 'ChatGPT.exe'){return}
            if($ProcessId -is [uint32]){if([uint64]$ProcessId -gt [int]::MaxValue){return};$canonicalPid=[int]$ProcessId}
            elseif($ProcessId -is [int]){$canonicalPid=$ProcessId}else{return}
            if($canonicalPid -le 0){return}
            $event=[pscustomobject][ordered]@{ProcessId=$canonicalPid;EventKind='Started';ObservedAtUtc=(& $getCanonicalUtcRef $watcherRef.Adapters 'CCOD_WATCHER_INPUT_INVALID' 'Watcher')}
            $signal=$false
            $queueArgument=[object[]]::new(1);$queueArgument[0]=$watcherRef.Queue
            $count=& $invokeAdapterRef $watcherRef.Adapters.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
            if($count -isnot [int] -or $count -lt 0){& $throwTrayErrorRef 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            if($count -ge 256){
                $watcherRef.FullReconciliationNeeded=$true
                if(-not $watcherRef.OverflowEpisodeSignaled){$watcherRef.OverflowEpisodeSignaled=$true;$signal=$true}
            }else{
                $enqueueArguments=[object[]]::new(2);$enqueueArguments[0]=$watcherRef.Queue;$enqueueArguments[1]=$event
                $added=& $invokeAdapterRef $watcherRef.Adapters.TryEnqueue $enqueueArguments 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
                if($added -isnot [bool] -or -not $added){
                    $watcherRef.FullReconciliationNeeded=$true
                    if(-not $watcherRef.OverflowEpisodeSignaled){$watcherRef.OverflowEpisodeSignaled=$true;$signal=$true}
                }else{
                    $watcherRef.OverflowEpisodeSignaled=$false
                }
            }
            if($signal){& $invokeAdapterRef $watcherRef.OnFullReconciliationRequired @() 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
        }catch{if($watcherRef.State -ceq 'Running'){$watcherRef.CallbackFailure=$true}}
        finally{[Threading.Monitor]::Exit($watcherRef.QueueGate)}
    }.GetNewClosure()
    $watcher.Callback=$callback
    $generatedSources=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($mode in @('Trace','Intrinsic')){
        $source=$null;$receipt=$null;$registrationAttempted=$false
        try{
            $source=Invoke-CcodTrayAdapter $adapter.NewSourceIdentifier @() 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
            if($source -isnot [string] -or $source -cnotmatch '^ccod-process-[0-9a-f]{32}$'){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            if(-not $generatedSources.Add($source)){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            $register=if($mode -ceq 'Trace'){$adapter.RegisterTrace}else{$adapter.RegisterIntrinsic}
            $registerArguments=if($mode -ceq 'Trace'){@($source,$traceClass,$callback)}else{@($source,$intrinsicQuery,$callback)}
            $registrationAttempted=$true
            $receipt=Invoke-CcodTrayAdapter $register $registerArguments 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'
            if(-not (Test-CcodExactProperties $receipt @('SourceIdentifier','JobId','Resource')) -or $receipt.SourceIdentifier -isnot [string] -or
               $receipt.SourceIdentifier -cne $source -or $receipt.JobId -isnot [int] -or $receipt.JobId -le 0 -or $null -eq $receipt.Resource){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
            $watcher.Registration=$receipt;$watcher.Mode=$mode;break
        }catch{
            if($registrationAttempted){
                try{Invoke-CcodTrayAdapter $adapter.CleanupWatcherAttempt @($source) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{
                    $watcher.PendingAttemptSources.Add($source);$watcher.CapabilityCleanupFailed=$true;break
                }
            }
        }
    }
    [Threading.Monitor]::Enter($watcher.QueueGate)
    try{$watcher.State='Running'}finally{[Threading.Monitor]::Exit($watcher.QueueGate)}
    return $watcher
}

function Stop-CcodProcessWatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Watcher)
    if(-not (Test-CcodWatcherGateHandle $Watcher)){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    $stopGate=$Watcher.StopGate
    try{[Threading.Monitor]::Enter($stopGate)}catch{Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    try{
    if(-not (Test-CcodWatcherObject $Watcher)){Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    if($Watcher.State -ceq 'Stopped'){return $Watcher.StopReceipt}
    if($Watcher.State -ceq 'Stopping'){return $Watcher.StopReceipt}
    $queueGate=$Watcher.QueueGate
    try{[Threading.Monitor]::Enter($queueGate)}catch{Throw-CcodTrayError 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}
    try{
        $Watcher.State='Stopping'
        $Watcher.StopReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=@()}
    }finally{[Threading.Monitor]::Exit($queueGate)}
    $codes=[Collections.Generic.List[string]]::new();$Watcher.CleanupCodes=$codes;$adapter=$Watcher.Adapters;$receipt=$Watcher.Registration
    try{
        foreach($source in @($Watcher.PendingAttemptSources|Select-Object -First 2)){
            if($source -is [string] -and $source -cmatch '^ccod-process-[0-9a-f]{32}$'){
                Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.CleanupWatcherAttempt @($source) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_ATTEMPT_FAILED' 'Watcher'
            }
        }
        if($null -ne $receipt){
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DetachWatcherCallback @($receipt) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_CALLBACK_DETACH_FAILED' 'Watcher'
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.UnregisterWatcher @($receipt.SourceIdentifier) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_UNREGISTER_FAILED' 'Watcher'
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.RemoveWatcherJob @($receipt.JobId) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_JOB_REMOVE_FAILED' 'Watcher'
            Invoke-CcodCleanupStage {Invoke-CcodTrayAdapter $adapter.DisposeWatcherResource @($receipt.Resource) 0 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'} $codes 'CCOD_WATCHER_CLEANUP_RESOURCE_DISPOSE_FAILED' 'Watcher'
        }
    }finally{
        $queueArgument=[object[]]::new(1);$queueArgument[0]=$Watcher.Queue
        $drainCount=$null
        try{$drainCount=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}
        if($drainCount -isnot [int] -or $drainCount -lt 0){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}else{
            $drainLimit=[Math]::Min($drainCount,256)
            $earlyEmpty=$false
            for($drained=0;$drained -lt $drainLimit;$drained++){
                $dequeued=$null
                try{$dequeued=Invoke-CcodTrayAdapter $adapter.TryDequeue $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED';break}
                if(-not (Test-CcodExactProperties $dequeued @('Succeeded','Value')) -or $dequeued.Succeeded -isnot [bool]){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED';break}
                if(-not $dequeued.Succeeded){$earlyEmpty=$true;break}
            }
            if($earlyEmpty){
                $remaining=$null
                try{$remaining=Invoke-CcodTrayAdapter $adapter.GetQueueCount $queueArgument 1 'CCOD_WATCHER_INPUT_INVALID' 'Watcher'}catch{Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}
                if($remaining -isnot [int] -or $remaining -ne 0){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED'}
            }
            if($drainCount -gt 256){Add-CcodCleanupCode $codes 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_LIMIT'}
        }
        $Watcher.Callback=$null;$Watcher.OnFullReconciliationRequired=$null;$Watcher.State='Stopped'
    }
    $safeCodes=@($codes|Where-Object {$script:WatcherCleanupCodeAllowlist -ccontains $_}|Select-Object -Unique)
    $Watcher.StopReceipt=[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=$safeCodes}
    return $Watcher.StopReceipt
    }finally{[Threading.Monitor]::Exit($stopGate)}
}

Export-ModuleMember -Function @(
    'New-CcodTrayContext','Set-CcodTrayPresentation','Show-CcodTrayError','Close-CcodTrayContext','Start-CcodProcessWatcher','Stop-CcodProcessWatcher'
)
