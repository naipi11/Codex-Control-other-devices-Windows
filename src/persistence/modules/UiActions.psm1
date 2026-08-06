Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'RuntimeManifest.psm1') -ErrorAction Stop

$script:CcodUiActionAdapterNames=@('ReadActiveRuntime','ValidateRuntimeManifest','GetItem','StartProcess')
$script:CcodUiActionRuntimeErrors=@(
    'CCOD_RUNTIME_MISSING','CCOD_RUNTIME_MANIFEST_MISSING','CCOD_RUNTIME_MANIFEST_INVALID','CCOD_RUNTIME_ID_MISMATCH',
    'CCOD_RUNTIME_FILE_SET_MISMATCH','CCOD_RUNTIME_FILE_LENGTH_MISMATCH','CCOD_RUNTIME_FILE_HASH_MISMATCH',
    'CCOD_PATH_OUTSIDE_ROOT','CCOD_PATH_MISSING','CCOD_REPARSE_PATH'
)

function Throw-CcodUiActionError {
    param([Parameter(Mandatory)][string]$Id,[Parameter(Mandatory)][string]$Message)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Id,[Management.Automation.ErrorCategory]::InvalidData,$null
    )
}

function Test-CcodUiActionExactProperties {
    param($Value,[string[]]$Names)
    try{
        if($null -eq $Value -or $Value -isnot [pscustomobject]){return $false}
        $actual=@($Value.PSObject.Properties.Name)
        if($actual.Count -ne $Names.Count){return $false}
        for($index=0;$index -lt $Names.Count;$index++){
            if($actual[$index] -cne $Names[$index] -or $Value.PSObject.Properties[$actual[$index]].MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty){return $false}
        }
        return $true
    }catch{return $false}
}

function Test-CcodUiActionDiagnosticRecord {
    param($Value)
    return $Value -is [Management.Automation.ErrorRecord] -or $Value -is [Management.Automation.WarningRecord] -or
        $Value -is [Management.Automation.VerboseRecord] -or $Value -is [Management.Automation.DebugRecord] -or
        $Value -is [Management.Automation.InformationRecord]
}

function Invoke-CcodUiActionAdapterCapture {
    param([scriptblock]$Callback,[object[]]$Arguments)
    if($Callback -isnot [scriptblock]){return [pscustomobject]@{Threw=$true;ErrorId=$null;Items=@()}}
    $items=[Collections.Generic.List[object]]::new();$threw=$false;$errorId=$null
    try{
        & $Callback @Arguments *>&1|ForEach-Object{
            if($items.Count -ge 16){throw 'adapter output limit exceeded'}
            $items.Add($_)
        }
    }catch{$threw=$true;$errorId=([string]$_.FullyQualifiedErrorId -split ',')[0]}
    return [pscustomobject]@{Threw=[bool]$threw;ErrorId=$errorId;Items=@($items)}
}

function Invoke-CcodUiActionAdapter {
    param([scriptblock]$Callback,[object[]]$Arguments,[string]$FailureId,[string[]]$AllowedErrorIds=@())
    $capture=Invoke-CcodUiActionAdapterCapture $Callback $Arguments
    if($capture.Threw){
        $stableId=if($capture.ErrorId -is [string] -and $AllowedErrorIds -ccontains $capture.ErrorId){$capture.ErrorId}else{$FailureId}
        Throw-CcodUiActionError $stableId 'The tray uninstall operation failed safely.'
    }
    foreach($item in $capture.Items){if(Test-CcodUiActionDiagnosticRecord $item){Throw-CcodUiActionError $FailureId 'The tray uninstall operation failed safely.'}}
    if($capture.Items.Count -ne 1){Throw-CcodUiActionError $FailureId 'The tray uninstall operation failed safely.'}
    Write-Output -NoEnumerate $capture.Items[0]
}

