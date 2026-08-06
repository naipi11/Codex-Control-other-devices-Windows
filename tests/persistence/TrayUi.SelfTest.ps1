$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\TrayUi.psm1'
if(-not [IO.File]::Exists($modulePath)){
    throw 'MISSING_TRAY_UI_MODULE: src\persistence\modules\TrayUi.psm1'
}
Import-Module $modulePath -Force

function New-CcodTrayTestQueue {
    Write-Output -NoEnumerate ([Collections.Generic.Queue[object]]::new())
}

function New-CcodTrayFakeAdapters {
    $state=[pscustomobject]@{
        Calls=[Collections.Generic.List[string]]::new()
        Objects=[Collections.Generic.List[object]]::new()
        Bitmaps=[Collections.Generic.List[object]]::new()
        IconClones=[Collections.Generic.List[object]]::new()
        HiconSeed=1000
        ThreadId=37
        Apartment='STA'
        Now=[DateTimeOffset]::new(2030,2,3,4,5,6,[TimeSpan]::Zero)
        SourceSeed=0
        TraceCalls=0
        IntrinsicCalls=0
        TraceHandler=$null
        IntrinsicHandler=$null
        TraceClass=$null
        IntrinsicQuery=$null
        TraceReceipt=$null
        IntrinsicReceipt=$null
        ActiveSources=@{}
    }
    $adapters=@{
        GetUtcNow={ $state.Calls.Add('Clock:GetUtcNow'); $state.Now }.GetNewClosure()
        GetQueueCount={ param($Queue) [int]$Queue.Count }
        TryEnqueue={ param($Queue,$Value) $Queue.Enqueue($Value); $true }
        TryDequeue={ param($Queue) if($Queue.Count -eq 0){[pscustomobject]@{Succeeded=$false;Value=$null}}else{[pscustomobject]@{Succeeded=$true;Value=$Queue.Dequeue()}} }
        GetManagedThreadId={ [int]$state.ThreadId }.GetNewClosure()
        GetApartmentState={ [string]$state.Apartment }.GetNewClosure()
        CreateUiObject={
            param($Kind,$Name)
            $state.Calls.Add("Create:$Kind`:$Name")
            $object=[pscustomobject]@{
                Kind=$Kind;Name=$Name;Properties=[ordered]@{IsDisposed=$false};Events=[ordered]@{}
                Children=[Collections.Generic.List[object]]::new();Disposed=$false;DisposeCount=0
            }
            $state.Objects.Add($object)
            $object
        }.GetNewClosure()
        AddUiChild={param($Parent,$Child)$state.Calls.Add("Add:$($Parent.Name):$($Child.Name)");$Parent.Children.Add($Child)}.GetNewClosure()
        SetUiProperty={param($Object,$Name,$Value)$state.Calls.Add("Set:$($Object.Name):$Name");$Object.Properties[$Name]=$Value}.GetNewClosure()
        GetUiProperty={param($Object,$Name)$Object.Properties[$Name]}
        SetUiVisible={param($Object,$Visible)$state.Calls.Add("Visible:$($Object.Name):$Visible");$Object.Properties['Visible']=[bool]$Visible}.GetNewClosure()
        StartUiTimer={param($Timer)$state.Calls.Add("TimerStart:$($Timer.Name)");$Timer.Properties['Started']=$true}.GetNewClosure()
        StopUiTimer={param($Timer)$state.Calls.Add("TimerStop:$($Timer.Name)");$Timer.Properties['Started']=$false}.GetNewClosure()
        AttachUiCallback={
            param($Object,$EventName,$Callback)
            $state.Calls.Add("Attach:$($Object.Name):$EventName")
            $Object.Events[$EventName]=$Callback
            [pscustomobject][ordered]@{Target=$Object;EventName=$EventName;Handler=$Callback}
        }.GetNewClosure()
        DetachUiCallback={param($Attachment)$state.Calls.Add("Detach:$($Attachment.Target.Name):$($Attachment.EventName)");$Attachment.Target.Events.Remove($Attachment.EventName)}.GetNewClosure()
        DisposeUiObject={
            param($Object)
            $state.Calls.Add("DisposeUi:$($Object.Name)");$Object.Disposed=$true;$Object.Properties['IsDisposed']=$true;$Object.DisposeCount++
            if($Object.Kind -ceq 'Menu'){foreach($child in $Object.Children){$child.Disposed=$true;$child.Properties['IsDisposed']=$true;$child.DisposeCount++}}
        }.GetNewClosure()
        ExitUiContext={param($Context)$state.Calls.Add("ExitUi:$($Context.Name)")}.GetNewClosure()
        CreateBitmap={
            param($Color,$Size)
            $state.Calls.Add("Bitmap:$Color`:$Size")
            $bitmap=[pscustomobject]@{Color=$Color;Size=[int]$Size;Disposed=$false;DisposeCount=0}
            $state.Bitmaps.Add($bitmap);$bitmap
        }.GetNewClosure()
        DrawBridgeIcon={param($Bitmap,$Color,$Size)$state.Calls.Add("Draw:$Color`:$Size")}.GetNewClosure()
        GetHicon={param($Bitmap)$state.HiconSeed++;$state.Calls.Add("GetHicon:$($Bitmap.Color):$($Bitmap.Size)");[IntPtr]$state.HiconSeed}.GetNewClosure()
        CloneIcon={
            param($Hicon,$Color,$Size)
            $state.Calls.Add("Clone:$Color`:$Size");$icon=[pscustomobject]@{Color=$Color;Size=[int]$Size;Disposed=$false;DisposeCount=0}
            $state.IconClones.Add($icon);$icon
        }.GetNewClosure()
        DestroyIcon={param($Hicon)$state.Calls.Add("DestroyIcon:$([long]$Hicon)")}.GetNewClosure()
        DisposeIconResource={param($Resource)$state.Calls.Add("DisposeIcon:$($Resource.Color):$($Resource.Size)");$Resource.Disposed=$true;$Resource.DisposeCount++}.GetNewClosure()
        NewSourceIdentifier={$state.SourceSeed++;'ccod-process-'+('{0:x32}' -f $state.SourceSeed)}.GetNewClosure()
        RegisterTrace={
            param($SourceIdentifier,$ClassName,$Callback)
            $state.TraceCalls++;$state.TraceClass=$ClassName;$state.TraceHandler=$Callback
            $resource=[pscustomobject]@{Kind='TraceResource';Disposed=$false}
            $state.TraceReceipt=[pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=[int](100+$state.TraceCalls);Resource=$resource}
            $state.ActiveSources[$SourceIdentifier]=$resource
            $state.TraceReceipt
        }.GetNewClosure()
        RegisterIntrinsic={
            param($SourceIdentifier,$Query,$Callback)
            $state.IntrinsicCalls++;$state.IntrinsicQuery=$Query;$state.IntrinsicHandler=$Callback
            $resource=[pscustomobject]@{Kind='IntrinsicResource';Disposed=$false}
            $state.IntrinsicReceipt=[pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=[int](200+$state.IntrinsicCalls);Resource=$resource}
            $state.ActiveSources[$SourceIdentifier]=$resource
            $state.IntrinsicReceipt
        }.GetNewClosure()
        CleanupWatcherAttempt={param($SourceIdentifier)$state.Calls.Add("WatcherAttemptCleanup:$SourceIdentifier");[void]$state.ActiveSources.Remove($SourceIdentifier)}.GetNewClosure()
        DetachWatcherCallback={param($Receipt)$state.Calls.Add("WatcherDetach:$($Receipt.SourceIdentifier)")}.GetNewClosure()
        UnregisterWatcher={param($SourceIdentifier)$state.Calls.Add("WatcherUnregister:$SourceIdentifier");[void]$state.ActiveSources.Remove($SourceIdentifier)}.GetNewClosure()
        RemoveWatcherJob={param($JobId)$state.Calls.Add("WatcherRemoveJob:$JobId")}.GetNewClosure()
        DisposeWatcherResource={param($Resource)$state.Calls.Add("WatcherDispose:$($Resource.Kind)");$Resource.Disposed=$true}.GetNewClosure()
    }
    [pscustomobject]@{State=$state;Adapters=$adapters}
}

function New-CcodValidPresentation {
    [pscustomobject][ordered]@{
        Color='Green';Tooltip='Current Codex session is fixed';StatusText='Current Codex session is fixed'
        ApplyNowEnabled=$false;ManualRetryEnabled=$false;AutomationToggleEnabled=$true;AutomationChecked=$true
        CandidateOptInToggleEnabled=$true;CandidateOptInChecked=$false;OpenLogsEnabled=$true;UninstallEnabled=$true;Busy=$false
    }
}

