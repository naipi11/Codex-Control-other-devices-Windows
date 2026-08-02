$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\KernelObjects.psm1'
Import-Module $modulePath -Force
$kernelModule=Get-Module KernelObjects
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-kernel-selftest-'+[guid]::NewGuid().ToString('N'))
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$userSid=$identity.User.Value
$identity.Dispose()
$sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId

function New-CcodPrivateKernelName([string]$Namespace,[string]$Kind){
    "$Namespace\CodexControlOtherDevices.Test.$Kind.$([guid]::NewGuid().ToString('N'))"
}

function Get-CcodAclFacts($Security,[string]$RightsProperty){
    $owner=$Security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $rules=@($Security.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
    [pscustomobject]@{Owner=$owner;Protected=$Security.AreAccessRulesProtected;Rules=$rules;RightsProperty=$RightsProperty}
}

function Copy-CcodKernelSecurity($Security,[type]$SecurityType){
    $bytes=$Security.GetSecurityDescriptorBinaryForm()
    $copy=[Activator]::CreateInstance($SecurityType)
    $copy.SetSecurityDescriptorBinaryForm($bytes)
    return $copy
}

function Set-CcodRawAclMutation($Security,[scriptblock]$Mutation,[type]$SecurityType){
    $raw=[Security.AccessControl.RawSecurityDescriptor]::new($Security.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
    & $Mutation $raw
    $bytes=New-Object byte[] $raw.BinaryLength
    $raw.GetBinaryForm($bytes,0)
    $copy=[Activator]::CreateInstance($SecurityType)
    $copy.SetSecurityDescriptorBinaryForm($bytes)
    return [pscustomobject]@{Security=$copy;DescriptorBinary=$bytes}
}

function New-CcodAclProbeAdapters($Security,[string]$Name,$DescriptorBinary){
    $handle=[Threading.Mutex]::new($false)
    $adapters=@{
        GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$Name}.GetNewClosure()
        CreateMutex={param($ObjectName,$ExpectedSecurity)[pscustomobject]@{Handle=$handle;CreatedNew=$true}}.GetNewClosure()
        GetMutexSecurity={param($ObjectHandle)$Security}.GetNewClosure()
        WaitMutex={param($ObjectHandle,$Timeout)throw 'wait must not run for a rejected ACL'}
        DisposeHandle={param($ObjectHandle)$ObjectHandle.Dispose()}
    }
    if($null -ne $DescriptorBinary){$adapters.GetMutexSecurityDescriptor={param($ObjectHandle,$ActualSecurity)$DescriptorBinary}.GetNewClosure()}
    return $adapters
}

function Invoke-CcodChild([string]$Body,[hashtable]$Variables,[bool]$AllowNonzero=$false){
    $scriptPath=Join-Path $root ([guid]::NewGuid().ToString('N')+'.ps1')
    $preamble="`$ErrorActionPreference='Stop'`r`n"
    foreach($name in $Variables.Keys){
        $literal="'"+([string]$Variables[$name]).Replace("'","''")+"'"
        $preamble+="`$$name=$literal`r`n"
    }
    [IO.Directory]::CreateDirectory($root)|Out-Null
    [IO.File]::WriteAllText($scriptPath,$preamble+$Body,[Text.UTF8Encoding]::new($false))
    $output=@(& $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath)
    if($LASTEXITCODE -ne 0 -and -not $AllowNonzero){throw "child helper failed with exit code $LASTEXITCODE"}
    return $output
}

try{
    Invoke-CcodTest 'exports only the seven bounded kernel-object functions' {
        $expected='Enter-CcodMutex,Exit-CcodMutex,Get-CcodKernelObjectName,New-CcodEvent,New-CcodEventSecurity,New-CcodMutexSecurity,Open-CcodEvent'
        $actual=((Get-Command -Module KernelObjects -CommandType Function).Name|Sort-Object)-join ','
        Assert-CcodEqual $expected $actual 'module export surface remains exact'
    }

    Invoke-CcodTest 'derives the exact six account and session object names' {
        $token='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        Assert-CcodEqual "Global\CodexControlOtherDevices.AccountSupervisor.$userSid" (Get-CcodKernelObjectName -Kind AccountSupervisor -UserSid $userSid) 'account supervisor name'
        Assert-CcodEqual "Global\CodexControlOtherDevices.AccountTransition.$userSid" (Get-CcodKernelObjectName -Kind AccountTransition -UserSid $userSid) 'account transition name'
        Assert-CcodEqual "Local\CodexControlOtherDevices.Supervisor.$userSid.$sessionId" (Get-CcodKernelObjectName -Kind Supervisor -UserSid $userSid -SessionId $sessionId) 'session supervisor name'
        Assert-CcodEqual "Local\CodexControlOtherDevices.Transition.$userSid.$sessionId" (Get-CcodKernelObjectName -Kind Transition -UserSid $userSid -SessionId $sessionId) 'session transition name'
        Assert-CcodEqual "Local\CodexControlOtherDevices.Shutdown.$userSid.$sessionId" (Get-CcodKernelObjectName -Kind Shutdown -UserSid $userSid -SessionId $sessionId) 'shutdown name'
        Assert-CcodEqual "Local\CodexControlOtherDevices.Ready.$userSid.$sessionId.$token" (Get-CcodKernelObjectName -Kind Ready -UserSid $userSid -SessionId $sessionId -ReadyToken $token) 'ready name'
    }

    Invoke-CcodTest 'rejects case variants coercion noncanonical SIDs illegal optionals and overlength names' {
        $token='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        $upper=$token.ToUpperInvariant()
        $longSid='S-1-5-'+((1..15|ForEach-Object{'4294967295'})-join '-')
        foreach($case in @(
            {Get-CcodKernelObjectName -Kind transition -UserSid $userSid -SessionId $sessionId},
            {Get-CcodKernelObjectName -Kind 1 -UserSid $userSid -SessionId $sessionId},
            {Get-CcodKernelObjectName -Kind Transition -UserSid ($userSid.ToLowerInvariant()) -SessionId $sessionId},
            {Get-CcodKernelObjectName -Kind Transition -UserSid 'S-1-5-18\bad' -SessionId $sessionId},
            {Get-CcodKernelObjectName -Kind Transition -UserSid $userSid -SessionId ([long]$sessionId)},
            {Get-CcodKernelObjectName -Kind Transition -UserSid $userSid -SessionId ([string]$sessionId)},
            {Get-CcodKernelObjectName -Kind Transition -UserSid $userSid -SessionId -1},
            {Get-CcodKernelObjectName -Kind Transition -UserSid $userSid},
            {Get-CcodKernelObjectName -Kind AccountTransition -UserSid $userSid -SessionId $sessionId},
            {Get-CcodKernelObjectName -Kind AccountTransition -UserSid $userSid -ReadyToken $token},
            {Get-CcodKernelObjectName -Kind Shutdown -UserSid $userSid -SessionId $sessionId -ReadyToken $token},
            {Get-CcodKernelObjectName -Kind Ready -UserSid $userSid -SessionId $sessionId},
            {Get-CcodKernelObjectName -Kind Ready -UserSid $userSid -SessionId $sessionId -ReadyToken $upper},
            {Get-CcodKernelObjectName -Kind Ready -UserSid $userSid -SessionId $sessionId -ReadyToken ($token+'0')},
            {Get-CcodKernelObjectName -Kind Ready -UserSid $longSid -SessionId $sessionId -ReadyToken $token}
        )){Assert-CcodThrows $case 'CCOD_KERNEL_INPUT_INVALID'}
    }

    Invoke-CcodTest 'constructs protected exact mutex and event DACLs' {
        foreach($case in @(
            @{Security=(New-CcodMutexSecurity -UserSid $userSid);Type=[Security.AccessControl.MutexSecurity];Rights='MutexRights'},
            @{Security=(New-CcodEventSecurity -UserSid $userSid);Type=[Security.AccessControl.EventWaitHandleSecurity];Rights='EventWaitHandleRights'}
        )){
            Assert-CcodTrue ($case.Security.GetType() -eq $case.Type) 'constructor returns the exact framework type'
            $facts=Get-CcodAclFacts $case.Security $case.Rights
            Assert-CcodEqual $userSid $facts.Owner 'owner is the current user'
            Assert-CcodEqual $true $facts.Protected 'DACL is protected'
            Assert-CcodEqual 3 $facts.Rules.Count 'there are exactly three explicit ACEs'
            Assert-CcodEqual ((@('S-1-5-18','S-1-5-32-544',$userSid)|Sort-Object)-join ',') (($facts.Rules.IdentityReference.Value|Sort-Object)-join ',') 'only current user SYSTEM and administrators are allowed'
            foreach($rule in $facts.Rules){
                Assert-CcodEqual 'Allow' ([string]$rule.AccessControlType) 'ACE is allow'
                Assert-CcodEqual $false $rule.IsInherited 'ACE is explicit'
                Assert-CcodEqual 'None' ([string]$rule.InheritanceFlags) 'no inheritance flags'
                Assert-CcodEqual 'None' ([string]$rule.PropagationFlags) 'no propagation flags'
                Assert-CcodEqual 'FullControl' ([string]$rule.($case.Rights)) 'rights are exact FullControl'
            }
        }
    }

    Invoke-CcodTest 'fails closed on owner extra missing deny inherited partial and duplicate ACL mutations' {
        $base=New-CcodMutexSecurity -UserSid $userSid
        $mutations=[Collections.Generic.List[object]]::new()
        $owner=Copy-CcodKernelSecurity $base ([Security.AccessControl.MutexSecurity]);$owner.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-18'));$mutations.Add([pscustomobject]@{Security=$owner;DescriptorBinary=$null})
        $extra=Copy-CcodKernelSecurity $base ([Security.AccessControl.MutexSecurity]);$extra.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));$mutations.Add([pscustomobject]@{Security=$extra;DescriptorBinary=$null})
        $missing=Copy-CcodKernelSecurity $base ([Security.AccessControl.MutexSecurity]);$missing.RemoveAccessRuleAll([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));$mutations.Add([pscustomobject]@{Security=$missing;DescriptorBinary=$null})
        $deny=Copy-CcodKernelSecurity $base ([Security.AccessControl.MutexSecurity]);$deny.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Deny));$mutations.Add([pscustomobject]@{Security=$deny;DescriptorBinary=$null})
        $partial=Copy-CcodKernelSecurity $base ([Security.AccessControl.MutexSecurity]);$partial.RemoveAccessRuleAll([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));$partial.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.AccessControl.MutexRights]::Modify,[Security.AccessControl.AccessControlType]::Allow));$mutations.Add([pscustomobject]@{Security=$partial;DescriptorBinary=$null})
        $duplicate=Set-CcodRawAclMutation $base {param($raw)$ace=$raw.DiscretionaryAcl[0];$raw.DiscretionaryAcl.InsertAce(1,$ace)} ([Security.AccessControl.MutexSecurity]);$mutations.Add($duplicate)
        $inherited=Set-CcodRawAclMutation $base {param($raw)$ace=$raw.DiscretionaryAcl[0];$replacement=[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::Inherited,$ace.AceQualifier,$ace.AccessMask,$ace.SecurityIdentifier,$false,$null);$raw.DiscretionaryAcl.RemoveAce(0);$raw.DiscretionaryAcl.InsertAce(0,$replacement)} ([Security.AccessControl.MutexSecurity]);$mutations.Add($inherited)
        foreach($mutation in $mutations){
            $name=New-CcodPrivateKernelName Local Acl
            Assert-CcodThrows {Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 0 -Adapters (New-CcodAclProbeAdapters $mutation.Security $name $mutation.DescriptorBinary)} 'CCOD_KERNEL_ACL_MISMATCH'
        }
    }

    Invoke-CcodTest 'acquires and releases a private mutex with exact lease shapes and double cleanup' {
        $name=New-CcodPrivateKernelName Local Lease
        $lease=$null
        try{
            $lease=Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 1000 -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$name}.GetNewClosure()}
            Assert-CcodEqual 'SchemaVersion,Name,Kind,Outcome,CreatedNew,Abandoned,Handle,OwnerManagedThreadId,Released' (($lease.PSObject.Properties.Name)-join ',') 'lease fields are exact and ordered'
            Assert-CcodEqual 'Acquired' $lease.Outcome 'private mutex acquired'
            Assert-CcodEqual $false $lease.Abandoned 'fresh mutex is not abandoned'
            Assert-CcodTrue ($lease.Handle -is [Threading.Mutex]) 'lease carries exact Mutex handle'
            Assert-CcodEqual $true (Exit-CcodMutex -Lease $lease) 'first cleanup releases and disposes'
            Assert-CcodEqual $null $lease.Handle 'released lease drops handle'
            Assert-CcodEqual $true $lease.Released 'released flag is mutated'
            Assert-CcodEqual $false (Exit-CcodMutex -Lease $lease) 'second cleanup is an idempotent false'
        }finally{if($null -ne $lease -and -not $lease.Released){Exit-CcodMutex -Lease $lease|Out-Null}}
    }

    Invoke-CcodTest 'releases acquired ownership before disposing after an unexpected post-wait failure' {
        $name=New-CcodPrivateKernelName Local PostWait;$events=[Collections.Generic.List[string]]::new();$handle=[Threading.Mutex]::new($false);$security=New-CcodMutexSecurity -UserSid $userSid
        $adapters=@{
            GetName={param($IgnoredKind,$IgnoredSid,$IgnoredSession,$IgnoredToken)$name}.GetNewClosure();CreateMutex={param($ObjectName,$ExpectedSecurity)[pscustomobject]@{Handle=$handle;CreatedNew=$true}}.GetNewClosure();GetMutexSecurity={param($ObjectHandle)$security}.GetNewClosure();WaitMutex={param($ObjectHandle,$Timeout)$true};GetManagedThreadId={'coercive-thread-id'}
            ReleaseMutex={param($ObjectHandle)$events.Add('release');$ObjectHandle.ReleaseMutex()}.GetNewClosure();DisposeHandle={param($ObjectHandle)$events.Add('dispose');$ObjectHandle.Dispose()}.GetNewClosure()
        }
        Assert-CcodThrows {Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 0 -Adapters $adapters} 'CCOD_KERNEL_OPEN_FAILED'
        Assert-CcodEqual 'release,dispose' ($events -join ',') 'post-wait validation failure cannot strand ownership before handle cleanup'
    }

    Invoke-CcodTest 'enforces a global mutex across a helper process and returns the exact timeout shape' {
        $name=New-CcodPrivateKernelName Global Exclusion
        $lease=$null
        try{
            $lease=Enter-CcodMutex -Kind AccountTransition -UserSid $userSid -TimeoutMilliseconds 1000 -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$name}.GetNewClosure()}
            $body=@'