function ConvertTo-CcodUiActionArgument {
    param([Parameter(Mandatory)][string]$Argument)
    $quoted=[Text.StringBuilder]::new();[void]$quoted.Append('"');$backslashes=0
    foreach($character in $Argument.ToCharArray()){
        if($character -eq [char]'\'){$backslashes++;continue}
        if($character -eq [char]'"'){
            [void]$quoted.Append(('\'*(($backslashes*2)+1)));[void]$quoted.Append('"');$backslashes=0;continue
        }
        if($backslashes -gt 0){[void]$quoted.Append(('\'*$backslashes));$backslashes=0}
        [void]$quoted.Append($character)
    }
    if($backslashes -gt 0){[void]$quoted.Append(('\'*($backslashes*2)))}
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function New-CcodUiActionStartInfo {
    param([Parameter(Mandatory)][string]$FilePath,[Parameter(Mandatory)][string[]]$Arguments)
    $startInfo=[Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName=$FilePath
    $startInfo.Arguments=(($Arguments|ForEach-Object{ConvertTo-CcodUiActionArgument -Argument $_})-join ' ')
    $startInfo.UseShellExecute=$false
    $startInfo.CreateNoWindow=$true
    $startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    return $startInfo
}

function Start-CcodUiActionProcess {
    param([Parameter(Mandatory)][string]$FilePath,[Parameter(Mandatory)][string[]]$Arguments)
    $process=$null
    try{
        $startInfo=New-CcodUiActionStartInfo -FilePath $FilePath -Arguments $Arguments
        $process=[Diagnostics.Process]::Start($startInfo)
        if($null -eq $process){throw [InvalidOperationException]::new('The process returned no handle.')}
        [pscustomobject][ordered]@{
            Pid=[int]$process.Id
            CreationTimeUtc=$process.StartTime.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        }
    }finally{
        if($null -ne $process){$process.Dispose()}
    }
}

function Get-CcodUiActionAdapters {
    param([hashtable]$Adapters)
    $resolved=@{
        ReadActiveRuntime={param($InstallRoot)Read-CcodActiveRuntime -InstallRoot $InstallRoot}
        ValidateRuntimeManifest={param($RuntimeRoot,$ExpectedRuntimeId)Test-CcodRuntimeManifest -RuntimeDirectory $RuntimeRoot -ExpectedRuntimeId $ExpectedRuntimeId}
        GetItem={param($Path)Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force -ErrorAction Stop}
        StartProcess={param($FilePath,[string[]]$Arguments)Start-CcodUiActionProcess -FilePath $FilePath -Arguments $Arguments}
    }
    if($null -ne $Adapters){
        foreach($name in @($Adapters.Keys)){
            if($name -isnot [string] -or $script:CcodUiActionAdapterNames -cnotcontains $name -or $Adapters[$name] -isnot [scriptblock]){
                Throw-CcodUiActionError 'CCOD_UNINSTALL_ADAPTER_INVALID' 'The tray uninstall adapter set is invalid.'
            }
            $resolved[$name]=$Adapters[$name]
        }
    }
    return $resolved
}

function Get-CcodUiActionFullPath {
    param([string]$Path,[string]$FailureId)
    if([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)){Throw-CcodUiActionError $FailureId 'The tray uninstall path is invalid.'}
    try{return [IO.Path]::GetFullPath($Path)}catch{Throw-CcodUiActionError $FailureId 'The tray uninstall path is invalid.'}
}

function Get-CcodUiActionComparablePath {
    param([string]$Path,[string]$FailureId)
    $full=Get-CcodUiActionFullPath $Path $FailureId
    $root=[IO.Path]::GetPathRoot($full)
    while($full.Length -gt $root.Length -and ($full.EndsWith('\') -or $full.EndsWith('/'))){$full=$full.Substring(0,$full.Length-1)}
    return $full
}

function Test-CcodUiActionCanonicalUtc {
    param($Value)
    if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'){return $false}
    $parsed=[DateTime]::MinValue
    return [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -and
        $parsed.Kind -eq [DateTimeKind]::Utc -and $parsed.ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $Value
}

function Assert-CcodStartedProcessReceipt {
    param($Receipt)
    if(-not (Test-CcodUiActionExactProperties $Receipt @('Pid','CreationTimeUtc')) -or
       $Receipt.Pid -isnot [int] -or $Receipt.Pid -le 0 -or -not (Test-CcodUiActionCanonicalUtc $Receipt.CreationTimeUtc)){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_PROCESS_RECEIPT_INVALID' 'The uninstaller process receipt is invalid.'
    }
}

function Resolve-CcodVerifiedRuntimeUninstaller {
    param([string]$InstallRoot,[string]$RuntimeRoot,[hashtable]$Adapters)
    $installFull=Get-CcodUiActionComparablePath $InstallRoot 'CCOD_UNINSTALL_INPUT_INVALID'
    $runtimeFull=Get-CcodUiActionComparablePath $RuntimeRoot 'CCOD_UNINSTALL_INPUT_INVALID'

    $active=Invoke-CcodUiActionAdapter $Adapters.ReadActiveRuntime @($InstallRoot) 'CCOD_UNINSTALL_ACTIVE_RUNTIME_INVALID'
    if($null -eq $active -or $null -eq $active.PSObject.Properties['activeRuntime'] -or $active.activeRuntime -isnot [string] -or [string]::IsNullOrWhiteSpace($active.activeRuntime)){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_ACTIVE_RUNTIME_INVALID' 'The active runtime pointer is invalid.'
    }
    $pathAdapters=@{GetItem=$Adapters.GetItem}
    $relativeRuntime=Join-Path 'runtime' ([string]$active.activeRuntime)
    $expectedRuntime=Resolve-CcodContainedPath -Root $installFull -RelativePath $relativeRuntime -Adapters $pathAdapters
    $expectedComparable=Get-CcodUiActionComparablePath $expectedRuntime 'CCOD_UNINSTALL_RUNTIME_MISMATCH'
    if(-not $runtimeFull.Equals($expectedComparable,[StringComparison]::OrdinalIgnoreCase)){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_RUNTIME_MISMATCH' 'The requested runtime is not the active runtime.'
    }

    $validation=Invoke-CcodUiActionAdapter $Adapters.ValidateRuntimeManifest @($expectedRuntime,[string]$active.activeRuntime) 'CCOD_UNINSTALL_RUNTIME_INVALID' $script:CcodUiActionRuntimeErrors
    if(-not (Test-CcodUiActionExactProperties $validation @('Valid','Code','RuntimeId','Manifest')) -or $validation.Valid -isnot [bool] -or $validation.Code -isnot [string]){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The runtime manifest result is invalid.'
    }
    if(-not $validation.Valid){
        $code=if($script:CcodUiActionRuntimeErrors -ccontains $validation.Code){$validation.Code}else{'CCOD_UNINSTALL_RUNTIME_INVALID'}
        Throw-CcodUiActionError $code 'The active runtime did not pass manifest validation.'
    }
    if($validation.RuntimeId -isnot [string] -or $validation.RuntimeId -cne [string]$active.activeRuntime -or $null -eq $validation.Manifest -or
       $null -eq $validation.Manifest.PSObject.Properties['files']){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_RUNTIME_INVALID' 'The runtime manifest result is invalid.'
    }
    $matches=@($validation.Manifest.files|Where-Object{
        $null -ne $_ -and $null -ne $_.PSObject.Properties['path'] -and $_.path -is [string] -and $_.path -ceq 'Uninstall-CodexControlOtherDevices.ps1'
    })
    if($matches.Count -ne 1){Throw-CcodUiActionError 'CCOD_UNINSTALL_SCRIPT_UNHASHED' 'The runtime uninstaller is not manifest-bound.'}

    $scriptPath=Resolve-CcodContainedPath -Root $expectedRuntime -RelativePath 'Uninstall-CodexControlOtherDevices.ps1' -Adapters $pathAdapters
    $scriptItem=Invoke-CcodUiActionAdapter $Adapters.GetItem @($scriptPath) 'CCOD_UNINSTALL_SCRIPT_INVALID'
    if($null -eq $scriptItem.PSObject.Properties['Attributes'] -or $null -eq $scriptItem.PSObject.Properties['PSIsContainer'] -or
       $scriptItem.PSIsContainer -isnot [bool] -or $scriptItem.PSIsContainer -or
       (($scriptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
        if($null -ne $scriptItem.PSObject.Properties['Attributes'] -and (($scriptItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
            Throw-CcodUiActionError 'CCOD_REPARSE_PATH' 'The runtime uninstaller is a reparse point.'
        }
        Throw-CcodUiActionError 'CCOD_UNINSTALL_SCRIPT_INVALID' 'The runtime uninstaller is invalid.'
    }
    return $scriptPath
}

function Start-CcodTrayUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [hashtable]$Adapters
    )
    $resolved=Get-CcodUiActionAdapters $Adapters
    $powershellComparable=Get-CcodUiActionComparablePath $PowerShellPath 'CCOD_UNINSTALL_HOST_INVALID'
    if([string]::IsNullOrWhiteSpace($env:SystemRoot)){Throw-CcodUiActionError 'CCOD_UNINSTALL_HOST_INVALID' 'The Windows PowerShell host is invalid.'}
    $approvedHost=Get-CcodUiActionComparablePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') 'CCOD_UNINSTALL_HOST_INVALID'
    if(-not $powershellComparable.Equals($approvedHost,[StringComparison]::OrdinalIgnoreCase)){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_HOST_INVALID' 'The Windows PowerShell host is not approved.'
    }
    $hostItem=Invoke-CcodUiActionAdapter $resolved.GetItem @($approvedHost) 'CCOD_UNINSTALL_HOST_INVALID'
    if($null -eq $hostItem.PSObject.Properties['Attributes'] -or $null -eq $hostItem.PSObject.Properties['PSIsContainer'] -or
       $hostItem.PSIsContainer -isnot [bool] -or $hostItem.PSIsContainer -or (($hostItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){
        Throw-CcodUiActionError 'CCOD_UNINSTALL_HOST_INVALID' 'The Windows PowerShell host is invalid.'
    }

    $scriptPath=Resolve-CcodVerifiedRuntimeUninstaller -InstallRoot $InstallRoot -RuntimeRoot $RuntimeRoot -Adapters $resolved
    [string[]]$arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-InstallRoot',$InstallRoot,'-Confirm:$false')
    $startArguments=[object[]]::new(2);$startArguments[0]=$PowerShellPath;$startArguments[1]=$arguments
    $capture=Invoke-CcodUiActionAdapterCapture $resolved.StartProcess $startArguments
    if($capture.Threw){Throw-CcodUiActionError 'CCOD_UNINSTALL_START_FAILED' 'The verified uninstaller could not be started.'}
    foreach($item in $capture.Items){if(Test-CcodUiActionDiagnosticRecord $item){Throw-CcodUiActionError 'CCOD_UNINSTALL_START_FAILED' 'The verified uninstaller could not be started.'}}
    if($capture.Items.Count -ne 1){Throw-CcodUiActionError 'CCOD_UNINSTALL_PROCESS_RECEIPT_INVALID' 'The uninstaller process receipt is invalid.'}
    $started=$capture.Items[0]
    Assert-CcodStartedProcessReceipt $started
    [pscustomobject][ordered]@{Started=$true;Pid=[int]$started.Pid;CreationTimeUtc=[string]$started.CreationTimeUtc}
}

Export-ModuleMember -Function Start-CcodTrayUninstall