function Test-CcodOpaquePixels {
    param([Drawing.Bitmap]$Bitmap,[ValidateSet('base')][string]$Region)
    $samples=if($Bitmap.Width -eq 16){
        [pscustomobject]@{Outside=@(@(1,1),@(14,1),@(1,14));Inside=@(@(2,2),@(13,2),@(2,13))}
    }elseif($Bitmap.Width -eq 32){
        [pscustomobject]@{Outside=@(@(2,2),@(29,2),@(2,29));Inside=@(@(4,4),@(27,4),@(4,27))}
    }else{return $false}
    foreach($point in $samples.Outside){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        if($pixel.A -ge 128 -or ($pixel.R -eq 32 -and $pixel.G -eq 37 -and $pixel.B -eq 45)){return $false}
    }
    foreach($point in $samples.Inside){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        if($pixel.A -ne 255 -or $pixel.R -ne 32 -or $pixel.G -ne 37 -or $pixel.B -ne 45){return $false}
    }
    return $true
}

function Test-CcodLightPixels {
    param([Drawing.Bitmap]$Bitmap,[ValidateSet('links')][string]$Region)
    $regions=if($Bitmap.Width -eq 16){
        @(@(3,5,6,11),@(11,13,4,9))
    }elseif($Bitmap.Width -eq 32){
        @(@(6,10,12,22),@(22,26,8,18))
    }else{return $false}
    foreach($bounds in $regions){
        $found=$false
        for($y=$bounds[2];$y -le $bounds[3] -and -not $found;$y++){
            for($x=$bounds[0];$x -le $bounds[1];$x++){
                $pixel=$Bitmap.GetPixel($x,$y)
                if($pixel.A -ge 220 -and $pixel.R -ge 230 -and $pixel.G -ge 230 -and $pixel.B -ge 230){$found=$true;break}
            }
        }
        if(-not $found){return $false}
    }
    return $true
}

function Test-CcodStatusPixels {
    param([Drawing.Bitmap]$Bitmap,[ValidateSet('dot')][string]$Region,[ValidateSet('Gray','Green','Yellow','Red')][string]$Color)
    $expected=@{
        Gray=@(138,144,153);Green=@(41,179,111);Yellow=@(227,160,8);Red=@(217,74,74)
    }[$Color]
    $samples=if($Bitmap.Width -eq 16){
        [pscustomobject]@{
            Bounds=@(10,15,10,15);Center=@(12,12)
            Outline=@(@(12,11),@(11,12),@(14,12),@(12,14))
            Outside=@(@(14,10),@(10,14),@(15,12),@(12,15))
        }
    }elseif($Bitmap.Width -eq 32){
        [pscustomobject]@{
            Bounds=@(21,30,21,30);Center=@(25,25)
            Outline=@(@(25,22),@(22,25),@(28,25),@(25,28))
            Outside=@(@(25,20),@(20,25),@(30,25),@(25,30))
        }
    }else{return $false}
    $fillCount=0
    for($y=$samples.Bounds[2];$y -le $samples.Bounds[3];$y++){
        for($x=$samples.Bounds[0];$x -le $samples.Bounds[1];$x++){
            $pixel=$Bitmap.GetPixel($x,$y)
            if($pixel.A -eq 255 -and $pixel.R -eq $expected[0] -and $pixel.G -eq $expected[1] -and $pixel.B -eq $expected[2]){$fillCount++}
        }
    }
    $expectedFillCount=if($Bitmap.Width -eq 16){1}else{21}
    if($fillCount -ne $expectedFillCount){return $false}
    $center=$Bitmap.GetPixel([int]$samples.Center[0],[int]$samples.Center[1])
    if($center.A -ne 255 -or $center.R -ne $expected[0] -or $center.G -ne $expected[1] -or $center.B -ne $expected[2]){return $false}
    foreach($point in $samples.Outline){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        $whiteDelta=($pixel.R-$expected[0])+($pixel.G-$expected[1])+($pixel.B-$expected[2])
        if($pixel.A -ne 255 -or $pixel.R -le $expected[0] -or $pixel.G -le $expected[1] -or $pixel.B -le $expected[2] -or $whiteDelta -lt 150){return $false}
    }
    foreach($point in $samples.Outside){
        $pixel=$Bitmap.GetPixel([int]$point[0],[int]$point[1])
        $whiteDelta=($pixel.R-$expected[0])+($pixel.G-$expected[1])+($pixel.B-$expected[2])
        if($pixel.R -gt $expected[0] -and $pixel.G -gt $expected[1] -and $pixel.B -gt $expected[2] -and $whiteDelta -ge 150){return $false}
        if($pixel.A -ne 0 -and ($pixel.R -gt 128 -or $pixel.G -gt 128 -or $pixel.B -gt 128)){return $false}
    }
    return $true
}

function Test-CcodTransparentCorners {
    param([Drawing.Bitmap]$Bitmap)
    foreach($point in @(@(0,0),@(($Bitmap.Width-1),0),@(0,($Bitmap.Height-1)),@(($Bitmap.Width-1),($Bitmap.Height-1)))){
        if($Bitmap.GetPixel([int]$point[0],[int]$point[1]).A -ne 0){return $false}
    }
    return $true
}

$results=[Collections.Generic.List[object]]::new()

$results.Add((Invoke-CcodTest 'exports exactly the five frozen TrayUi functions' {
    $expected='Close-CcodTrayContext,New-CcodTrayContext,Set-CcodTrayPresentation,Start-CcodProcessWatcher,Stop-CcodProcessWatcher'
    $actual=((Get-Command -Module TrayUi -CommandType Function).Name|Sort-Object)-join ','
    Assert-CcodEqual $expected $actual 'public export surface remains exact'
}))

$results.Add((Invoke-CcodTest 'exposes and draws the production bridge icon contract at both cached sizes' {
    $production=& (Get-Module TrayUi) {Get-CcodTrayDefaultAdapters}
    Assert-CcodTrue ($production.ContainsKey('DrawBridgeIcon')) 'production adapter exposes DrawBridgeIcon'
    Assert-CcodTrue (-not $production.ContainsKey('DrawIconCircle')) 'retired DrawIconCircle adapter is absent'
    foreach($color in @('Gray','Green','Yellow','Red')){
        foreach($size in @(16,32)){
            $bitmap=& $production.CreateBitmap $color $size
            try{
                & $production.DrawBridgeIcon $bitmap $color $size
                Assert-CcodEqual $size $bitmap.Width "$color $size width"
                Assert-CcodEqual $size $bitmap.Height "$color $size height"
                Assert-CcodTrue (Test-CcodOpaquePixels -Bitmap $bitmap -Region 'base') "$color $size has dark rounded base"
                Assert-CcodTrue (Test-CcodLightPixels -Bitmap $bitmap -Region 'links') "$color $size has visible bridge links"
                Assert-CcodTrue (Test-CcodStatusPixels -Bitmap $bitmap -Region 'dot' -Color $color) "$color $size has correct outlined status dot"
                Assert-CcodTrue (Test-CcodTransparentCorners -Bitmap $bitmap) "$color $size corners are transparent"
            }finally{& $production.DisposeIconResource $bitmap}
        }
    }
}))

