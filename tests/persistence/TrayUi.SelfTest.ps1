$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\TrayUi.psm1'
$localizationPath=Join-Path $repositoryRoot 'src\persistence\modules\UiLocalization.psm1'
$resourcesRoot=Join-Path $repositoryRoot 'src\persistence\resources'
if(-not [IO.File]::Exists($modulePath)){
    throw 'MISSING_TRAY_UI_MODULE: src\persistence\modules\TrayUi.psm1'
}
Import-Module $localizationPath -Force
Import-Module $modulePath -Force
$script:TestEnglishCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode en-US -SystemCultureName en-US
$script:TestChineseCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode zh-CN -SystemCultureName zh-CN
$script:TestSystemCatalog=Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode System -SystemCultureName zh-CN

function New-CcodTestTrayContext {
    param($CommandQueue,[scriptblock]$OnTick,$Adapters,$Catalog=$script:TestEnglishCatalog,[string]$LanguageMode='en-US',[string]$SystemCultureName='en-US')
    TrayUi\New-CcodTrayContext -CommandQueue $CommandQueue -OnTick $OnTick -Catalog $Catalog -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName -Adapters $Adapters
}

function Set-CcodTestTrayPresentation {
    param($Context,$Presentation,$Catalog=$script:TestEnglishCatalog,[string]$LanguageMode='en-US',[string]$SystemCultureName='en-US')
    TrayUi\Set-CcodTrayPresentation -Context $Context -Presentation $Presentation -Catalog $Catalog -LanguageMode $LanguageMode -SystemCultureName $SystemCultureName
}
Set-Alias -Name New-CcodTrayContext -Value New-CcodTestTrayContext -Scope Script
Set-Alias -Name Set-CcodTrayPresentation -Value Set-CcodTestTrayPresentation -Scope Script

function New-CcodTrayTestQueue {
    Write-Output -NoEnumerate ([Collections.Generic.Queue[object]]::new())
}

function New-CcodTrayFakeAdapters {
    $state=[pscustomobject]@{
        Calls=[Collections.Generic.List[string]]::new()
        Objects=[Collections.Generic.List[object]]::new()
        Bitmaps=[Collections.Generic.List[object]]::new()
        IconClones=[Collections.Generic.List[object]]::new()
        TitleBitmaps=[Collections.Generic.List[object]]::new()
        BoldFonts=[Collections.Generic.List[object]]::new()
        Dialogs=[Collections.Generic.List[object]]::new()
        NativeOwners=[Collections.Generic.List[object]]::new()
        NativeMenuSpecs=[Collections.Generic.List[object]]::new()
        NativeMenuResults=[Collections.Generic.Queue[int]]::new()
        NativeMenuShowCount=0
        NativeMenuEndCount=0
        NativeOwnerDisposeCount=0
        OnShowNativeMenu=$null
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
                Kind=$Kind;Name=$Name;Properties=[ordered]@{IsDisposed=$false;Font=[pscustomobject]@{Bold=$false}};Events=[ordered]@{}
                Children=[Collections.Generic.List[object]]::new();Disposed=$false;DisposeCount=0
            }
            $state.Objects.Add($object)
            $object
        }.GetNewClosure()
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
        ShowErrorDialog={param($Title,$Message)$state.Dialogs.Add([pscustomobject][ordered]@{Title=$Title;Message=$Message})}.GetNewClosure()
        ConfirmUninstall={param($Title,$Message)$true}
        CreateNativeMenuOwner={
            $owner=[pscustomobject]@{Kind='NativeMenuOwner';Name='TrayNativeMenuOwner';Disposed=$false;DisposeCount=0}
            $state.Calls.Add('NativeOwner:Create');$state.NativeOwners.Add($owner);$owner
        }.GetNewClosure()
        ShowNativeMenu={
            param($Owner,$Items)
            $state.NativeMenuShowCount++;$state.Calls.Add('NativeMenu:Show');$state.NativeMenuSpecs.Add($Items)
            if($state.OnShowNativeMenu -is [scriptblock]){& $state.OnShowNativeMenu}
            if($state.NativeMenuResults.Count -gt 0){return [int]$state.NativeMenuResults.Dequeue()}
            [int]0
        }.GetNewClosure()
        EndNativeMenu={$state.NativeMenuEndCount++;$state.Calls.Add('NativeMenu:End')}.GetNewClosure()
        DisposeNativeMenuOwner={param($Owner)$state.NativeOwnerDisposeCount++;$state.Calls.Add('NativeOwner:Dispose');$Owner.Disposed=$true;$Owner.DisposeCount++}.GetNewClosure()
        DestroyIcon={param($Hicon)$state.Calls.Add("DestroyIcon:$([long]$Hicon)")}.GetNewClosure()
        DisposeIconResource={param($Resource)if($Resource.PSObject.Properties['Kind']){$state.Calls.Add("DisposeResource:$($Resource.Kind):$($Resource.Name)")}else{$state.Calls.Add("DisposeIcon:$($Resource.Color):$($Resource.Size)")};$Resource.Disposed=$true;$Resource.DisposeCount++}.GetNewClosure()
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
        Color='Green';StateKey='Active';SessionReadyVisible=$true;ApplyNowVisible=$false;ApplyNowEnabled=$false;ManualRetryVisible=$false;ManualRetryEnabled=$false
        AutomationToggleEnabled=$true;AutomationChecked=$true
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

$results.Add((Invoke-CcodTest 'exports exactly the six frozen TrayUi functions' {
    $expected='Close-CcodTrayContext,New-CcodTrayContext,Set-CcodTrayPresentation,Show-CcodTrayError,Start-CcodProcessWatcher,Stop-CcodProcessWatcher'
    $actual=((Get-Command -Module TrayUi -CommandType Function).Name|Sort-Object)-join ','
    Assert-CcodEqual $expected $actual 'public export surface remains exact'
}))