Import-Module $modulePath -Force
$lease=Enter-CcodMutex -Kind AccountTransition -UserSid $userSid -TimeoutMilliseconds 100 -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$objectName}.GetNewClosure()}
            $lease|ConvertTo-Json -Depth 4 -Compress
'@
            $child=@(Invoke-CcodChild $body @{modulePath=$modulePath;userSid=$userSid;objectName=$name})
            $timed=$child[-1]|ConvertFrom-Json
            Assert-CcodEqual 'SchemaVersion,Name,Kind,Outcome,CreatedNew,Abandoned,Handle,OwnerManagedThreadId,Released' (($timed.PSObject.Properties.Name)-join ',') 'timeout preserves the exact nine-field lease shape'
            Assert-CcodEqual 'TimedOut' $timed.Outcome 'other process cannot enter held global mutex'
            Assert-CcodEqual $false $timed.Abandoned 'timeout is not abandonment'
            Assert-CcodEqual $null $timed.Handle 'timeout drops and disposes its handle'
            Assert-CcodEqual $null $timed.OwnerManagedThreadId 'timeout has no owning thread'
            Assert-CcodEqual $true $timed.Released 'timeout handle is already disposed'
        }finally{if($null -ne $lease -and -not $lease.Released){Exit-CcodMutex -Lease $lease|Out-Null}}
    }

    Invoke-CcodTest 'signals and reopens a private manual-reset event across a helper process' {
        $name=New-CcodPrivateKernelName Local Event
        $eventLease=$null;$reopened=$null
        try{
            $eventLease=New-CcodEvent -Kind Shutdown -UserSid $userSid -SessionId $sessionId -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$name}.GetNewClosure()}
            Assert-CcodEqual 'SchemaVersion,Name,Kind,CreatedNew,Handle,Disposed' (($eventLease.PSObject.Properties.Name)-join ',') 'event fields are exact and ordered'
            Assert-CcodEqual $true $eventLease.CreatedNew 'first event creation is new'
            $body=@'