$results.Add((Invoke-CcodTest 'constructs one fake-first STA tray graph and closes every owned resource exactly once' {
    $fake=New-CcodTrayFakeAdapters
    $queue=New-CcodTrayTestQueue
    $ticks=[pscustomobject]@{Count=0}
    $onTick={$ticks.Count=$ticks.Count+1}.GetNewClosure()
    $context=New-CcodTrayContext -CommandQueue $queue -OnTick $onTick -Adapters $fake.Adapters
    Assert-CcodEqual 'Open' $context.State 'context opens only after complete construction'
    Assert-CcodEqual 37 $context.OwnerManagedThreadId 'owner managed thread is recorded'
    Assert-CcodEqual 1 @($fake.State.Objects|Where-Object Kind -eq 'ApplicationContext').Count 'one application context'
    Assert-CcodEqual 1 @($fake.State.Objects|Where-Object Kind -eq 'Timer').Count 'one timer'
    Assert-CcodEqual 1 @($fake.State.Objects|Where-Object Kind -eq 'NotifyIcon').Count 'one notify icon'
    Assert-CcodEqual 1 @($fake.State.Objects|Where-Object Kind -eq 'Menu').Count 'one menu'
    Assert-CcodEqual 3 @($fake.State.Objects|Where-Object Kind -eq 'Row').Count 'three read-only rows'
    Assert-CcodEqual 6 @($fake.State.Objects|Where-Object Kind -eq 'MenuItem').Count 'six command items'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*'}).Count 'eight cached bitmap sizes and colors'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'Draw:*'}).Count 'eight cached bitmaps are drawn once'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'Clone:*'}).Count 'eight cached icon clones are created'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'every temporary HICON is destroyed immediately'
    Assert-CcodEqual 'Gray:16,Gray:32,Green:16,Green:32,Yellow:16,Yellow:32,Red:16,Red:32' (@($context.Icons.Keys)-join ',') 'cached icon keys are exact and ordered'
    $iconCalls=@($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'})
    $expectedIconCalls=@(
        'Bitmap:Gray:16','Draw:Gray:16','GetHicon:Gray:16','Clone:Gray:16','DestroyIcon:1001','DisposeIcon:Gray:16',
        'Bitmap:Gray:32','Draw:Gray:32','GetHicon:Gray:32','Clone:Gray:32','DestroyIcon:1002','DisposeIcon:Gray:32',
        'Bitmap:Green:16','Draw:Green:16','GetHicon:Green:16','Clone:Green:16','DestroyIcon:1003','DisposeIcon:Green:16',
        'Bitmap:Green:32','Draw:Green:32','GetHicon:Green:32','Clone:Green:32','DestroyIcon:1004','DisposeIcon:Green:32',
        'Bitmap:Yellow:16','Draw:Yellow:16','GetHicon:Yellow:16','Clone:Yellow:16','DestroyIcon:1005','DisposeIcon:Yellow:16',
        'Bitmap:Yellow:32','Draw:Yellow:32','GetHicon:Yellow:32','Clone:Yellow:32','DestroyIcon:1006','DisposeIcon:Yellow:32',
        'Bitmap:Red:16','Draw:Red:16','GetHicon:Red:16','Clone:Red:16','DestroyIcon:1007','DisposeIcon:Red:16',
        'Bitmap:Red:32','Draw:Red:32','GetHicon:Red:32','Clone:Red:32','DestroyIcon:1008','DisposeIcon:Red:32'
    )
    Assert-CcodEqual ($expectedIconCalls-join ',') ($iconCalls-join ',') 'each temporary HICON is destroyed before its bitmap and the next icon'
    Assert-CcodEqual 250 $context.Timer.Properties.Interval 'single timer is exactly 250 ms'
    Assert-CcodEqual $true $context.Timer.Properties.Started 'timer starts once after graph creation'
    Assert-CcodEqual $true $context.NotifyIcon.Properties.Visible 'notify icon becomes visible only after setup'

    $tickOutput=@(& $context.Timer.Events.Tick)
    Assert-CcodEqual 0 $tickOutput.Count 'timer callback emits no output'
    Assert-CcodEqual $false $context.CallbackFailure 'valid timer callback is not contained as a failure'
    Assert-CcodEqual 1 $ticks.Count 'one tick invokes infrastructure callback once'

    $first=Close-CcodTrayContext -Context $context
    Assert-CcodEqual 'SchemaVersion,Closed,CleanupCodes' (($first.PSObject.Properties.Name)-join ',') 'close receipt has exact fields'
    Assert-CcodEqual 1 $first.SchemaVersion 'close receipt schema'
    Assert-CcodEqual $true $first.Closed 'first close succeeds'
    Assert-CcodEqual 0 @($first.CleanupCodes).Count 'clean fake close has no failure code'
    Assert-CcodEqual 'Closed' $context.State 'close latches state before cleanup'
    Assert-CcodEqual 8 @($context.Icons.Values|Where-Object {$_.DisposeCount -eq 1}).Count 'all owned icon clones disposed exactly once'
    Assert-CcodEqual 0 @($context.Icons.Values|Where-Object {$_.DisposeCount -gt 1}).Count 'no owned icon clone is disposed twice'
    $callCount=$fake.State.Calls.Count
    $second=Close-CcodTrayContext -Context $context
    Assert-CcodEqual $true $second.Closed 'second close is a success no-op'
    Assert-CcodEqual $callCount $fake.State.Calls.Count 'idempotent close runs no adapters twice'
}))

$results.Add((Invoke-CcodTest 'renders the exact presentation without policy or icon allocation and enqueues six exact commands' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation
        $iconResourceCalls=@($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count
        $output=@(Set-CcodTrayPresentation -Context $context -Presentation $presentation -PackageText $null -RuntimeText $null)
        Assert-CcodEqual 0 $output.Count 'presentation emits no output'
        Assert-CcodEqual 'Status: Current Codex session is fixed' $context.Rows.Status.Properties.Text 'status row is read-only display data'
        Assert-CcodEqual ('Package: '+[char]0x2014) $context.Rows.Package.Properties.Text 'null package renders em dash'
        Assert-CcodEqual ('Runtime: '+[char]0x2014) $context.Rows.Runtime.Properties.Text 'null runtime renders em dash'
        Assert-CcodEqual 'Current Codex session is fixed' $context.NotifyIcon.Properties.Text 'tooltip comes only from Task 9 presentation'
        Assert-CcodEqual 'Green' $context.NotifyIcon.Properties.Icon.Color 'cached green icon selected'
        Assert-CcodEqual $iconResourceCalls @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count 'presentation allocates or disposes no icon resources'

        foreach($kind in @('ApplyNow','ManualRetry','SetAutomationEnabled','SetCandidateCompatibleOptIn','OpenLogs','Uninstall')){
            $context.Items[$kind].Properties.Enabled=$true
            if($kind -ceq 'SetAutomationEnabled'){$context.Items[$kind].Properties.Checked=$false}
            elseif($kind -ceq 'SetCandidateCompatibleOptIn'){$context.Items[$kind].Properties.Checked=$true}
            $callbackOutput=@(& $context.Items[$kind].Events.Click $context.Items[$kind] $null)
            Assert-CcodEqual 0 $callbackOutput.Count "$kind callback emits no output"
        }
        Assert-CcodEqual 6 $queue.Count 'six callbacks enqueue six commands only'
        $expectedKinds=@('ApplyNow','ManualRetry','SetAutomationEnabled','SetCandidateCompatibleOptIn','OpenLogs','Uninstall')
        for($i=0;$i -lt $expectedKinds.Count;$i++){
            $command=$queue.Dequeue()
            Assert-CcodEqual 'Kind,Value,EnqueuedAtUtc' (($command.PSObject.Properties.Name)-join ',') 'command has exact ordered fields'
            Assert-CcodEqual $expectedKinds[$i] $command.Kind 'command kind is exact and case-sensitive'
            if($command.Kind -ceq 'SetAutomationEnabled'){Assert-CcodEqual $false $command.Value 'automation toggle uses sender checked state'}
            elseif($command.Kind -ceq 'SetCandidateCompatibleOptIn'){Assert-CcodEqual $true $command.Value 'candidate toggle uses sender checked state'}
            else{Assert-CcodEqual $null $command.Value 'non-toggle command value is null'}
            Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $command.EnqueuedAtUtc 'command timestamp is canonical UTC o'
        }

        $context.Items.ApplyNow.Properties.Enabled=$false
        @(& $context.Items.ApplyNow.Events.Click $context.Items.ApplyNow $null)|Out-Null
        Assert-CcodEqual 0 $queue.Count 'disabled command callback is a no-op'
        foreach($n in 1..256){$queue.Enqueue([pscustomobject]@{N=$n})}
        @(& $context.Items.OpenLogs.Events.Click $context.Items.OpenLogs $null)|Out-Null
        Assert-CcodEqual 256 $queue.Count 'command queue never exceeds 256'
        Assert-CcodEqual $true $context.CommandOverflowed 'command overflow sets sticky flag'
        $closedCallback=$context.Items.OpenLogs.Events.Click
        [void](Close-CcodTrayContext -Context $context)
        $clockCalls=@($fake.State.Calls|Where-Object {$_ -ceq 'Clock:GetUtcNow'}).Count
        $closedOutput=@(& $closedCallback $context.Items.OpenLogs $null)
        Assert-CcodEqual 0 $closedOutput.Count 'closed callback is a no-output no-op'
        Assert-CcodEqual $clockCalls @($fake.State.Calls|Where-Object {$_ -ceq 'Clock:GetUtcNow'}).Count 'closed callback invokes no clock or queue adapter'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'rejects an invalid presentation color before NotifyIcon mutation or icon allocation' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation;$presentation.Color='Blue'
        $notifyMutations=@($fake.State.Calls|Where-Object {$_ -like 'Set:TrayNotifyIcon:*'}).Count
        $iconResourceCalls=@($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count
        Assert-CcodThrows {Set-CcodTrayPresentation -Context $context -Presentation $presentation} 'CCOD_TRAY_INPUT_INVALID'
        Assert-CcodEqual $notifyMutations @($fake.State.Calls|Where-Object {$_ -like 'Set:TrayNotifyIcon:*'}).Count 'invalid color does not mutate NotifyIcon'
        Assert-CcodEqual $iconResourceCalls @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count 'invalid color allocates or disposes no icon resources'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'rejects malformed presentation display data and wrong-thread or closed updates before touching controls' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        $base=New-CcodValidPresentation
        $extra=[pscustomobject][ordered]@{};foreach($property in $base.PSObject.Properties){$extra|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value};$extra|Add-Member Extra $true
        foreach($case in @(
            {Set-CcodTrayPresentation -Context $context -Presentation $extra},
            {Set-CcodTrayPresentation -Context $context -Presentation $base -PackageText ('p'*161)},
            {Set-CcodTrayPresentation -Context $context -Presentation $base -RuntimeText ('r'*97)},
            {Set-CcodTrayPresentation -Context $context -Presentation $base -PackageText ("pkg"+[char]1)},
            {Set-CcodTrayPresentation -Context $context -Presentation $base -RuntimeText ("runtime"+[char]0x7f)},
            {Set-CcodTrayPresentation -Context $context -Presentation $base -PackageText ("pkg"+[char]0x85)}
        )){Assert-CcodThrows $case 'CCOD_TRAY_INPUT_INVALID'}
        $fake.State.ThreadId=38
        Assert-CcodThrows {Set-CcodTrayPresentation -Context $context -Presentation $base} 'CCOD_TRAY_THREAD_INVALID'
        $fake.State.ThreadId=37
        [void](Close-CcodTrayContext -Context $context)
        Assert-CcodThrows {Set-CcodTrayPresentation -Context $context -Presentation $base} 'CCOD_TRAY_CONTEXT_CLOSED'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'uses Trace first and enqueues only exact ChatGPT start hints before bounded idempotent cleanup' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$signals=[pscustomobject]@{Count=0}
    $signal={$signals.Count=$signals.Count+1}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired $signal -Adapters $fake.Adapters
    Assert-CcodEqual 'Running' $watcher.State 'watcher reaches running after registration decision'
    Assert-CcodEqual 'Trace' $watcher.Mode 'Trace is preferred'
    Assert-CcodEqual 1 $fake.State.TraceCalls 'Trace attempted once'
    Assert-CcodEqual 'Win32_ProcessStartTrace' $fake.State.TraceClass 'Trace capability class is exact'
    Assert-CcodEqual 0 $fake.State.IntrinsicCalls 'Intrinsic not attempted after Trace success'
    foreach($case in @(
        @([uint32]123,'chatgpt.exe'),@([uint32]123,'Other.exe'),@('123','ChatGPT.exe'),@([uint32]0,'ChatGPT.exe'),@([uint32]2147483648,'ChatGPT.exe')
    )){
        $callbackOutput=@(& $fake.State.TraceHandler $case[0] $case[1])
        Assert-CcodEqual 0 $callbackOutput.Count 'rejected watcher hint emits no output'
    }
    Assert-CcodEqual 0 $queue.Count 'name and PID lookalikes are ignored'
    $callbackOutput=@(& $fake.State.TraceHandler ([uint32]123) 'ChatGPT.exe')
    Assert-CcodEqual 0 $callbackOutput.Count 'valid watcher callback emits no output'
    Assert-CcodEqual 1 $queue.Count 'one valid hint is queued'
    $event=$queue.Peek()
    Assert-CcodEqual 'ProcessId,EventKind,ObservedAtUtc' (($event.PSObject.Properties.Name)-join ',') 'watcher event has exact ordered fields'
    Assert-CcodEqual 123 $event.ProcessId 'UInt32 PID is converted losslessly to Int32'
    Assert-CcodEqual 'Started' $event.EventKind 'event kind is fixed'
    Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $event.ObservedAtUtc 'event time is canonical UTC o'
    $staleCallback=$fake.State.TraceHandler
    $first=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 'SchemaVersion,Stopped,CleanupCodes' (($first.PSObject.Properties.Name)-join ',') 'stop receipt has exact fields'
    Assert-CcodEqual $true $first.Stopped 'watcher stops'
    Assert-CcodEqual 0 @($first.CleanupCodes).Count 'normal stop has no cleanup failure'
    Assert-CcodEqual 0 $queue.Count 'stop drains queued hints in finally'
    Assert-CcodEqual 'WatcherDetach,WatcherUnregister,WatcherRemoveJob,WatcherDispose' ((@($fake.State.Calls|Where-Object {$_ -like 'Watcher*'})|ForEach-Object {($_ -split ':')[0]})-join ',') 'watcher cleanup stage order is exact'
    $callCount=$fake.State.Calls.Count
    $second=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual $callCount $fake.State.Calls.Count 'second stop invokes no adapter'
    Assert-CcodEqual $true $second.Stopped 'second stop reuses terminal receipt'
    Assert-CcodEqual 0 @(& $staleCallback ([uint32]124) 'ChatGPT.exe').Count 'stale stopped callback emits nothing'
    Assert-CcodEqual 0 $queue.Count 'stale stopped callback does not enqueue'
}))

$results.Add((Invoke-CcodTest 'falls through Trace to Intrinsic and then ReconciliationOnly on every registration capability failure' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue
    $state=$fake.State
    $fake.Adapters.RegisterTrace={param($SourceIdentifier,$ClassName,$Callback)$state.TraceCalls++;throw "C:\private\trace`n--token hunter2"}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'Intrinsic' $watcher.Mode 'Trace exception falls through to Intrinsic'
    Assert-CcodEqual 1 $state.TraceCalls 'failed Trace attempted once'
    Assert-CcodEqual 1 $state.IntrinsicCalls 'Intrinsic attempted once'
    Assert-CcodEqual ([string]::Join("`r`n",@('SELECT * FROM __InstanceCreationEvent WITHIN 1',"WHERE TargetInstance ISA 'Win32_Process'","AND TargetInstance.Name = 'ChatGPT.exe'"))) $state.IntrinsicQuery 'Intrinsic query is exact multiline text'
    Assert-CcodTrue (@($state.Calls|Where-Object {$_ -like 'WatcherAttemptCleanup:ccod-process-*'}).Count -ge 1) 'failed Trace cleans only its requested private source'
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null

    $fake2=New-CcodTrayFakeAdapters;$state2=$fake2.State
    $fake2.Adapters.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $state2.TraceCalls++;Write-Warning 'SECRET_TRACE_WARNING'
        $state2.ActiveSources[$SourceIdentifier]=[pscustomobject]@{Kind='LeakedTraceResource'}
        [pscustomobject][ordered]@{SourceIdentifier='ccod-process-ffffffffffffffffffffffffffffffff';JobId=999;Resource=[pscustomobject]@{Kind='Malicious'}}
    }.GetNewClosure()
    $fake2.Adapters.RegisterIntrinsic={param($SourceIdentifier,$Query,$Callback)$state2.IntrinsicCalls++;throw 'SECRET_INTRINSIC_FAILURE'}.GetNewClosure()
    $watcher2=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher2.Mode 'diagnostic and exception degrade without public raw error'
    Assert-CcodEqual 1 $state2.TraceCalls 'diagnostic Trace attempted once'
    Assert-CcodEqual 1 $state2.IntrinsicCalls 'failed Intrinsic attempted once'
    Assert-CcodEqual 0 @($state2.Calls|Where-Object {$_ -ceq 'WatcherRemoveJob:999'}).Count 'invalid receipt job is never trusted for cleanup'
    Assert-CcodEqual 0 @($state2.Calls|Where-Object {$_ -like 'WatcherAttemptCleanup:ccod-process-ffffffff*'}).Count 'invalid receipt source is never trusted for cleanup'
    Assert-CcodEqual 2 @($state2.Calls|Where-Object {$_ -like 'WatcherAttemptCleanup:ccod-process-*'}).Count 'each failed attempt cleans only its generated source once'
    Assert-CcodEqual 0 $state2.ActiveSources.Count 'failed attempt cleanup leaves no registered fake resource'
    Stop-CcodProcessWatcher -Watcher $watcher2|Out-Null
}))