$results.Add((Invoke-CcodTest 'cold native owner initialization emits only the owned HWND under diagnostic stream isolation' {
    $escapedModulePath=$modulePath.Replace("'","''")
    $probe=@"
`$ErrorActionPreference='Stop'
Import-Module '$escapedModulePath' -Force
& (Get-Module TrayUi) {
    `$adapters=Get-CcodTrayDefaultAdapters
    `$capture=Invoke-CcodTrayAdapterCapture `$adapters.CreateNativeMenuOwner @()
    try {
        [pscustomobject]@{
            Threw=[bool]`$capture.Threw
            Count=[int]`$capture.Items.Count
            Types=@(`$capture.Items|ForEach-Object { `$_.GetType().FullName })
        } | ConvertTo-Json -Compress
    } finally {
        foreach(`$item in `$capture.Items){if(`$item -is [IDisposable]){`$item.Dispose()}}
    }
}
"@
    $output=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -Command $probe 2>&1)
    Assert-CcodEqual 0 $LASTEXITCODE 'cold native owner probe exits cleanly'
    Assert-CcodEqual 1 $output.Count 'cold native owner probe emits one JSON receipt'
    $receipt=[string]$output[0]|ConvertFrom-Json
    Assert-CcodEqual $false ([bool]$receipt.Threw) 'cold native owner adapter does not throw'
    Assert-CcodEqual 1 ([int]$receipt.Count) 'cold native owner adapter emits only one owned object'
    Assert-CcodEqual 'CcodTrayNativeMenuOwnerV1' (@($receipt.Types)-join ',') 'cold native owner adapter emits no Add-Type diagnostics'
}))

$results.Add((Invoke-CcodTest 'production native menu helper exposes owner show cancel and disposal operations' {
    & (Get-Module TrayUi) {Initialize-CcodTrayNativeMenuV1}
    $helper='CcodTrayNativeMenuV1' -as [type]
    $ownerType='CcodTrayNativeMenuOwnerV1' -as [type]
    Assert-CcodTrue ($null -ne $helper) 'versioned native menu helper type is loaded'
    Assert-CcodTrue ($null -ne $ownerType) 'versioned hidden-owner type is loaded'
    foreach($method in @('Show','EndMenu')){Assert-CcodTrue ($null -ne $helper.GetMethod($method)) "native helper exposes $method"}
    Assert-CcodTrue ($null -ne $ownerType.GetMethod('Dispose')) 'native owner exposes deterministic disposal'
}))

$results.Add((Invoke-CcodTest 'native helper only tracks after a visible offscreen tool owner is foreground and always hides it afterward' {
    $text=Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    $owner=[regex]::Match($text,'(?ms)public sealed class CcodTrayNativeMenuOwnerV1.*?^}\s*\r?\n\r?\npublic static class')
    $helper=[regex]::Match($text,'(?ms)public static class CcodTrayNativeMenuV1.*?^\s*}\s*''@')
    Assert-CcodTrue $owner.Success 'native owner source is present'
    Assert-CcodTrue $helper.Success 'native helper source is present'
    $toolWindow=$owner.Value.IndexOf('WS_EX_TOOLWINDOW')
    $offscreen=$owner.Value.IndexOf('-32000, -32000, 1, 1')
    $show=$owner.Value.IndexOf('ShowWindow(Handle, SW_SHOWNOACTIVATE)')
    $hide=$owner.Value.IndexOf('ShowWindow(handle, SW_HIDE)')
    Assert-CcodTrue ($toolWindow -ge 0 -and $offscreen -gt $toolWindow -and $show -gt $offscreen -and $hide -gt $show) 'owner is an offscreen tool window and has explicit show/hide operations'
    $showForMenu=$helper.Value.IndexOf('owner.ShowForMenu()')
    $foreground=$helper.Value.IndexOf('if (!SetForegroundWindow(owner.Handle))')
    $foregroundProof=$helper.Value.IndexOf('if (GetForegroundWindow() != owner.Handle)')
    $track=$helper.Value.IndexOf('TrackPopupMenuEx(')
    $post=$helper.Value.IndexOf('PostMessageW(owner.Handle, WM_NULL')
    $hideFinally=$helper.Value.IndexOf('owner.HideAfterMenu()')
    Assert-CcodTrue ($showForMenu -ge 0 -and $foreground -gt $showForMenu -and $foregroundProof -gt $foreground -and $track -gt $foregroundProof -and $post -gt $track) 'failed foreground ownership cannot reach TrackPopupMenuEx and WM_NULL follows tracking'
    Assert-CcodTrue ($hideFinally -gt $post -and $helper.Value.IndexOf('finally') -lt $hideFinally) 'the owner is hidden from a finally path after menu processing'
}))

$results.Add((Invoke-CcodTest 'native menu spec preserves exact grouping command ids disabled rows checks and language radios' {
    $presentation=New-CcodValidPresentation
    $spec=& (Get-Module TrayUi) {
        param($Presentation,$Catalog)
        $localized=Resolve-CcodTrayLocalizedStrings -Catalog $Catalog -LanguageMode en-US -SystemCultureName en-US
        $render=New-CcodTrayRenderState -Presentation $Presentation -Localized $localized -LanguageMode en-US -SystemCultureName en-US
        New-CcodTrayNativeMenuSpec -Render $render
    } $presentation $script:TestEnglishCatalog
    Assert-CcodEqual 11 $spec.Count 'active native menu has exact top-level item count'
    $top=@($spec|ForEach-Object {if($_.Separator){'-'}else{"$($_.CommandId):$($_.Enabled):$($_.Checked):$($_.Radio):$($_.Text)"}})
    $expected=@(
        '0:False:False:False:Codex Device Connection',
        ('0:False:False:False:'+[char]0x201c+'Control other devices'+[char]0x201d+' is active for this session'),
        '-',
        '0:False:False:False:Current session is ready',
        '-',
        '1003:True:True:False:Repair new sessions automatically',
        '1004:True:False:False:Allow compatible update trials',
        ('0:True:False:False:Language / '+[char]0x8bed+[char]0x8a00),
        '1008:True:False:False:Open logs',
        '-',
        ('1009:True:False:False:Uninstall supervisor'+[char]0x2026)
    )
    Assert-CcodEqual ($expected-join '|') ($top-join '|') 'top-level system menu order and state are exact'
    $language=@($spec[7].Children|ForEach-Object {"$($_.CommandId):$($_.Enabled):$($_.Checked):$($_.Radio):$($_.Text)"})
    Assert-CcodEqual (('1005:True:False:True:Follow system (English)|1006:True:False:True:'+[char]0x4e2d+[char]0x6587+'|1007:True:True:True:English')) ($language-join '|') 'language submenu ids order and radio truth are exact'
    foreach($item in $spec){Assert-CcodEqual 'CommandId,Text,Enabled,Checked,Radio,Separator,Children' (@($item.PSObject.Properties.Name)-join ',') 'native menu item shape is exact'}
}))

