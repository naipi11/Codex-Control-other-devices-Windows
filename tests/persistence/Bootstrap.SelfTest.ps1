$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$bootstrapScript = Join-Path $repositoryRoot 'src\persistence\bootstrap.ps1'
$runtimeManifestModule = Join-Path $repositoryRoot 'src\persistence\modules\RuntimeManifest.psm1'
$powershellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $bootstrapScript -PathType Leaf)) {
    throw "Bootstrap script is missing: $bootstrapScript"
}
if (-not (Test-Path -LiteralPath $runtimeManifestModule -PathType Leaf)) {
    throw "Runtime manifest module is missing: $runtimeManifestModule"
}
Import-Module $runtimeManifestModule -Force

function Assert-CcodExactEqual($Expected, $Actual, [string]$Message) {
    if (-not [object]::Equals($Expected, $Actual)) {
        throw "ASSERT_EXACT: $Message expected=[$Expected] actual=[$Actual]"
    }
}

function New-CcodBootstrapToken {
    return ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
}

function New-CcodTestSupervisorScript {
    param([string]$Kind, [string]$MarkerPath)

    $markerLine = if ([string]::IsNullOrWhiteSpace($MarkerPath)) {
        ''
    } else {
        "[IO.File]::WriteAllText('$MarkerPath','started')"
    }
    switch ($Kind) {
        'Ready' {
            return @"
param([string]`$ReadyToken)
$markerLine
`$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
`$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
`$name="Local\CodexControlOtherDevices.Ready.`$sid.`$session.`$ReadyToken"
`$event=[Threading.EventWaitHandle]::OpenExisting(`$name)
`$event.Set() | Out-Null
Start-Sleep -Milliseconds 200
exit 0
"@
        }
        'ExitEarly' {
            return @"
param([string]`$ReadyToken)
$markerLine
exit 7
"@
        }
        'Timeout' {
            return @"
param([string]`$ReadyToken)
$markerLine
Start-Sleep -Seconds 60
exit 0
"@
        }
        'ExitLaterNonzero' {
            return @"
param([string]`$ReadyToken)
$markerLine
`$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
`$session=[Diagnostics.Process]::GetCurrentProcess().SessionId
`$name="Local\CodexControlOtherDevices.Ready.`$sid.`$session.`$ReadyToken"
`$event=[Threading.EventWaitHandle]::OpenExisting(`$name)
`$event.Set() | Out-Null
Start-Sleep -Milliseconds 300
exit 9
"@
        }
        default { throw "Unknown fake supervisor kind: $Kind" }
    }
}

function New-CcodBootstrapFixture {
    param([string]$Root)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'logs') -Force | Out-Null
    return $Root
}

function Add-CcodTestRuntime {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SupervisorScript,
        [AllowNull()][string]$RuntimeId
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
        $runtimeDirectory = Join-Path $Root ('runtime\pending-' + [guid]::NewGuid().ToString('N'))
    } else {
        $runtimeDirectory = Join-Path $Root "runtime\$RuntimeId"
    }
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    $supervisorDirectory = Join-Path $runtimeDirectory 'src\persistence'
    New-Item -ItemType Directory -Path $supervisorDirectory -Force | Out-Null
    $supervisorPath = Join-Path $supervisorDirectory 'Supervisor.ps1'
    [IO.File]::WriteAllText($supervisorPath, $SupervisorScript, [Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
        $hash = (Get-FileHash -LiteralPath $supervisorPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $length = [int64](Get-Item -LiteralPath $supervisorPath).Length
        $files = @([pscustomobject]@{ path = 'src/persistence/Supervisor.ps1'; length = $length; sha256 = $hash })
        $RuntimeId = Get-CcodRuntimeId -ProjectVersion '0.0.0-bootstrap-test' -Files $files
        $targetDirectory = Join-Path $Root "runtime\$RuntimeId"
        if ($targetDirectory -cne $runtimeDirectory) {
            [IO.Directory]::Move($runtimeDirectory, $targetDirectory)
            $runtimeDirectory = $targetDirectory
            $supervisorPath = Join-Path $runtimeDirectory 'src\persistence\Supervisor.ps1'
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        projectVersion = '0.0.0-bootstrap-test'
        runtimeId = $RuntimeId
        files = @(
            [ordered]@{
                path = 'src/persistence/Supervisor.ps1'
                length = [int64](Get-Item -LiteralPath $supervisorPath).Length
                sha256 = (Get-FileHash -LiteralPath $supervisorPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $runtimeDirectory 'manifest.json'),
        ($manifest | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )
    return $RuntimeId
}

function Set-CcodTestActivePointer {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ActiveRuntime,
        [AllowNull()][string]$PreviousRuntime
    )

    $pointer = [ordered]@{
        schemaVersion = 1
        activeRuntime = $ActiveRuntime
        previousRuntime = $PreviousRuntime
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText(
        (Join-Path $Root 'active.json'),
        ($pointer | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-CcodTestActivePointer {
    param([Parameter(Mandatory)][string]$Root)

    return (Get-Content -LiteralPath (Join-Path $Root 'active.json') -Raw | ConvertFrom-Json)
}

function Invoke-CcodBootstrapUnderTest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ReadyToken,
        [int]$ReadyTimeoutSeconds = 3
    )

    & $powershellExecutable -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript `
        -InstallRoot $Root -ReadyToken $ReadyToken -ReadyTimeoutSeconds $ReadyTimeoutSeconds 2>&1
    return [int]$LASTEXITCODE
}