$results.Add((Invoke-CcodTest 'never cleans or registers an invalid or repeated generated watcher source' {
    $fake=New-CcodTrayFakeAdapters;$cleanup=[pscustomobject]@{Count=0}
    $fake.Adapters.NewSourceIdentifier={'existing-production-source'}
    $fake.Adapters.CleanupWatcherAttempt={param($Source)$cleanup.Count++}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher.Mode 'invalid generated sources degrade without mutation'
    Assert-CcodEqual 0 $fake.State.TraceCalls 'invalid source never reaches Trace register'
    Assert-CcodEqual 0 $fake.State.IntrinsicCalls 'invalid source never reaches Intrinsic register'
    Assert-CcodEqual 0 $cleanup.Count 'invalid source never reaches cleanup adapter'
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null

    $fake2=New-CcodTrayFakeAdapters;$same='ccod-process-33333333333333333333333333333333';$cleanup2=[pscustomobject]@{Count=0};$state2=$fake2.State
    $fake2.Adapters.NewSourceIdentifier={$same}.GetNewClosure()
    $fake2.Adapters.RegisterTrace={param($Source,$Class,$Callback)$state2.TraceCalls++;throw 'trace failed'}.GetNewClosure()
    $fake2.Adapters.CleanupWatcherAttempt={param($Source)$cleanup2.Count++}.GetNewClosure()
    $watcher2=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    Assert-CcodEqual 1 $state2.TraceCalls 'first exact source attempts Trace once'
    Assert-CcodEqual 0 $state2.IntrinsicCalls 'repeated source never reaches Intrinsic register'
    Assert-CcodEqual 1 $cleanup2.Count 'only the actually attempted Trace source is cleaned'
    Stop-CcodProcessWatcher -Watcher $watcher2|Out-Null
}))

$results.Add((Invoke-CcodTest 'bounds watcher hints and signals full reconciliation once per continuous overflow episode' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;foreach($n in 1..256){$queue.Enqueue($n)}
    $signals=[pscustomobject]@{Count=0};$signal={$signals.Count=$signals.Count+1}.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired $signal -Adapters $fake.Adapters
    @(& $fake.State.TraceHandler ([uint32]301) 'ChatGPT.exe')|Out-Null
    @(& $fake.State.TraceHandler ([uint32]302) 'ChatGPT.exe')|Out-Null
    Assert-CcodEqual 256 $queue.Count 'overflow hints are dropped or coalesced'
    Assert-CcodEqual 1 $signals.Count 'continuous overflow signals once'
    Assert-CcodEqual $true $watcher.FullReconciliationNeeded 'overflow sets full reconciliation flag'
    [void]$queue.Dequeue()
    @(& $fake.State.TraceHandler ([uint32]303) 'ChatGPT.exe')|Out-Null
    Assert-CcodEqual 256 $queue.Count 'capacity becomes usable for a later exact hint'
    @(& $fake.State.TraceHandler ([uint32]304) 'ChatGPT.exe')|Out-Null
    Assert-CcodEqual 2 $signals.Count 'new overflow episode signals exactly once again'
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null
}))