$results.Add((Invoke-CcodTest 'converts the complete PowerShell menu spec to the versioned C# item graph without changing ids or submenu state' {
    $presentation=New-CcodValidPresentation
    $result=& (Get-Module TrayUi) {
        param($Presentation,$Catalog)
        Initialize-CcodTrayNativeMenuV1
        $localized=Resolve-CcodTrayLocalizedStrings -Catalog $Catalog -LanguageMode en-US -SystemCultureName en-US
        $render=New-CcodTrayRenderState -Presentation $Presentation -Localized $localized -LanguageMode en-US -SystemCultureName en-US
        $spec=New-CcodTrayNativeMenuSpec -Render $render
        ConvertTo-CcodTrayNativeMenuItems $spec
    } $presentation $script:TestEnglishCatalog
    Assert-CcodEqual 'CcodTrayNativeMenuItemV1[]' $result.GetType().FullName 'conversion returns the versioned native item array'
    Assert-CcodEqual 11 $result.Length 'conversion retains every top-level item'
    Assert-CcodEqual '0,0,0,0,0,1003,1004,0,1008,0,1009' (($result|ForEach-Object {$_.CommandId})-join ',') 'conversion keeps exact top-level command ids'
    Assert-CcodEqual 'True,True,True' (($result[7].Children|ForEach-Object {[string]$_.Radio})-join ',') 'conversion retains language radio markers'
    Assert-CcodEqual 'False,False,True' (($result[7].Children|ForEach-Object {[string]$_.Checked})-join ',') 'conversion retains the active language state'
    Assert-CcodEqual $true $result[9].Separator 'conversion preserves separators'
}))

$results.Add((Invoke-CcodTest 'native item conversion rejects an unwhitelisted enabled command before the C# boundary' {
    $invalid=[pscustomobject][ordered]@{
        CommandId=[int]1010;Text='Unexpected command';Enabled=$true;Checked=$false;Radio=$false;Separator=$false;Children=[object[]]@()
    }
    Assert-CcodThrows {
        & (Get-Module TrayUi) {param($Items)ConvertTo-CcodTrayNativeMenuItems -Items $Items} @($invalid)
    } 'native menu command id is invalid'
}))

$results.Add((Invoke-CcodTest 'production adapters own a hidden HWND and expose blocking menu show cancel and MouseUp boundaries' {
    $production=& (Get-Module TrayUi) {Get-CcodTrayDefaultAdapters}
    foreach($name in @('CreateNativeMenuOwner','ShowNativeMenu','EndNativeMenu','DisposeNativeMenuOwner')){
        Assert-CcodTrue $production.ContainsKey($name) "production adapter exposes $name"
    }
    $owner=$null;$notify=$null;$attachment=$null
    try{
        $owner=& $production.CreateNativeMenuOwner
        Assert-CcodEqual 'CcodTrayNativeMenuOwnerV1' $owner.GetType().FullName 'owner crosses the versioned native HWND boundary'
        Assert-CcodTrue ($owner.WindowHandle -is [IntPtr] -and $owner.WindowHandle -ne [IntPtr]::Zero) 'owner has a live hidden HWND'
        $notify=& $production.CreateUiObject 'NotifyIcon' 'TrayNotifyIcon'
        $attachment=& $production.AttachUiCallback $notify 'MouseUp' {param($sender,$eventArgs)}
        Assert-CcodEqual 'MouseUp' $attachment.EventName 'NotifyIcon right-click boundary uses MouseUp'
    }finally{
        if($null -ne $attachment){& $production.DetachUiCallback $attachment}
        if($null -ne $notify){& $production.DisposeUiObject $notify}
        if($null -ne $owner){& $production.DisposeNativeMenuOwner $owner}
    }
}))