$results = @()

$results += Invoke-CcodTest 'selects previous runtime after active exits before ready and swaps pointer' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 0 $exitCode 'previous fallback succeeds'
        Assert-CcodTrue (Test-Path -LiteralPath $activeMarker) 'active runtime was attempted first'
        Assert-CcodTrue (Test-Path -LiteralPath $previousMarker) 'previous runtime was then launched'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'previous becomes active after ready'
        Assert-CcodExactEqual $activeId $pointer.previousRuntime 'old active is retained for rollback'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'keeps a ready active runtime and does not rewrite the pointer' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $activeMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $null

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 0 $exitCode 'healthy active runtime succeeds'
        Assert-CcodTrue (Test-Path -LiteralPath $activeMarker) 'active supervisor was launched'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $activeId $pointer.activeRuntime 'active pointer is unchanged'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'fails and keeps the pointer when both runtimes exit before ready' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath (Join-Path $root 'active.started'))
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath (Join-Path $root 'previous.started'))
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodTrue ($exitCode -ne 0) 'both-invalid bootstrap must fail closed'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $activeId $pointer.activeRuntime 'failed bootstrap never rewrites active'
        Assert-CcodExactEqual $previousId $pointer.previousRuntime 'failed bootstrap never rewrites previous'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'falls back after a ready timeout and stops the exact hung child' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Timeout' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token -ReadyTimeoutSeconds 2
        Assert-CcodExactEqual 0 $exitCode 'timeout falls back to previous'
        Assert-CcodTrue (Test-Path -LiteralPath $activeMarker) 'hung active was launched'
        Assert-CcodTrue (Test-Path -LiteralPath $previousMarker) 'previous was launched after timeout'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'timeout fallback swaps pointer'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'invalid active manifest falls back to a verified previous runtime' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        [IO.File]::WriteAllText(
            (Join-Path $root "runtime\$activeId\Supervisor.ps1"),
            "param([string]`$ReadyToken)`ncorrupt",
            [Text.UTF8Encoding]::new($false)
        )
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 0 $exitCode 'invalid active manifest falls back'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $activeMarker)) 'corrupt active runtime is never executed'
        Assert-CcodTrue (Test-Path -LiteralPath $previousMarker) 'verified previous is launched'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'fallback pointer is swapped'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'rejects a pre-existing stale ready event before launching any supervisor' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    $handle = $null
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'Ready' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $name = "Local\CodexControlOtherDevices.Ready.$sid.$session.$token"
        $created = $false
        $handle = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $name, [ref]$created)
        Assert-CcodTrue $created 'stale-event fixture must create the named event'
        $handle.Set() | Out-Null

        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodTrue ($exitCode -ne 0) 'pre-existing ready event is fail closed'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $activeMarker)) 'stale event must not launch active'
        Assert-CcodTrue (-not (Test-Path -LiteralPath $previousMarker)) 'stale event must not launch previous'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $activeId $pointer.activeRuntime 'stale event leaves pointer unchanged'
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'propagates a nonzero exit after the supervisor signals ready' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-bootstrap-" + [guid]::NewGuid().ToString('N'))
    try {
        New-CcodBootstrapFixture -Root $root | Out-Null
        $activeMarker = Join-Path $root 'active.started'
        $previousMarker = Join-Path $root 'previous.started'
        $activeId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitEarly' -MarkerPath $activeMarker)
        $previousId = Add-CcodTestRuntime -Root $root -SupervisorScript (New-CcodTestSupervisorScript -Kind 'ExitLaterNonzero' -MarkerPath $previousMarker)
        Set-CcodTestActivePointer -Root $root -ActiveRuntime $activeId -PreviousRuntime $previousId

        $token = New-CcodBootstrapToken
        $exitCode = Invoke-CcodBootstrapUnderTest -Root $root -ReadyToken $token
        Assert-CcodExactEqual 9 $exitCode 'later abnormal supervisor exit is propagated'
        $pointer = Read-CcodTestActivePointer -Root $root
        Assert-CcodExactEqual $previousId $pointer.activeRuntime 'ready pointer swap still commits before abnormal exit'
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

$results += Invoke-CcodTest 'bootstrap contains no Codex process, package, or task mutation commands' {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$tokens, [ref]$parseErrors)
    Assert-CcodExactEqual 0 @($parseErrors).Count 'bootstrap parses before command audit'
    $forbidden = @(
        'Get-Process', 'Stop-Process', 'Get-AppxPackage', 'Get-CimInstance', 'Get-WmiObject',
        'Register-WmiEvent', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'schtasks',
        'Register-ObjectEvent', 'Invoke-WebRequest', 'Invoke-RestMethod', 'node'
    )
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ })
    foreach ($name in $commands) {
        Assert-CcodTrue ($forbidden -cnotcontains $name) "bootstrap cannot reach $name"
    }
}