$results.Add((Invoke-CcodTest 'rejects initial queue and adapter contracts before any UI or watcher mutation' {
    foreach($variant in @('TooLarge','Coercive','Diagnostic')){
        $fake=New-CcodTrayFakeAdapters
        if($variant -ceq 'TooLarge'){$fake.Adapters.GetQueueCount={param($Queue)[int]257}}
        elseif($variant -ceq 'Coercive'){$fake.Adapters.GetQueueCount={param($Queue)'0'}}
        else{$fake.Adapters.GetQueueCount={param($Queue)Write-Warning 'SECRET_COUNT';[int]0}}
        Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_INPUT_INVALID'
        Assert-CcodEqual 0 @($fake.State.Calls|Where-Object {$_ -like 'Create:*'}).Count "$variant queue rejection creates no UI"
    }
    $fake=New-CcodTrayFakeAdapters
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters @{UnknownAdapter={}}} 'CCOD_TRAY_INPUT_INVALID'
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters @{GetUtcNow='not-a-scriptblock'}} 'CCOD_TRAY_INPUT_INVALID'
    $fake.State.Apartment='MTA'
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_THREAD_INVALID'
    Assert-CcodEqual 0 @($fake.State.Calls|Where-Object {$_ -like 'Create:*'}).Count 'non-STA rejection creates no UI'
}))

$results.Add((Invoke-CcodTest 'continues every tray and watcher cleanup stage with bounded allowlisted receipts' {
    $fake=New-CcodTrayFakeAdapters;$context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $context.CleanupCodes.Add('SECRET_PRESEEDED_CODE')
    $cleanup=[pscustomobject]@{Hide=0;Stop=0;Ui=0;Icon=0;Detach=0;Exit=0}
    $context.Adapters.SetUiVisible={param($Object,$Visible)$cleanup.Hide++;throw 'SECRET_HIDE'}.GetNewClosure()
    $context.Adapters.StopUiTimer={param($Timer)$cleanup.Stop++;throw 'SECRET_STOP'}.GetNewClosure()
    $context.Adapters.DisposeUiObject={param($Object)$cleanup.Ui++;throw 'SECRET_UI'}.GetNewClosure()
    $context.Adapters.DisposeIconResource={param($Object)$cleanup.Icon++;throw 'SECRET_ICON'}.GetNewClosure()
    $context.Adapters.DetachUiCallback={param($Receipt)$cleanup.Detach++;throw 'SECRET_DETACH'}.GetNewClosure()
    $context.Adapters.ExitUiContext={param($Object)$cleanup.Exit++;throw 'SECRET_EXIT'}.GetNewClosure()
    $receipt=Close-CcodTrayContext -Context $context
    $expected='CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED,CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED,CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_CONTROL_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED,CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED,CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED'
    Assert-CcodEqual $expected (@($receipt.CleanupCodes)-join ',') 'tray cleanup codes are ordered deduplicated and allowlisted'
    Assert-CcodTrue ($cleanup.Hide -ge 1 -and $cleanup.Stop -eq 1 -and $cleanup.Ui -ge 4 -and $cleanup.Icon -eq 8 -and $cleanup.Detach -eq 7 -and $cleanup.Exit -eq 1) 'all tray cleanup stages continue after failures'
    Assert-CcodTrue (($receipt|ConvertTo-Json -Compress) -cnotmatch 'SECRET') 'tray receipt exposes no injected text'

    $fake2=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$watcher=Start-CcodProcessWatcher -Queue $queue -OnFullReconciliationRequired {} -Adapters $fake2.Adapters;$queue.Enqueue('hint')
    $watcher.CleanupCodes.Add('SECRET_PRESEEDED_CODE')
    $wcalls=[pscustomobject]@{Detach=0;Unregister=0;Remove=0;Dispose=0}
    $watcher.Adapters.DetachWatcherCallback={param($x)$wcalls.Detach++;throw 'SECRET'}.GetNewClosure()
    $watcher.Adapters.UnregisterWatcher={param($x)$wcalls.Unregister++;throw 'SECRET'}.GetNewClosure()
    $watcher.Adapters.RemoveWatcherJob={param($x)$wcalls.Remove++;throw 'SECRET'}.GetNewClosure()
    $watcher.Adapters.DisposeWatcherResource={param($x)$wcalls.Dispose++;throw 'SECRET'}.GetNewClosure()
    $wreceipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 'CCOD_WATCHER_CLEANUP_CALLBACK_DETACH_FAILED,CCOD_WATCHER_CLEANUP_UNREGISTER_FAILED,CCOD_WATCHER_CLEANUP_JOB_REMOVE_FAILED,CCOD_WATCHER_CLEANUP_RESOURCE_DISPOSE_FAILED' (@($wreceipt.CleanupCodes)-join ',') 'watcher cleanup codes are exact and sanitized'
    Assert-CcodEqual '1,1,1,1' "$($wcalls.Detach),$($wcalls.Unregister),$($wcalls.Remove),$($wcalls.Dispose)" 'all watcher cleanup stages run once'
    Assert-CcodEqual 0 $queue.Count 'queue drains despite watcher cleanup failures'
}))

$results.Add((Invoke-CcodTest 'contains all six PowerShell streams and returns only fixed null-target public errors' {
    foreach($stream in @('Output','Error','Warning','Verbose','Debug','Information')){
        $fake=New-CcodTrayFakeAdapters;$secret="SECRET_STREAM_$stream"
        $fake.Adapters.SetUiProperty={
            param($Object,$Name,$Value)
            switch($stream){
                'Output'{Write-Output $secret};'Error'{Write-Error $secret -ErrorAction Continue};'Warning'{Write-Warning $secret}
                'Verbose'{Write-Verbose $secret};'Debug'{Write-Debug $secret};'Information'{Write-Information $secret}
            }
        }.GetNewClosure()
        $caught=$null;try{New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters|Out-Null}catch{$caught=$_}
        Assert-CcodTrue ($null -ne $caught) "$stream adapter diagnostic is rejected"
        Assert-CcodEqual 'CCOD_TRAY_CREATE_FAILED' (($caught.FullyQualifiedErrorId -split ',')[0]) "$stream maps to fixed create ID"
        Assert-CcodEqual 'The tray UI operation failed safely.' $caught.Exception.Message "$stream maps to fixed message"
        Assert-CcodEqual $null $caught.TargetObject "$stream has null target"
        Assert-CcodTrue (-not (($caught|Out-String).Contains($secret))) "$stream secret is contained"
        Assert-CcodTrue (-not (($Error|Out-String).Contains($secret))) "$stream secret is removed from caller error history"
    }
}))

$results.Add((Invoke-CcodTest 'removes a new adapter error from a full caller history without removing the old head' {
    $savedErrors=@($global:Error)
    try{
        $global:Error.Clear()
        $oldHead=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('OLD_HEAD'),'OLD_HEAD',[Management.Automation.ErrorCategory]::NotSpecified,$null)
        [void]$global:Error.Add($oldHead)
        foreach($index in 1..255){
            $old=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("OLD_$index"),"OLD_$index",[Management.Automation.ErrorCategory]::NotSpecified,$null)
            [void]$global:Error.Add($old)
        }
        Assert-CcodEqual 256 $global:Error.Count 'caller error history is full before the adapter runs'
        $secret='SECRET_FULL_ERROR_HISTORY'
        $callback={Write-Error $secret -ErrorAction Continue}.GetNewClosure()
        $module=Get-Module TrayUi
        $capture=& $module {param($Callback)Invoke-CcodTrayAdapterCapture $Callback @()} $callback
        Assert-CcodEqual 1 @($capture.Items).Count 'adapter error remains captured as a diagnostic stream'
        Assert-CcodTrue ([object]::ReferenceEquals($oldHead,$global:Error[0])) 'cleanup stops at the caller old head object'
        Assert-CcodTrue (-not (($global:Error|Out-String).Contains($secret))) 'new secret error is absent from caller history even when count never grew'
    }finally{
        $global:Error.Clear()
        foreach($old in $savedErrors){[void]$global:Error.Add($old)}
    }
}))