$results.Add((Invoke-CcodTest 'NotifyIcon left MouseUp is inert while right MouseUp shows one native menu and cancel queues nothing' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null;$openStates=[Collections.Generic.List[bool]]::new()
    try{
        $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
        Set-CcodTrayPresentation -Context $context -Presentation (New-CcodValidPresentation)
        Assert-CcodTrue (-not $context.NotifyIcon.Properties.Contains('ContextMenuStrip')) 'NotifyIcon never receives a ContextMenuStrip'
        Assert-CcodEqual 'MouseUp' (@($context.NotifyIcon.Events.Keys)-join ',') 'NotifyIcon registers only MouseUp'
        $fake.State.OnShowNativeMenu={$openStates.Add([bool]$context.MenuOpen)}.GetNewClosure()
        Assert-CcodEqual 0 @(& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Left'})).Count 'left MouseUp emits no output'
        Assert-CcodEqual 0 $fake.State.NativeMenuShowCount 'left MouseUp never displays a menu'
        Assert-CcodEqual 0 $queue.Count 'left MouseUp queues no command'
        $fake.State.NativeMenuResults.Enqueue(0)
        Assert-CcodEqual 0 @(& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})).Count 'right MouseUp emits no output'
        Assert-CcodEqual 1 $fake.State.NativeMenuShowCount 'right MouseUp displays exactly one native menu'
        Assert-CcodEqual 'True' (($openStates|ForEach-Object {[string]$_})-join ',') 'MenuOpen is true only while the native menu blocks'
        Assert-CcodEqual $false $context.MenuOpen 'native cancellation clears MenuOpen'
        Assert-CcodEqual 0 $queue.Count 'native command id zero queues nothing'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'right-click passes the entire native menu snapshot as the second adapter argument without argument flattening' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        Set-CcodTrayPresentation -Context $context -Presentation (New-CcodValidPresentation)
        $fake.State.NativeMenuResults.Enqueue(0)
        & $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})
        $items=$fake.State.NativeMenuSpecs[0]
        Assert-CcodEqual 11 @($items).Count 'ShowNativeMenu receives every top-level item as one Items argument'
        Assert-CcodEqual 3 @($items[7].Children).Count 'ShowNativeMenu receives the complete language submenu'
        Assert-CcodEqual '1005,1006,1007' (($items[7].Children|ForEach-Object {$_.CommandId})-join ',') 'nested command ids survive the adapter boundary'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'native command ids 1001 through 1009 map exactly to queue-only commands without optimistic truth changes' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation
        $presentation.SessionReadyVisible=$false;$presentation.ApplyNowVisible=$true;$presentation.ApplyNowEnabled=$true
        $presentation.ManualRetryVisible=$true;$presentation.ManualRetryEnabled=$true
        Set-CcodTrayPresentation -Context $context -Presentation $presentation
        foreach($id in 1001..1009){$fake.State.NativeMenuResults.Enqueue([int]$id)}
        foreach($id in 1001..1009){& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})}
        Assert-CcodEqual 9 $fake.State.NativeMenuShowCount 'each right MouseUp invokes one native menu'
        Assert-CcodEqual 9 $queue.Count 'each known enabled native id queues exactly once'
        $expected=@(
            @('ApplyNow',$null),@('ManualRetry',$null),@('SetAutomationEnabled',$false),@('SetCandidateCompatibleOptIn',$true),
            @('SetUiLanguage','System'),@('SetUiLanguage','zh-CN'),@('SetUiLanguage','en-US'),@('OpenLogs',$null),@('Uninstall',$null)
        )
        foreach($entry in $expected){
            $command=$queue.Dequeue()
            Assert-CcodEqual 'Kind,Value,EnqueuedAtUtc' (@($command.PSObject.Properties.Name)-join ',') 'native command queue shape is exact'
            Assert-CcodEqual $entry[0] $command.Kind 'native command kind maps by exact id'
            Assert-CcodEqual $entry[1] $command.Value 'native command value maps by exact id'
            Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $command.EnqueuedAtUtc 'native command timestamp is canonical UTC'
        }
        Assert-CcodEqual $true $context.CommandValues.AutomationChecked 'automation truth remains the last validated value'
        Assert-CcodEqual $false $context.CommandValues.CandidateOptInChecked 'candidate truth remains the last validated value'
        Assert-CcodEqual 'en-US' $context.CommandValues.LanguageMode 'language truth remains the last validated value'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'native command selection ignores disabled and unknown ids from the adapter boundary' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation;$presentation.ApplyNowVisible=$true;$presentation.ApplyNowEnabled=$false
        Set-CcodTrayPresentation -Context $context -Presentation $presentation
        foreach($id in @(1001,9999,1008)){$fake.State.NativeMenuResults.Enqueue([int]$id);& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})}
        Assert-CcodEqual 1 $queue.Count 'only the enabled id from the shown snapshot enters the queue'
        Assert-CcodEqual 'OpenLogs' $queue.Dequeue().Kind 'enabled id retains its exact mapping'
        Assert-CcodEqual $false $context.CallbackFailure 'disabled and unknown adapter results are contained as no-ops'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'blocking native menu keeps lightweight ticks and flushes only the latest pending render after return' {
    $fake=New-CcodTrayFakeAdapters;$context=$null;$modes=[Collections.Generic.List[bool]]::new();$during=[pscustomobject]@{Icon=$null;Pending=$null}
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick ({param($menuOpenOnly)$modes.Add([bool]$menuOpenOnly)}.GetNewClosure()) -Adapters $fake.Adapters
        Set-CcodTrayPresentation -Context $context -Presentation (New-CcodValidPresentation)
        $fake.State.OnShowNativeMenu={
            & $context.Timer.Events.Tick $context.Timer $null
            $pending=New-CcodValidPresentation;$pending.Color='Red';$pending.StateKey='Error'
            Set-CcodTrayPresentation -Context $context -Presentation $pending
            $during.Icon=$context.NotifyIcon.Properties.Icon.Color;$during.Pending=$context.PendingRender.Presentation.StateKey
        }.GetNewClosure()
        $fake.State.NativeMenuResults.Enqueue(0)
        & $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})
        Assert-CcodEqual 'True' (($modes|ForEach-Object {[string]$_})-join ',') 'nested timer requests only the lightweight supervisor tick'
        Assert-CcodEqual 'Green' $during.Icon 'open native menu receives no icon mutation'
        Assert-CcodEqual 'Error' $during.Pending 'latest render is pending while the menu blocks'
        Assert-CcodEqual $false $context.MenuOpen 'native menu return clears MenuOpen'
        Assert-CcodEqual $null $context.PendingRender 'native menu return consumes the pending render'
        Assert-CcodEqual 'Red' $context.NotifyIcon.Properties.Icon.Color 'latest pending render applies after native menu return'
        & $context.Timer.Events.Tick $context.Timer $null
        Assert-CcodEqual 'True,False' (($modes|ForEach-Object {[string]$_})-join ',') 'next timer returns to normal supervisor work'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'close during native tracking calls EndMenu and disposes the owner exactly once without queuing the returned id' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
    Set-CcodTrayPresentation -Context $context -Presentation (New-CcodValidPresentation)
    $fake.State.OnShowNativeMenu={Close-CcodTrayContext -Context $context|Out-Null}.GetNewClosure()
    $fake.State.NativeMenuResults.Enqueue(1008)
    & $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})
    Assert-CcodEqual 'Closed' $context.State 'reentrant shutdown reaches the terminal state'
    Assert-CcodEqual $false $context.MenuOpen 'reentrant shutdown clears MenuOpen'
    Assert-CcodEqual 1 $fake.State.NativeMenuEndCount 'shutdown cancels the active native menu exactly once'
    Assert-CcodEqual 1 $fake.State.NativeOwnerDisposeCount 'shutdown disposes the hidden owner exactly once'
    Assert-CcodEqual 0 $queue.Count 'a command id returned after shutdown is ignored'
    Close-CcodTrayContext -Context $context|Out-Null
    Assert-CcodEqual 1 $fake.State.NativeMenuEndCount 'idempotent close does not cancel twice'
    Assert-CcodEqual 1 $fake.State.NativeOwnerDisposeCount 'idempotent close does not dispose the owner twice'
}))