$results += Invoke-CcodTest 'launches the supervisor child with an explicit STA apartment' {
    $source = Get-Content -LiteralPath $bootstrapScript -Raw
    Assert-CcodTrue ($source.Contains('-STA -File')) 'bootstrap supervisor launch arguments include -STA before -File'
    Assert-CcodTrue ($source.Contains('-NoProfile -ExecutionPolicy Bypass -STA -File')) 'bootstrap uses the exact STA launch argument prefix'
    Assert-CcodTrue (-not $source.Contains('-NoProfile -ExecutionPolicy Bypass -File "')) 'bootstrap no longer launches the supervisor without -STA'
}


$results += Invoke-CcodTest 'defaults InstallRoot to the bootstrap script directory for task launches' {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$tokens, [ref]$parseErrors)
    Assert-CcodExactEqual 0 @($parseErrors).Count 'bootstrap parses before InstallRoot default audit'
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'InstallRoot' } | Select-Object -First 1
    Assert-CcodTrue ($null -ne $param) 'InstallRoot parameter exists'
    Assert-CcodTrue (-not $param.Attributes.Where({ $_.TypeName.Name -ceq 'Parameter' -and $_.NamedArguments.Where({ $_.ArgumentName -ceq 'Mandatory' -and $_.Argument.Extent.Text -match 'true' }) }).Count) 'InstallRoot is not mandatory'
    Assert-CcodTrue ($param.DefaultValue.Extent.Text -match 'PSScriptRoot') 'InstallRoot defaults to PSScriptRoot for scheduled-task launches'
}

$results | Format-Table -AutoSize
Write-Host ("Bootstrap self-test passed: {0}" -f $results.Count)