$results.Add((Invoke-CcodTest 'rejects suppressed adapter errors and restores the complete caller error history' {
    $savedErrors=@($global:Error)
    try{
        $global:Error.Clear()
        $before=[Collections.Generic.List[object]]::new()
        foreach($index in 1..4){
            $old=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("OLD_SUPPRESSED_$index"),"OLD_SUPPRESSED_$index",[Management.Automation.ErrorCategory]::NotSpecified,$null)
            $before.Add($old);[void]$global:Error.Add($old)
        }
        $secret='SECRET_SUPPRESSED_ERROR_HISTORY'
        $callback={foreach($index in 1..40){Write-Error "$secret`_$index" -ErrorAction SilentlyContinue};'valid'}.GetNewClosure()
        $module=Get-Module TrayUi
        $capture=& $module {param($Callback)Invoke-CcodTrayAdapterCapture $Callback @()} $callback
        Assert-CcodEqual $true $capture.Threw 'suppressed Error-stream records make the adapter capture fail'
        Assert-CcodEqual 4 $global:Error.Count 'caller error history count is restored exactly'
        for($index=0;$index -lt $before.Count;$index++){
            Assert-CcodTrue ([object]::ReferenceEquals($before[$index],$global:Error[$index])) "caller error history reference and order $index are restored"
        }
        Assert-CcodTrue (-not (($global:Error|Out-String).Contains($secret))) 'no suppressed adapter secret remains in caller error history'
    }finally{
        $global:Error.Clear()
        foreach($old in $savedErrors){[void]$global:Error.Add($old)}
    }
}))

$results.Add((Invoke-CcodTest 'normalizes three forged public handles before any monitor operation' {
    $presentation=New-CcodValidPresentation
    $forgedContext=[pscustomobject]@{State='Open';Adapters=@{}}
    $forgedContext.PSObject.TypeNames.Insert(0,'Ccod.TrayContext')
    $forgedWatcher=[pscustomobject]@{State='Running';Adapters=@{}}
    $forgedWatcher.PSObject.TypeNames.Insert(0,'Ccod.ProcessWatcher')
    $cases=@(
        [pscustomobject]@{Name='Set';ExpectedId='CCOD_TRAY_INPUT_INVALID';ExpectedMessage='The tray UI operation failed safely.';Action={Set-CcodTrayPresentation -Context $forgedContext -Presentation $presentation}.GetNewClosure()},
        [pscustomobject]@{Name='Close';ExpectedId='CCOD_TRAY_INPUT_INVALID';ExpectedMessage='The tray UI operation failed safely.';Action={Close-CcodTrayContext -Context $forgedContext}.GetNewClosure()},
        [pscustomobject]@{Name='Stop';ExpectedId='CCOD_WATCHER_INPUT_INVALID';ExpectedMessage='The process watcher operation failed safely.';Action={Stop-CcodProcessWatcher -Watcher $forgedWatcher}.GetNewClosure()}
    )
    foreach($case in $cases){
        $caught=$null
        try{& $case.Action|Out-Null}catch{$caught=$_}
        Assert-CcodTrue ($null -ne $caught) "$($case.Name) rejects a forged handle"
        Assert-CcodEqual $case.ExpectedId (($caught.FullyQualifiedErrorId -split ',')[0]) "$($case.Name) maps to its fixed input ID"
        Assert-CcodEqual $case.ExpectedMessage $caught.Exception.Message "$($case.Name) maps to its fixed message"
        Assert-CcodEqual $null $caught.TargetObject "$($case.Name) has a null target"
    }
}))

$results.Add((Invoke-CcodTest 'accepts the exact Closing snapshot after OnTick is cleared and returns its provisional receipt' {
    $fake=New-CcodTrayFakeAdapters
    $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $originalOnTick=$context.OnTick
    $provisional=[pscustomobject][ordered]@{SchemaVersion=1;Closed=$true;CleanupCodes=@()}
    try{
        $context.State='Closing';$context.OnTick=$null;$context.CloseReceipt=$provisional
        $returned=Close-CcodTrayContext -Context $context
        Assert-CcodTrue ([object]::ReferenceEquals($provisional,$returned)) 'second Close returns the same provisional receipt after waiting its gate'
    }finally{
        $context.State='Open';$context.OnTick=$originalOnTick;$context.CloseReceipt=$null
        Close-CcodTrayContext -Context $context|Out-Null
    }
}))

$results.Add((Invoke-CcodTest 'accepts every exact Stopping callback-clear snapshot and returns its provisional receipt' {
    $fake=New-CcodTrayFakeAdapters
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    $originalCallback=$watcher.Callback;$originalSignal=$watcher.OnFullReconciliationRequired
    $provisional=[pscustomobject][ordered]@{SchemaVersion=1;Stopped=$true;CleanupCodes=@()}
    try{
        $cases=@(
            [pscustomobject]@{Name='callback-cleared-first';Callback=$null;Signal=$originalSignal},
            [pscustomobject]@{Name='signal-cleared';Callback=$originalCallback;Signal=$null},
            [pscustomobject]@{Name='both-cleared';Callback=$null;Signal=$null}
        )
        foreach($case in $cases){
            $watcher.State='Stopping';$watcher.Callback=$case.Callback;$watcher.OnFullReconciliationRequired=$case.Signal;$watcher.StopReceipt=$provisional
            $returned=Stop-CcodProcessWatcher -Watcher $watcher
            Assert-CcodTrue ([object]::ReferenceEquals($provisional,$returned)) "$($case.Name) returns the same provisional receipt after waiting its gate"
        }
    }finally{
        $watcher.State='Running';$watcher.Callback=$originalCallback;$watcher.OnFullReconciliationRequired=$originalSignal;$watcher.StopReceipt=$null
        Stop-CcodProcessWatcher -Watcher $watcher|Out-Null
    }
}))