$results.Add((Invoke-CcodTest 'native timer releases QueueGate before invoking the supervisor callback' {
    $text=Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
    $match=[regex]::Match($text,'(?ms)\$tick=\{.*?\$validTickAttachment=')
    Assert-CcodTrue $match.Success 'production timer callback source is present'
    $tickSource=$match.Value
    $exitIndex=$tickSource.IndexOf('Monitor]::Exit($contextRef.QueueGate)')
    $onTickIndex=$tickSource.IndexOf('$invokeAdapterRef $onTick')
    Assert-CcodTrue ($exitIndex -ge 0 -and $onTickIndex -gt $exitIndex) 'heavy supervisor work is invoked only after the tray gate is released'
}))

$results.Add((Invoke-CcodTest 'confirms localized uninstall with native warning defaults and queues only the accepted click with no callback output' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    $confirm=[pscustomobject]@{Results=[Collections.Generic.Queue[bool]]::new();Calls=[Collections.Generic.List[object]]::new()}
    $confirm.Results.Enqueue($false);$confirm.Results.Enqueue($true)
    $fake.Adapters.ConfirmUninstall={
        param($Title,$Message)
        $confirm.Calls.Add([pscustomobject][ordered]@{Title=$Title;Message=$Message})
        [bool]$confirm.Results.Dequeue()
    }.GetNewClosure()
    try{
        $context=TrayUi\New-CcodTrayContext -CommandQueue $queue -OnTick {} -Catalog $script:TestEnglishCatalog -LanguageMode en-US -SystemCultureName en-US -Adapters $fake.Adapters
        TrayUi\Set-CcodTrayPresentation -Context $context -Presentation (New-CcodValidPresentation) -Catalog $script:TestEnglishCatalog -LanguageMode en-US -SystemCultureName en-US
        $fake.State.NativeMenuResults.Enqueue(1009)
        Assert-CcodEqual 0 @(& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})).Count 'cancel callback emits no output'
        Assert-CcodEqual 0 $queue.Count 'cancel queues nothing'
        $fake.State.NativeMenuResults.Enqueue(1009)
        Assert-CcodEqual 0 @(& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})).Count 'confirmed callback emits no output'
        Assert-CcodEqual 1 $queue.Count 'confirmation queues exactly once'
        Assert-CcodEqual 2 $confirm.Calls.Count 'both clicks ask for confirmation once'
        foreach($call in $confirm.Calls){
            Assert-CcodEqual 'Uninstall Codex connection supervisor?' $call.Title 'localized confirmation title is exact'
            Assert-CcodEqual 'This stops the supervisor. A managed Codex session will restart normally. Device keys are kept by default.' $call.Message 'localized confirmation message is exact'
        }
        $command=$queue.Dequeue()
        Assert-CcodEqual 'Kind,Value,EnqueuedAtUtc' (($command.PSObject.Properties.Name)-join ',') 'confirmed command shape is exact and ordered'
        Assert-CcodEqual 'Uninstall' $command.Kind 'confirmed command kind'
        Assert-CcodEqual $null $command.Value 'confirmed command has no value'
        Assert-CcodEqual '2030-02-03T04:05:06.0000000Z' $command.EnqueuedAtUtc 'confirmed command timestamp is canonical UTC'

        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $native=[pscustomobject]@{Calls=[Collections.Generic.List[object]]::new()}
        $show={
            param($Message,$Title,$Buttons,$Icon,$DefaultButton)
            $native.Calls.Add([pscustomobject][ordered]@{Message=$Message;Title=$Title;Buttons=$Buttons;Icon=$Icon;DefaultButton=$DefaultButton})
            [Windows.Forms.DialogResult]::Yes
        }.GetNewClosure()
        $accepted=& (Get-Module TrayUi) {param($Show)Invoke-CcodTrayUninstallConfirmation -Title 'title' -Message 'message' -ShowDialog $Show} $show
        Assert-CcodEqual $true $accepted 'native Yes result confirms'
        Assert-CcodEqual 1 $native.Calls.Count 'native dialog is invoked once'
        Assert-CcodEqual 'message,title,YesNo,Warning,Button2' "$($native.Calls[0].Message),$($native.Calls[0].Title),$($native.Calls[0].Buttons),$($native.Calls[0].Icon),$($native.Calls[0].DefaultButton)" 'native dialog is YesNo Warning default No'
    }finally{if($null -ne $context){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'shows a bilingual native snapshot from the current render without retaining ContextMenuStrip controls' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    try{
        $context=TrayUi\New-CcodTrayContext -CommandQueue $queue -OnTick {} -Catalog $script:TestSystemCatalog -LanguageMode System -SystemCultureName zh-CN -Adapters $fake.Adapters
        $active=New-CcodValidPresentation
        Assert-CcodEqual 0 @(TrayUi\Set-CcodTrayPresentation -Context $context -Presentation $active -Catalog $script:TestSystemCatalog -LanguageMode System -SystemCultureName zh-CN).Count 'localized semantic render emits no output'
        Assert-CcodTrue ($null -eq $context.PSObject.Properties['Menu'] -and $null -eq $context.PSObject.Properties['Rows'] -and $null -eq $context.PSObject.Properties['Items']) 'context retains no permanent ContextMenuStrip graph'
        $fake.State.NativeMenuResults.Enqueue(0)
        & $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})
        $snapshot=$fake.State.NativeMenuSpecs[0]
        $zhTitle='Codex '+[string]::Concat([char[]]@(0x8bbe,0x5907,0x8fde,0x63a5))
        $zhStatus=[string]::Concat([char[]]@(0x5f53,0x524d,0x4f1a,0x8bdd,0x5df2,0x542f,0x7528,0x201c,0x8fde,0x63a5,0x5176,0x4ed6,0x8bbe,0x5907,0x201d))
        Assert-CcodEqual $zhTitle $snapshot[0].Text 'title resolves from the Chinese catalog at show time'
        Assert-CcodEqual $zhStatus $snapshot[1].Text 'status resolves from the semantic state at show time'
        Assert-CcodEqual ([string]::Concat([char[]]@(0x8bed,0x8a00))+' / Language') $snapshot[7].Text 'language root stays bilingual'
        Assert-CcodEqual 'True,False,False' (($snapshot[7].Children|ForEach-Object {[string]$_.Checked})-join ',') 'System alone is radio-checked'
        Assert-CcodEqual $false $snapshot[3].Enabled 'active session row remains display-only through disabled state'
        Assert-CcodEqual $false $snapshot[3].Checked 'active session row is not a toggle'
    }finally{if($null -ne $context){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'live language switching updates the next native menu snapshot without rebuilding the tray owner or icons' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=TrayUi\New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Catalog $script:TestSystemCatalog -LanguageMode System -SystemCultureName zh-CN -Adapters $fake.Adapters
        $active=New-CcodValidPresentation
        TrayUi\Set-CcodTrayPresentation -Context $context -Presentation $active -Catalog $script:TestSystemCatalog -LanguageMode System -SystemCultureName zh-CN
        $notify=$context.NotifyIcon;$owner=$context.NativeMenuOwner;$icons=$context.Icons;$createCount=@($fake.State.Calls|Where-Object {$_ -like 'Create:*'}).Count
        $resourceCount=@($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Clone:*'}).Count
        Assert-CcodEqual 0 @(TrayUi\Set-CcodTrayPresentation -Context $context -Presentation $active -Catalog $script:TestEnglishCatalog -LanguageMode en-US -SystemCultureName zh-CN).Count 'live language switch emits no output'
        Assert-CcodEqual 'Codex device connection: working' $context.NotifyIcon.Properties.Text 'tooltip switches immediately'
        $fake.State.NativeMenuResults.Enqueue(0)
        & $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})
        $snapshot=$fake.State.NativeMenuSpecs[0]
        Assert-CcodEqual 'Codex Device Connection' $snapshot[0].Text 'next snapshot uses English title'
        Assert-CcodEqual ([char]0x201c+'Control other devices'+[char]0x201d+' is active for this session') $snapshot[1].Text 'next snapshot uses English status'
        Assert-CcodEqual 'False,False,True' (($snapshot[7].Children|ForEach-Object {[string]$_.Checked})-join ',') 'en-US alone is checked after switch'
        Assert-CcodTrue ([object]::ReferenceEquals($notify,$context.NotifyIcon) -and [object]::ReferenceEquals($owner,$context.NativeMenuOwner) -and [object]::ReferenceEquals($icons,$context.Icons)) 'live switch preserves every retained tray identity'
        Assert-CcodEqual $createCount @($fake.State.Calls|Where-Object {$_ -like 'Create:*'}).Count 'live switch creates no UI object'
        Assert-CcodEqual $resourceCount @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Clone:*'}).Count 'live switch allocates no owned icon resource'
    }finally{if($null -ne $context){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'shows only allow-listed localized native tray errors on the owner thread with no output' {
    $fake=New-CcodTrayFakeAdapters;$context=TrayUi\New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Catalog $script:TestChineseCatalog -LanguageMode zh-CN -SystemCultureName en-US -Adapters $fake.Adapters
    try{
        Assert-CcodEqual 0 @(Show-CcodTrayError -Context $context -Catalog $script:TestChineseCatalog -Key Error.LanguageChange).Count 'error dialog emits no output'
        Assert-CcodEqual 1 $fake.State.Dialogs.Count 'one dialog is shown'
        Assert-CcodEqual ('Codex '+[string]::Concat([char[]]@(0x8bbe,0x5907,0x8fde,0x63a5))) $fake.State.Dialogs[0].Title 'dialog title is localized'
        Assert-CcodEqual ([string]::Concat([char[]]@(0x65e0,0x6cd5,0x5207,0x6362,0x8bed,0x8a00,0xff1b,0x5df2,0x4fdd,0x7559,0x539f,0x8bed,0x8a00,0x3002))) $fake.State.Dialogs[0].Message 'dialog message is localized and non-sensitive'
        Assert-CcodThrows {Show-CcodTrayError -Context $context -Catalog $script:TestChineseCatalog -Key Tray.Title} 'CCOD_TRAY_INPUT_INVALID'
        $fake.State.ThreadId=38
        Assert-CcodThrows {Show-CcodTrayError -Context $context -Catalog $script:TestChineseCatalog -Key Error.UninstallStart} 'CCOD_TRAY_THREAD_INVALID'
    }finally{$fake.State.ThreadId=37;Close-CcodTrayContext -Context $context|Out-Null}
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

$results.Add((Invoke-CcodTest 'constructs the minimal native tray graph and closes the hidden owner and every retained resource exactly once' {
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
    Assert-CcodEqual 1 $fake.State.NativeOwners.Count 'one hidden native menu owner'
    Assert-CcodEqual 'NativeMenuOwner' $context.NativeMenuOwner.Kind 'native owner crosses the explicit adapter boundary'
    Assert-CcodEqual 0 @($fake.State.Objects|Where-Object {$_.Kind -in @('Menu','Row','MenuItem','Separator')}).Count 'no permanent ContextMenuStrip controls are allocated'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*'}).Count 'eight cached bitmap sizes and colors'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'Draw:*'}).Count 'eight cached bitmaps are drawn once'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'Clone:*'}).Count 'eight cached icon clones are created'
    Assert-CcodEqual 8 @($fake.State.Calls|Where-Object {$_ -like 'DestroyIcon:*'}).Count 'every temporary HICON is destroyed immediately'
    Assert-CcodEqual 0 $fake.State.TitleBitmaps.Count 'native menu needs no retained title bitmap'
    Assert-CcodEqual 0 $fake.State.BoldFonts.Count 'native menu needs no retained title font'
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
    $visibleIndex=$fake.State.Calls.IndexOf('Visible:TrayNotifyIcon:True')
    $ownerIndex=$fake.State.Calls.IndexOf('NativeOwner:Create')
    Assert-CcodTrue ($ownerIndex -ge 0 -and $visibleIndex -gt $ownerIndex) 'hidden owner creation completes before the icon becomes visible'
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
    Assert-CcodEqual 1 $context.NotifyIcon.DisposeCount 'NotifyIcon is disposed exactly once'
    Assert-CcodEqual 1 $fake.State.NativeOwnerDisposeCount 'hidden native menu owner is disposed exactly once'
    Assert-CcodEqual $true $context.NativeMenuOwner.Disposed 'hidden native owner records deterministic disposal'
    Assert-CcodEqual 0 @($fake.State.Objects|Where-Object {$_.DisposeCount -gt 1}).Count 'retained WinForms objects are never disposed twice'
    $hideIndex=$fake.State.Calls.IndexOf('Visible:TrayNotifyIcon:False')
    $notifyDisposeIndex=$fake.State.Calls.IndexOf('DisposeUi:TrayNotifyIcon')
    $ownerDisposeIndex=$fake.State.Calls.IndexOf('NativeOwner:Dispose')
    $contextDisposeIndex=$fake.State.Calls.IndexOf('DisposeUi:TrayApplicationContext')
    $lastDetachIndex=-1
    for($index=0;$index -lt $fake.State.Calls.Count;$index++){if($fake.State.Calls[$index] -like 'Detach:*'){$lastDetachIndex=$index}}
    Assert-CcodTrue ($hideIndex -ge 0 -and $lastDetachIndex -gt $hideIndex -and $notifyDisposeIndex -gt $lastDetachIndex -and $ownerDisposeIndex -gt $notifyDisposeIndex -and $contextDisposeIndex -gt $ownerDisposeIndex) 'close hides, detaches, disposes NotifyIcon, hidden owner, then application context in order'
    $callCount=$fake.State.Calls.Count
    $second=Close-CcodTrayContext -Context $context
    Assert-CcodEqual $true $second.Closed 'second close is a success no-op'
    Assert-CcodEqual $callCount $fake.State.Calls.Count 'idempotent close runs no adapters twice'
}))

$results.Add((Invoke-CcodTest 'renders notification state without allocation and keeps native command dispatch bounded and inert after close' {
    $fake=New-CcodTrayFakeAdapters;$queue=New-CcodTrayTestQueue;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue $queue -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation
        $iconResourceCalls=@($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count
        $output=@(Set-CcodTrayPresentation -Context $context -Presentation $presentation)
        Assert-CcodEqual 0 $output.Count 'presentation emits no output'
        Assert-CcodEqual 'Codex device connection: working' $context.NotifyIcon.Properties.Text 'tooltip resolves from the semantic state key'
        Assert-CcodEqual 'Green' $context.NotifyIcon.Properties.Icon.Color 'cached green icon selected'
        Assert-CcodEqual 'Active' $context.CurrentRender.Presentation.StateKey 'current native menu snapshot records the semantic presentation'
        Assert-CcodEqual $true $context.CommandValues.AutomationChecked 'verified automation state is retained for selected commands'
        Assert-CcodEqual $false $context.CommandValues.CandidateOptInChecked 'verified candidate state is retained for selected commands'
        Assert-CcodEqual $iconResourceCalls @($fake.State.Calls|Where-Object {$_ -like 'Bitmap:*' -or $_ -like 'Draw:*' -or $_ -like 'GetHicon:*' -or $_ -like 'Clone:*' -or $_ -like 'DestroyIcon:*' -or $_ -like 'DisposeIcon:*'}).Count 'presentation allocates or disposes no icon resources'

        $fake.State.NativeMenuResults.Enqueue(1008)
        $callbackOutput=@(& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'}))
        Assert-CcodEqual 0 $callbackOutput.Count 'native command callback emits no output'
        Assert-CcodEqual 'OpenLogs' $queue.Dequeue().Kind 'enabled snapshot command queues its exact kind'
        foreach($n in 1..256){$queue.Enqueue([pscustomobject]@{N=$n})}
        $fake.State.NativeMenuResults.Enqueue(1008)
        @(& $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'}))|Out-Null
        Assert-CcodEqual 256 $queue.Count 'command queue never exceeds 256'
        Assert-CcodEqual $true $context.CommandOverflowed 'command overflow sets sticky flag'
        $closedCallback=$context.NotifyIcon.Events.MouseUp
        [void](Close-CcodTrayContext -Context $context)
        $clockCalls=@($fake.State.Calls|Where-Object {$_ -ceq 'Clock:GetUtcNow'}).Count
        $closedOutput=@(& $closedCallback $context.NotifyIcon ([pscustomobject]@{Button='Right'}))
        Assert-CcodEqual 0 $closedOutput.Count 'closed callback is a no-output no-op'
        Assert-CcodEqual $clockCalls @($fake.State.Calls|Where-Object {$_ -ceq 'Clock:GetUtcNow'}).Count 'closed callback invokes no clock or queue adapter'
    }finally{if($null -ne $context -and $context.State -cne 'Closed'){Close-CcodTrayContext -Context $context|Out-Null}}
}))

$results.Add((Invoke-CcodTest 'renders the optional External renderer handoff warning while keeping the active tooltip' {
    $fake=New-CcodTrayFakeAdapters;$context=$null
    try{
        $context=New-CcodTrayContext -CommandQueue (New-CcodTrayTestQueue) -OnTick {} -Adapters $fake.Adapters
        $presentation=New-CcodValidPresentation
        $presentation.Color='Yellow'
        $presentation.StateKey='RendererHandoff'
        Set-CcodTrayPresentation -Context $context -Presentation $presentation -Catalog $script:TestEnglishCatalog -LanguageMode en-US -SystemCultureName en-US
        Assert-CcodEqual 'Codex device connection: working' $context.NotifyIcon.Properties.Text 'External renderer warning keeps the active tooltip'
        Assert-CcodEqual 'Yellow' $context.NotifyIcon.Properties.Icon.Color 'External renderer warning uses the yellow icon'
        $fake.State.NativeMenuResults.Enqueue(0)
        & $context.NotifyIcon.Events.MouseUp $context.NotifyIcon ([pscustomobject]@{Button='Right'})
        Assert-CcodEqual 'External renderer handoff was not completed; Codex remains active' $fake.State.NativeMenuSpecs[0][1].Text 'warning text is carried by the next native snapshot'
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
        $badState=New-CcodValidPresentation;$badState.StateKey='active'
        $badVisible=New-CcodValidPresentation;$badVisible.SessionReadyVisible='true'
        foreach($case in @(
            {Set-CcodTrayPresentation -Context $context -Presentation $extra},
            {Set-CcodTrayPresentation -Context $context -Presentation $badState},
            {Set-CcodTrayPresentation -Context $context -Presentation $badVisible}
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
    $cleanup=[pscustomobject]@{Hide=0;NativeEnd=0;Stop=0;Ui=0;Icon=0;Detach=0;NativeOwner=0;Exit=0}
    $context.Adapters.SetUiVisible={param($Object,$Visible)$cleanup.Hide++;throw 'SECRET_HIDE'}.GetNewClosure()
    $context.MenuOpen=$true
    $context.Adapters.EndNativeMenu={$cleanup.NativeEnd++;throw 'SECRET_NATIVE_END'}.GetNewClosure()
    $context.Adapters.StopUiTimer={param($Timer)$cleanup.Stop++;throw 'SECRET_STOP'}.GetNewClosure()
    $context.Adapters.DisposeUiObject={param($Object)$cleanup.Ui++;throw 'SECRET_UI'}.GetNewClosure()
    $context.Adapters.DisposeIconResource={param($Object)$cleanup.Icon++;throw 'SECRET_ICON'}.GetNewClosure()
    $context.Adapters.DetachUiCallback={param($Receipt)$cleanup.Detach++;throw 'SECRET_DETACH'}.GetNewClosure()
    $context.Adapters.DisposeNativeMenuOwner={param($Owner)$cleanup.NativeOwner++;throw 'SECRET_NATIVE_OWNER'}.GetNewClosure()
    $context.Adapters.ExitUiContext={param($Object)$cleanup.Exit++;throw 'SECRET_EXIT'}.GetNewClosure()
    $receipt=Close-CcodTrayContext -Context $context
    $expected='CCOD_TRAY_CLEANUP_ICON_HIDE_FAILED,CCOD_TRAY_CLEANUP_NATIVE_MENU_END_FAILED,CCOD_TRAY_CLEANUP_TIMER_STOP_FAILED,CCOD_TRAY_CLEANUP_TIMER_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_CALLBACK_DETACH_FAILED,CCOD_TRAY_CLEANUP_ICON_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_NATIVE_MENU_OWNER_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_ICON_CLONE_DISPOSE_FAILED,CCOD_TRAY_CLEANUP_CONTEXT_EXIT_FAILED,CCOD_TRAY_CLEANUP_CONTEXT_DISPOSE_FAILED'
    Assert-CcodEqual $expected (@($receipt.CleanupCodes)-join ',') 'tray cleanup codes are ordered deduplicated and allowlisted'
    Assert-CcodTrue ($cleanup.Hide -ge 1 -and $cleanup.NativeEnd -eq 1 -and $cleanup.Stop -eq 1 -and $cleanup.Ui -eq 3 -and $cleanup.Icon -eq 8 -and $cleanup.Detach -eq 2 -and $cleanup.NativeOwner -eq 1 -and $cleanup.Exit -eq 1) 'all native tray cleanup stages continue despite a native menu cancellation failure'
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

$results.Add((Invoke-CcodTest 'recovers every retained Win32 owner UI bitmap HICON clone and attachment emitted before a diagnostic failure' {
    foreach($stage in @('CreateUiObject','CreateNativeMenuOwner','CreateBitmap','GetHicon','CloneIcon','AttachUiCallback')){
        $fake=New-CcodTrayFakeAdapters;$original=$fake.Adapters[$stage]
        switch($stage){
            'CreateUiObject' {$fake.Adapters[$stage]={param($Kind,$Name)$value=& $original $Kind $Name;$value;Write-Warning 'SECRET_AFTER_UI'}.GetNewClosure()}
            'CreateNativeMenuOwner' {$fake.Adapters[$stage]={$value=& $original;$value;Write-Warning 'SECRET_AFTER_NATIVE_OWNER'}.GetNewClosure()}
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
        if($stage -ceq 'CreateNativeMenuOwner'){Assert-CcodEqual 1 $fake.State.NativeOwnerDisposeCount 'diagnostic hidden owner is disposed immediately'}
        if($stage -ceq 'AttachUiCallback'){Assert-CcodEqual 1 @($fake.State.Calls|Where-Object {$_ -like 'Detach:TrayNotifyIcon:MouseUp'}).Count 'diagnostic MouseUp attachment is detached immediately'}
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
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$tokens,[ref]$parseErrors)
    Assert-CcodEqual 0 @($parseErrors).Count 'TrayUi module parses cleanly'
    $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$_})
    foreach($forbidden in @('Start-Process','Stop-Process','Get-AppxPackage','Set-ItemProperty','New-ItemProperty','schtasks.exe','node.exe','git.exe')){
        Assert-CcodEqual 0 @($commands|Where-Object {$_ -ceq $forbidden}).Count "$forbidden is absent from Task10C2 AST"
    }
    $text=Get-Content -LiteralPath $modulePath -Raw
    Assert-CcodTrue ($text.Contains('Register-WmiEvent -Class $ClassName')) 'production Trace default remains lazy source text only'
    foreach($forbiddenText in @('PresentationFramework','PresentationCore','WindowsBase','WindowsFormsIntegration','Windows.Window','PostUiCallback','Dispatcher','Topmost','NativeFallback')){
        Assert-CcodTrue (-not $text.Contains($forbiddenText)) "$forbiddenText is absent from the native tray implementation"
    }
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

$results += Invoke-CcodTest 'accepts the External renderer handoff status key from the validated UI catalog' {
    $localized=& (Get-Module TrayUi) {param($Catalog)Resolve-CcodTrayLocalizedStrings -Catalog $Catalog -LanguageMode en-US -SystemCultureName en-US} $script:TestEnglishCatalog
    Assert-CcodEqual 'External renderer handoff was not completed; Codex remains active' $localized['Status.RendererHandoff'] 'tray resolves the validated optional handoff status key'
}

$results|ForEach-Object{"PASS $($_.Name)"}