Import-Module $modulePath -Force
$opened=Open-CcodEvent -Kind Shutdown -UserSid $userSid -SessionId ([int]$sessionId) -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$objectName}.GetNewClosure()}
try{[void]$opened.Handle.Set();'signaled'}finally{$opened.Handle.Dispose();$opened.Handle=$null;$opened.Disposed=$true}
'@
            $child=@(Invoke-CcodChild $body @{modulePath=$modulePath;userSid=$userSid;sessionId=$sessionId;objectName=$name})
            Assert-CcodEqual 'signaled' $child[-1] 'helper signaled exact existing event'
            Assert-CcodEqual $true $eventLease.Handle.WaitOne(1000) 'manual reset signal reaches creator'
            $reopened=Open-CcodEvent -Kind Shutdown -UserSid $userSid -SessionId $sessionId -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$name}.GetNewClosure()}
            Assert-CcodEqual $false $reopened.CreatedNew 'open never claims creation'
            Assert-CcodEqual $true $reopened.Handle.WaitOne(0) 'new/open never resets existing signaled event'
        }finally{
            foreach($item in @($reopened,$eventLease)){if($null -ne $item -and -not $item.Disposed){$item.Handle.Dispose();$item.Handle=$null;$item.Disposed=$true}}
        }
    }

    Invoke-CcodTest 'opens only an existing tokenized private Ready event and validates its ACL' {
        $name=New-CcodPrivateKernelName Local Ready;$readyName=$name;$readyAdapter={param($IgnoredKind,$IgnoredSid,$IgnoredSession,$IgnoredToken)$readyName}.GetNewClosure();$token='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';$raw=$null;$opened=$null
        try{
            Assert-CcodThrows {Open-CcodEvent -Kind Ready -UserSid $userSid -SessionId $sessionId -ReadyToken $token -Adapters @{GetName=$readyAdapter}} 'CCOD_KERNEL_OPEN_FAILED'
            $security=New-CcodEventSecurity -UserSid $userSid;$created=$false;$raw=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name,[ref]$created,$security)
            $opened=Open-CcodEvent -Kind Ready -UserSid $userSid -SessionId $sessionId -ReadyToken $token -Adapters @{GetName=$readyAdapter}
            Assert-CcodEqual $false $opened.CreatedNew 'ready open never claims creation'
            Assert-CcodEqual $false $opened.Handle.WaitOne(0) 'ready open does not signal or reset the existing event'
            [void]$opened.Handle.Set();Assert-CcodEqual $true $raw.WaitOne(0) 'ready handle includes exact modify and synchronize rights'
        }finally{if($null -ne $opened -and -not $opened.Disposed){$opened.Handle.Dispose();$opened.Handle=$null;$opened.Disposed=$true};if($null -ne $raw){$raw.Dispose()}}
    }

    Invoke-CcodTest 'rejects private ACL mismatch and wait-handle type collision without opening unsafe objects' {
        $badName=New-CcodPrivateKernelName Local BadAcl;$badHandle=$null;$collisionName=New-CcodPrivateKernelName Local Collision;$collision=$null
        try{
            $security=[Security.AccessControl.MutexSecurity]::new();$security.SetOwner([Security.Principal.SecurityIdentifier]::new($userSid));$security.SetAccessRuleProtection($true,$false);$security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
            $created=$false;$badHandle=[Threading.Mutex]::new($false,$badName,[ref]$created,$security)
            $badNameAdapter={param($IgnoredKind,$IgnoredSid,$IgnoredSession,$IgnoredToken)$badName}.GetNewClosure()
            Assert-CcodThrows {Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 0 -Adapters @{GetName=$badNameAdapter}} 'CCOD_KERNEL_ACL_MISMATCH'
            $eventSecurity=New-CcodEventSecurity -UserSid $userSid;$eventCreated=$false;$collision=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$collisionName,[ref]$eventCreated,$eventSecurity)
            $collisionNameAdapter={param($IgnoredKind,$IgnoredSid,$IgnoredSession,$IgnoredToken)$collisionName}.GetNewClosure()
            Assert-CcodThrows {Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 0 -Adapters @{GetName=$collisionNameAdapter}} 'CCOD_KERNEL_OBJECT_TYPE_MISMATCH'
        }finally{if($null -ne $collision){$collision.Dispose()};if($null -ne $badHandle){$badHandle.Dispose()}}
    }

    Invoke-CcodTest 'rejects private event ACL mismatch and reverse wait-handle type collision' {
        $badName=New-CcodPrivateKernelName Local BadEvent;$mutexName=New-CcodPrivateKernelName Local MutexCollision;$badEvent=$null;$mutex=$null
        try{
            $badSecurity=[Security.AccessControl.EventWaitHandleSecurity]::new();$badSecurity.SetOwner([Security.Principal.SecurityIdentifier]::new($userSid));$badSecurity.SetAccessRuleProtection($true,$false);$badSecurity.AddAccessRule([Security.AccessControl.EventWaitHandleAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.EventWaitHandleRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
            $created=$false;$badEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$badName,[ref]$created,$badSecurity)
            $badAdapter={param($IgnoredKind,$IgnoredSid,$IgnoredSession,$IgnoredToken)$badName}.GetNewClosure()
            Assert-CcodThrows {Open-CcodEvent -Kind Shutdown -UserSid $userSid -SessionId $sessionId -Adapters @{GetName=$badAdapter}} 'CCOD_KERNEL_ACL_MISMATCH'
            $mutexSecurity=New-CcodMutexSecurity -UserSid $userSid;$mutexCreated=$false;$mutex=[Threading.Mutex]::new($false,$mutexName,[ref]$mutexCreated,$mutexSecurity)
            $collisionAdapter={param($IgnoredKind,$IgnoredSid,$IgnoredSession,$IgnoredToken)$mutexName}.GetNewClosure()
            Assert-CcodThrows {Open-CcodEvent -Kind Shutdown -UserSid $userSid -SessionId $sessionId -Adapters @{GetName=$collisionAdapter}} 'CCOD_KERNEL_OBJECT_TYPE_MISMATCH'
        }finally{if($null -ne $mutex){$mutex.Dispose()};if($null -ne $badEvent){$badEvent.Dispose()}}
    }

    Invoke-CcodTest 'treats a child-abandoned private mutex as an acquired owned lease' {
        $name=New-CcodPrivateKernelName Local Abandon
        $anchorSecurity=New-CcodMutexSecurity -UserSid $userSid;$anchorCreated=$false;$anchor=[Threading.Mutex]::new($false,$name,[ref]$anchorCreated,$anchorSecurity)
        $body=@'
Import-Module $modulePath -Force
$lease=Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId ([int]$sessionId) -TimeoutMilliseconds 1000 -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$objectName}.GetNewClosure()}
if($lease.Outcome -cne 'Acquired'){exit 2}
Stop-Process -Id $PID -Force
'@
        $lease=$null
        try{
            [void](Invoke-CcodChild $body @{modulePath=$modulePath;userSid=$userSid;sessionId=$sessionId;objectName=$name} $true)
            $lease=Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 1000 -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$name}.GetNewClosure()}
            Assert-CcodEqual 'Acquired' $lease.Outcome 'abandoned mutex still grants ownership'
            Assert-CcodEqual $true $lease.Abandoned 'lease records abandonment'
        }finally{if($null -ne $lease -and -not $lease.Released){Exit-CcodMutex -Lease $lease|Out-Null};$anchor.Dispose()}
    }

    Invoke-CcodTest 'rejects wrong-thread release then permits owner-thread cleanup' {
        $name=New-CcodPrivateKernelName Local Thread
        $lease=Enter-CcodMutex -Kind Transition -UserSid $userSid -SessionId $sessionId -TimeoutMilliseconds 1000 -Adapters @{GetName={param($Kind,$UserSid,$SessionId,$ReadyToken)$name}.GetNewClosure()}
        $runspace=[RunspaceFactory]::CreateRunspace();$pipeline=$null
        try{
            $runspace.Open();$runspace.SessionStateProxy.SetVariable('Lease',$lease);$runspace.SessionStateProxy.SetVariable('ModulePath',$modulePath)
            $pipeline=$runspace.CreatePipeline("Import-Module `$ModulePath -Force; try { Exit-CcodMutex -Lease `$Lease | Out-Null; 'unexpected' } catch { `$_.FullyQualifiedErrorId }")
            $wrong=@($pipeline.Invoke())
            Assert-CcodTrue (($wrong -join ',') -like 'CCOD_KERNEL_RELEASE_FAILED*') 'non-owner managed thread is rejected'
            Assert-CcodEqual $false $lease.Released 'wrong thread never claims release'
            Assert-CcodEqual $true (Exit-CcodMutex -Lease $lease) 'owner thread can still clean up'
        }finally{if($null -ne $pipeline){$pipeline.Dispose()};$runspace.Dispose();if(-not $lease.Released){Exit-CcodMutex -Lease $lease|Out-Null}}
    }
}catch{Write-Error $_;exit 1}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