$results.Add((Invoke-CcodTest 'recovers every identifiable UI bitmap HICON clone and attachment emitted before a diagnostic failure' {
    foreach($stage in @('CreateUiObject','CreateBitmap','GetHicon','CloneIcon','AttachUiCallback')){
        $fake=New-CcodTrayFakeAdapters;$original=$fake.Adapters[$stage]
        switch($stage){
            'CreateUiObject' {$fake.Adapters[$stage]={param($Kind,$Name)$value=& $original $Kind $Name;$value;Write-Warning 'SECRET_AFTER_UI'}.GetNewClosure()}
            'CreateBitmap' {$fake.Adapters[$stage]={param($Color,$Size)$value=& $original $Color $Size;$value;Write-Warning 'SECRET_AFTER_BITMAP'}.GetNewClosure()}
            'GetHicon' {$fake.Adapters[$stage]={param($Bitmap)$value=& $original $Bitmap;$value;Write-Warning 'SECRET_AFTER_HICON'}.GetNewClosure()}
            'CloneIcon' {$fake.Adapters[$stage]={param($Hicon,$Color,$Size)$value=& $original $Hicon $Color $Size;$value;Write-Warning 'SECRET_AFTER_CLONE'}.GetNewClosure()}
            'AttachUiCallback' {$fake.Adapters[$stage]={param($Object,$EventName,$Callback)$value=& $original $Object $EventName $Callback;$value;Write-Warning 'SECRET_AFTER_ATTACH'}.GetNewClosure()}
        }
        Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
        Assert-CcodTrue (@($fake.State.Objects|Where-Object {$_.DisposeCount -gt 1}).Count -eq 0) "$stage never double-disposes a UI object"
        Assert-CcodTrue (@($fake.State.Bitmaps|Where-Object {$_.DisposeCount -ne 1}).Count -eq 0) "$stage disposes every created bitmap once"
        Assert-CcodTrue (@($fake.State.IconClones|Where-Object {$_.DisposeCount -ne 1}).Count -eq 0) "$stage disposes every created clone once"
        if($stage -ceq 'GetHicon'){Assert-CcodEqual 1 @($fake.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'diagnostic HICON is still destroyed'}
        if($stage -ceq 'AttachUiCallback'){Assert-CcodEqual 1 @($fake.State.Calls|Where-Object {$_ -like 'Detach:ApplyNowItem:*'}).Count 'diagnostic attachment is detached immediately'}
    }
    $invalid=New-CcodTrayFakeAdapters;$invalid.Adapters.GetHicon={param($Bitmap)'1001';Write-Warning 'invalid hicon'}
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $invalid.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    Assert-CcodEqual 0 @($invalid.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'invalid HICON-shaped output is never passed to DestroyIcon'
    $duplicate=New-CcodTrayFakeAdapters;$originalHicon=$duplicate.Adapters.GetHicon
    $duplicate.Adapters.GetHicon={param($Bitmap)$value=& $originalHicon $Bitmap;$value;$value;Write-Warning 'duplicate hicon'}.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $duplicate.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    Assert-CcodEqual 1 @($duplicate.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'duplicate exact HICON output is destroyed once'
}))

$results.Add((Invoke-CcodTest 'recovers the seventeenth recognizable owned UI object and HICON without double cleanup' {
    $uiFake=New-CcodTrayFakeAdapters
    $created=[Collections.Generic.List[object]]::new();$uiState=$uiFake.State
    $uiFake.Adapters.CreateUiObject={
        param($Kind,$Name)
        foreach($index in 1..17){
            $object=[pscustomobject]@{Kind=$Kind;Name="$Name-$index";Properties=[ordered]@{IsDisposed=$false};Events=[ordered]@{};Children=[Collections.Generic.List[object]]::new();Disposed=$false;DisposeCount=0}
            $created.Add($object);$uiState.Objects.Add($object);$object
        }
    }.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $uiFake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    Assert-CcodEqual 17 $created.Count 'owned factory emitted exactly seventeen recognizable UI objects'
    Assert-CcodEqual 17 @($created|Where-Object {$_.DisposeCount -eq 1}).Count 'all seventeen UI objects are disposed exactly once'
    Assert-CcodEqual 0 @($created|Where-Object {$_.DisposeCount -gt 1}).Count 'overflow UI object is never double-disposed'

    $hiconFake=New-CcodTrayFakeAdapters;$hiconSeed=[pscustomobject]@{Value=3000}
    $hiconFake.Adapters.GetHicon={
        param($Bitmap)
        foreach($index in 1..17){$hiconSeed.Value++;[IntPtr]$hiconSeed.Value}
    }.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $hiconFake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    $destroyed=@($hiconFake.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'})
    Assert-CcodEqual 17 $destroyed.Count 'all seventeen recognizable HICON outputs are destroyed'
    Assert-CcodEqual 17 @($destroyed|Select-Object -Unique).Count 'every overflow HICON is destroyed exactly once'
}))

$results.Add((Invoke-CcodTest 'does not dispose a child twice when AddUiChild attaches it and then emits a diagnostic' {
    $fake=New-CcodTrayFakeAdapters;$originalAdd=$fake.Adapters.AddUiChild
    $fake.Adapters.AddUiChild={
        param($Parent,$Child)
        & $originalAdd $Parent $Child
        Write-Warning 'SECRET_ADD_AFTER_ATTACH'
    }.GetNewClosure()
    Assert-CcodThrows {New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters} 'CCOD_TRAY_CREATE_FAILED'
    $statusRows=@($fake.State.Objects|Where-Object {$_.Name -ceq 'StatusRow'})
    Assert-CcodEqual 1 $statusRows.Count 'the partial-success path creates one first child'
    Assert-CcodEqual 1 $statusRows[0].DisposeCount 'the attached child is disposed exactly once through its menu owner'
    Assert-CcodEqual 0 @($fake.State.Objects|Where-Object {$_.DisposeCount -gt 1}).Count 'partial Add ownership never permits a second direct dispose'
}))

$results.Add((Invoke-CcodTest 'does not dispose nine children twice when Menu disposal cascades and then emits a diagnostic' {
    $fake=New-CcodTrayFakeAdapters
    $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $menu=$context.Menu;$children=@($menu.Children);$originalDispose=$context.Adapters.DisposeUiObject
    Assert-CcodEqual 9 $children.Count 'complete tray owns three rows and six items before close'
    $context.Adapters.DisposeUiObject={
        param($Object)
        & $originalDispose $Object
        if($Object.Kind -ceq 'Menu'){Write-Warning 'SECRET_MENU_AFTER_CASCADE'}
    }.GetNewClosure()
    $receipt=Close-CcodTrayContext -Context $context
    Assert-CcodEqual 9 @($children|Where-Object {$_.DisposeCount -eq 1}).Count 'all cascaded children remain exactly-once disposed'
    Assert-CcodEqual 0 @($children|Where-Object {$_.DisposeCount -gt 1}).Count 'diagnostic after menu cascade never triggers direct redisposal'
    Assert-CcodEqual 1 $menu.DisposeCount 'menu itself is disposed exactly once'
    Assert-CcodEqual 'CCOD_TRAY_CLEANUP_MENU_DISPOSE_FAILED' (@($receipt.CleanupCodes)-join ',') 'diagnostic remains a bounded sanitized menu cleanup failure'
}))

$results.Add((Invoke-CcodTest 'stops fallback after failed attempt cleanup and retries only that exact source during Stop' {
    $fake=New-CcodTrayFakeAdapters;$state=$fake.State;$cleanup=[pscustomobject]@{Calls=0;Source=$null}
    $fake.Adapters.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $state.TraceCalls++;$state.TraceHandler=$Callback;$state.ActiveSources[$SourceIdentifier]=[pscustomobject]@{Kind='TracePartial'}
        Write-Warning 'SECRET_PARTIAL';[pscustomobject][ordered]@{SourceIdentifier=$SourceIdentifier;JobId=11;Resource=$state.ActiveSources[$SourceIdentifier]}
    }.GetNewClosure()
    $fake.Adapters.CleanupWatcherAttempt={
        param($SourceIdentifier)
        $cleanup.Calls++;$cleanup.Source=$SourceIdentifier
        if($cleanup.Calls -eq 1){throw 'SECRET_CLEANUP'}
        [void]$state.ActiveSources.Remove($SourceIdentifier)
    }.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher.Mode 'cleanup failure forces reconciliation-only mode'
    Assert-CcodEqual 0 $state.IntrinsicCalls 'cleanup failure never stacks Intrinsic registration'
    Assert-CcodEqual 1 $watcher.PendingAttemptSources.Count 'failed exact source is retained for Stop retry'
    $stale=$state.TraceHandler
    $receipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 2 $cleanup.Calls 'Stop retries attempt cleanup exactly once'
    Assert-CcodEqual 0 $state.ActiveSources.Count 'retry removes the partial fake registration'
    Assert-CcodEqual 0 @($receipt.CleanupCodes).Count 'successful Stop retry leaves clean receipt'
    Assert-CcodEqual 0 @(& $stale ([uint32]22) 'ChatGPT.exe').Count 'stale partial callback is stopped no-op'
}))

$results.Add((Invoke-CcodTest 'persists a discovered side-effect job before unregister and removes it on Stop retry' {
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    Assert-CcodEqual 0 @($parseErrors).Count 'production cleanup source parses before isolated execution'
    $defaultFunction=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CcodTrayDefaultAdapters'},$true))[0]
    $cleanupAssignment=@($defaultFunction.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$defaults.CleanupWatcherAttempt'
    },$true))[0]
    $cleanupExpression=@($cleanupAssignment.FindAll({param($node)$node -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true))[0]
    $productionCleanup=$cleanupExpression.ScriptBlock.GetScriptBlock()

    $source='ccod-process-'+('a'*32)
    $world=[pscustomobject]@{
        Subscribers=[Collections.Generic.List[object]]::new();Jobs=@{};RemoveCalls=0;UnregisterCalls=0;GetSubscriberCalls=0;GetJobCalls=0
    }
    $attempts=@{}
    $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
    $variables.Add([Management.Automation.PSVariable]::new('watcherAttemptJobs',$attempts))
    $variables.Add([Management.Automation.PSVariable]::new('watcherAttemptJobLimit',[int]16))
    $fakeCommands=@{
        'Get-EventSubscriber'={param($ErrorAction)$world.GetSubscriberCalls++;@($world.Subscribers)}.GetNewClosure()
        'Unregister-Event'={param($SourceIdentifier,$ErrorAction)$world.UnregisterCalls++;$world.Subscribers.Clear()}.GetNewClosure()
        'Get-Job'={param($ErrorAction)$world.GetJobCalls++;@($world.Jobs.Values)}.GetNewClosure()
        'Remove-Job'={
            param($Id,[switch]$Force,$ErrorAction)
            $world.RemoveCalls++
            if($world.RemoveCalls -eq 1){throw 'FAKE_FIRST_REMOVE_FAILURE'}
            [void]$world.Jobs.Remove([int]$Id)
        }.GetNewClosure()
    }
    $fake=New-CcodTrayFakeAdapters;$state=$fake.State
    $fake.Adapters.RegisterTrace={
        param($SourceIdentifier,$ClassName,$Callback)
        $state.TraceCalls++;$state.TraceHandler=$Callback
        $world.Subscribers.Add([pscustomobject]@{SourceIdentifier=$SourceIdentifier;Action=[pscustomobject]@{Id=[int]321}})
        $world.Jobs[[int]321]=[pscustomobject]@{Id=[int]321}
        throw 'FAKE_REGISTER_SIDE_EFFECT_THEN_THROW'
    }.GetNewClosure()
    $fake.Adapters.CleanupWatcherAttempt={
        param($SourceIdentifier)
        $productionCleanup.InvokeWithContext($fakeCommands,$variables,[object[]]@($SourceIdentifier))|Out-Null
    }.GetNewClosure()
    $watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    Assert-CcodEqual 'ReconciliationOnly' $watcher.Mode 'failed cleanup prevents Intrinsic stacking after a side-effecting Trace throw'
    Assert-CcodEqual 0 $state.IntrinsicCalls 'Intrinsic is not attempted while the side-effect job remains'
    Assert-CcodEqual 1 $world.UnregisterCalls 'first cleanup unregisters the exact discovered subscriber'
    Assert-CcodEqual 1 $world.RemoveCalls 'first cleanup observes the injected job-removal failure'
    Assert-CcodEqual 1 $world.Jobs.Count 'failed first removal leaves the fake job observable'
    $receipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 2 $world.RemoveCalls 'Stop retries the persisted exact discovered job ID'
    Assert-CcodEqual 0 $world.Jobs.Count 'Stop retry removes the orphan candidate completely'
    Assert-CcodEqual 0 @($receipt.CleanupCodes).Count 'successful retry has no cleanup failure receipt'
}))

$results.Add((Invoke-CcodTest 'drains exactly 256 hints cleanly caps 257 and detects an early false dequeue' {
    $fake=New-CcodTrayFakeAdapters;$full=New-CcodTrayTestQueue;foreach($n in 1..256){$full.Enqueue($n)}
    $watcher=Start-CcodProcessWatcher -Queue $full -OnFullReconciliationRequired {} -Adapters $fake.Adapters
    $receipt=Stop-CcodProcessWatcher -Watcher $watcher
    Assert-CcodEqual 0 $full.Count 'exact 256 queue drains completely'
    Assert-CcodEqual 0 @($receipt.CleanupCodes).Count 'exact 256 drain does not misreport limit'

    $fake2=New-CcodTrayFakeAdapters;$over=New-CcodTrayTestQueue;$watcher2=Start-CcodProcessWatcher -Queue $over -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    foreach($n in 1..257){$over.Enqueue($n)}
    $receipt2=Stop-CcodProcessWatcher -Watcher $watcher2
    Assert-CcodEqual 1 $over.Count '257 queue performs no more than 256 dequeues'
    Assert-CcodEqual 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_LIMIT' (@($receipt2.CleanupCodes)-join ',') '257 residual reports stable limit code'

    $fake3=New-CcodTrayFakeAdapters;$stuck=New-CcodTrayTestQueue;$watcher3=Start-CcodProcessWatcher -Queue $stuck -OnFullReconciliationRequired {} -Adapters $fake3.Adapters;$stuck.Enqueue('left')
    $watcher3.Adapters.TryDequeue={param($Queue)[pscustomobject][ordered]@{Succeeded=$false;Value=$null}}
    $receipt3=Stop-CcodProcessWatcher -Watcher $watcher3
    Assert-CcodEqual 1 $stuck.Count 'early false leaves observable residual'
    Assert-CcodEqual 'CCOD_WATCHER_CLEANUP_QUEUE_DRAIN_FAILED' (@($receipt3.CleanupCodes)-join ',') 'early false residual is not claimed clean'
}))

$results.Add((Invoke-CcodTest 'latches close and stop before reentrant cleanup callbacks can dispose twice' {
    $fake=New-CcodTrayFakeAdapters;$context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
    $originalStop=$context.Adapters.StopUiTimer;$stops=[pscustomobject]@{Count=0}
    $context.Adapters.StopUiTimer={param($Timer)$stops.Count++;Close-CcodTrayContext -Context $context|Out-Null;& $originalStop $Timer}.GetNewClosure()
    Close-CcodTrayContext -Context $context|Out-Null
    Assert-CcodEqual 1 $stops.Count 'reentrant close does not repeat timer stop'
    Assert-CcodEqual 8 @($fake.State.IconClones|Where-Object {$_.DisposeCount -eq 1}).Count 'reentrant close disposes each owned clone once'

    $fake2=New-CcodTrayFakeAdapters;$watcher=Start-CcodProcessWatcher -Queue (New-CcodTrayTestQueue) -OnFullReconciliationRequired {} -Adapters $fake2.Adapters
    $originalDetach=$watcher.Adapters.DetachWatcherCallback;$detaches=[pscustomobject]@{Count=0}
    $watcher.Adapters.DetachWatcherCallback={param($Receipt)$detaches.Count++;Stop-CcodProcessWatcher -Watcher $watcher|Out-Null;& $originalDetach $Receipt}.GetNewClosure()
    Stop-CcodProcessWatcher -Watcher $watcher|Out-Null
    Assert-CcodEqual 1 $detaches.Count 'reentrant stop does not repeat watcher cleanup'
    Assert-CcodEqual 1 @($fake2.State.Calls|Where-Object {$_ -like 'WatcherRemoveJob:*'}).Count 'job removal occurs once'
}))

$results.Add((Invoke-CcodTest 'keeps production defaults lazy and the Task10C2 AST free of forbidden mutation surfaces' {
    Assert-CcodEqual $null ('CcodTrayNativeMethods' -as [type]) 'fake-only tests never load native HICON helper type'
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    Assert-CcodEqual 0 @($parseErrors).Count 'TrayUi module parses cleanly'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$_})
    foreach($forbidden in @('Start-Process','Stop-Process','Get-AppxPackage','Set-ItemProperty','New-ItemProperty','schtasks.exe','node.exe','git.exe')){
        Assert-CcodEqual 0 @($commands|Where-Object {$_ -ceq $forbidden}).Count "$forbidden is absent from Task10C2 AST"
    }
    Assert-CcodTrue ((Get-Content -LiteralPath $modulePath -Raw).Contains('Register-WmiEvent -Class $ClassName')) 'production Trace default remains lazy source text only'
}))

$results.Add((Invoke-CcodTest 'executes only extracted production WMI action ASTs with fake Event and MessageData values' {
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Register-WmiEvent'},$true))
    Assert-CcodEqual 2 $commands.Count 'there are exactly two production WMI registrations in source'
    $traceCommand=@($commands|Where-Object {$_.Extent.Text -cmatch '-Class\s+\$ClassName'})[0]
    $intrinsicCommand=@($commands|Where-Object {$_.Extent.Text -cmatch '-Query\s+\$Query'})[0]
    Assert-CcodTrue ($traceCommand.Extent.Text -cmatch '-MessageData\s+\$Callback') 'Trace binds callback only through MessageData'
    Assert-CcodTrue ($intrinsicCommand.Extent.Text -cmatch '-MessageData\s+\$Callback') 'Intrinsic binds callback only through MessageData'
    $traceAction=@($traceCommand.CommandElements|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[0].ScriptBlock.GetScriptBlock()
    $intrinsicAction=@($intrinsicCommand.CommandElements|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]})[0].ScriptBlock.GetScriptBlock()
    $seen=[pscustomobject]@{TraceId=$null;TraceName=$null;IntrinsicId=$null;IntrinsicName=$null}
    $traceCallback={param($processId,$name)$seen.TraceId=$processId;$seen.TraceName=$name}.GetNewClosure()
    $intrinsicCallback={param($processId,$name)$seen.IntrinsicId=$processId;$seen.IntrinsicName=$name}.GetNewClosure()
    $traceEvent=[pscustomobject]@{MessageData=$traceCallback;SourceEventArgs=[pscustomobject]@{NewEvent=[pscustomobject]@{ProcessID=[uint32]123;ProcessName='ChatGPT.exe'}}}
    $intrinsicEvent=[pscustomobject]@{MessageData=$intrinsicCallback;SourceEventArgs=[pscustomobject]@{NewEvent=[pscustomobject]@{TargetInstance=[pscustomobject]@{ProcessId=[uint32]124;Name='ChatGPT.exe'}}}}
    foreach($case in @(@($traceAction,$traceEvent),@($intrinsicAction,$intrinsicEvent))){
        $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new();$variables.Add([Management.Automation.PSVariable]::new('Event',$case[1]))
        $case[0].InvokeWithContext($null,$variables,[object[]]@())|Out-Null
    }
    Assert-CcodEqual ([uint32]123) $seen.TraceId 'Trace action forwards raw UInt32 without touching read-only PID'
    Assert-CcodEqual 'ChatGPT.exe' $seen.TraceName 'Trace action forwards exact name'
    Assert-CcodEqual ([uint32]124) $seen.IntrinsicId 'Intrinsic action forwards raw UInt32'
    Assert-CcodEqual 'ChatGPT.exe' $seen.IntrinsicName 'Intrinsic action forwards exact name'
    $text=Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('Remove-Job -Id $jobId -Force -ErrorAction Stop')) 'attempt cleanup never hides a real job-removal failure'
    Assert-CcodTrue ($text.Contains('$watcherAttemptJobs[$SourceIdentifier]')) 'attempt cleanup retains source-bound job identity for retry'
}))


$results += Invoke-CcodTest 'production tray icon paths dispose temporary handles and use OrderedDictionary Contains' {
    $text = Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('$temporary.Dispose()')) 'CloneIcon disposes the temporary FromHandle icon'
    Assert-CcodTrue ($text.Contains('Icons.Contains($color')) 'icon map uses OrderedDictionary Contains, not ContainsKey'
    Assert-CcodTrue (-not $text.Contains('Icons.ContainsKey(')) 'no OrderedDictionary ContainsKey misuse remains'
    Assert-CcodTrue ($text.Contains('$iconCleanupFailed -and -not $context.Icons.Contains($color')) 'icon cleanup failure is non-fatal after a successful clone'
}

$results += Invoke-CcodTest 'production AttachUiCallback handlers capture the callback scriptblock' {
    $text = Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}.GetNewClosure()')) 'event handler wraps the callback in a closure so Timer ticks survive the adapter scope'
    $needle = '[EventHandler]{param($sender,$eventArgs)& $Callback $sender $eventArgs}'
    $index = $text.IndexOf($needle)
    Assert-CcodTrue ($index -ge 0) 'event handler needle is present'
    $tail = $text.Substring($index + $needle.Length, [Math]::Min(24, $text.Length - $index - $needle.Length))
    Assert-CcodTrue ($tail.StartsWith('.GetNewClosure()')) 'every event handler needle is immediately closed over'
}

$results|ForEach-Object{"PASS $($_.Name)"}
