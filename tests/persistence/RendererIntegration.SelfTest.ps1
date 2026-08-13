$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$module = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\persistence\modules\RendererIntegration.psm1'
Import-Module $module -Force

$localAppData = Join-Path ([IO.Path]::GetTempPath()) ("ccod-renderer-" + [guid]::NewGuid().ToString('N'))
$root = Join-Path $localAppData 'CodexRenderer'
$oldLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $localAppData

function Assert-CcodPropertyOrder($Value, [string[]]$Expected, [string]$Message) {
    Assert-CcodEqual ($Expected -join ',') (@($Value.PSObject.Properties.Name) -join ',') $Message
}

function New-CcodRendererFixture {
    param([switch]$WithoutStartScript, [switch]$Paused)
    New-Item -ItemType Directory -Path (Join-Path $root 'engine\scripts') -Force | Out-Null
    if (-not $WithoutStartScript) {
        [IO.File]::WriteAllText((Join-Path $root 'engine\scripts\start-renderer.ps1'), '# fixture', [Text.UTF8Encoding]::new($false))
    }
    if ($Paused) {
        [IO.File]::WriteAllText((Join-Path $root 'paused'), '', [Text.UTF8Encoding]::new($false))
    }
}

function New-CcodRendererAdapters {
    param([string]$StateText, [switch]$StateExists, [switch]$PortAvailable, [bool]$InjectorAlive = $true, $Launches)
    @{
        ReadText = { param([string]$Path) $StateText }.GetNewClosure()
        PathExists = {
            param([string]$Path)
            if ($Path -like '*state.json') { return [bool]$StateExists }
            if ($Path -eq 'C:\Codex\Codex.exe') { return $true }
            [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)
        }.GetNewClosure()
        TestLoopbackPortAvailable = { param([int]$Port) [bool]$PortAvailable }.GetNewClosure()
        TestProcessAlive = { param([int]$ProcessId) [bool]$InjectorAlive }.GetNewClosure()
        StartHiddenProcess = {
            param([string]$FilePath, [string[]]$Arguments)
            $Launches.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($Arguments) })
            [pscustomobject]@{ Id = 4242 }
        }.GetNewClosure()
    }
}

try {
    New-CcodRendererFixture

    Invoke-CcodTest 'selects the valid saved renderer port 9444' {
        $adapters = New-CcodRendererAdapters -StateExists -StateText '{"port":9444,"browserId":"browser-1","injectorPid":99,"codexExe":"C:\\Codex\\Codex.exe"}' -PortAvailable
        $layout = Get-CcodRendererLayout -Root $root
        $state = Read-CcodRendererState -Layout $layout -Adapters $adapters
        Assert-CcodPropertyOrder $layout @('Installed','Root','EngineRoot','StartScript','StatePath','PauseFile','DefaultRendererPort') 'layout property order'
        Assert-CcodPropertyOrder $state @('Port','BrowserId','InjectorPid','CodexExe','Paused','InjectorAlive') 'state property order'
        Assert-CcodEqual $true $state.InjectorAlive 'live injector is reported in saved state'
        Assert-CcodEqual 9444 (Get-CcodRendererPreferredPort -ExcludedPorts @() -Adapters $adapters) 'saved state port is preferred'
    }

    Invoke-CcodTest 'reports a dead saved injector from state' {
        $adapters = New-CcodRendererAdapters -StateExists -StateText '{"port":9444,"browserId":"browser-1","injectorPid":99,"codexExe":"C:\\Codex\\Codex.exe"}' -PortAvailable -InjectorAlive:$false
        $layout = Get-CcodRendererLayout -Root $root
        $state = Read-CcodRendererState -Layout $layout -Adapters $adapters
        Assert-CcodEqual $false $state.InjectorAlive 'dead injector is reported in saved state'
    }

    Invoke-CcodTest 'falls back to renderer port 9335 when state is missing' {
        $adapters = New-CcodRendererAdapters -PortAvailable
        Assert-CcodEqual 9335 (Get-CcodRendererPreferredPort -ExcludedPorts @() -Adapters $adapters) 'missing state uses default port'
    }

    Invoke-CcodTest 'falls back safely when state is invalid' {
        $adapters = New-CcodRendererAdapters -StateExists -StateText '{not-json' -PortAvailable
        $layout = Get-CcodRendererLayout -Root $root
        Assert-CcodEqual $null (Read-CcodRendererState -Layout $layout -Adapters $adapters) 'invalid state is unavailable'
        Assert-CcodEqual $null (Get-CcodRendererPreferredPort -ExcludedPorts @() -Adapters $adapters) 'invalid state leaves no preferred port'
    }

    Invoke-CcodTest 'accepts only an exact loopback Browser ID response for the requested renderer port' {
        $adapters = New-CcodRendererAdapters -PortAvailable
        $adapters.ReadBrowserId = {
            param([int]$Port)
            if($Port -eq 9335){[pscustomobject][ordered]@{ResponseUri='http://127.0.0.1:9335/json/version';WebSocketDebuggerUrl='ws://127.0.0.1:9335/devtools/browser/browser-current'}}else{$null}
        }
        Assert-CcodEqual 'browser-current' (Get-CcodRendererCurrentBrowserId -RendererPort 9335 -Adapters $adapters) 'loopback Browser ID is returned exactly'
        Assert-CcodEqual $null (Get-CcodRendererCurrentBrowserId -RendererPort 9444 -Adapters $adapters) 'unreadable Browser ID is unavailable'
    }

    Invoke-CcodTest 'rejects redirected remote and port-mismatched Browser ID responses' {
        $cases = @(
            [pscustomobject]@{Name='redirected';ResponseUri='https://remote.example/json/version';WebSocketDebuggerUrl='ws://127.0.0.1:9335/devtools/browser/browser-current'},
            [pscustomobject]@{Name='remote-websocket';ResponseUri='http://127.0.0.1:9335/json/version';WebSocketDebuggerUrl='ws://remote.example:9335/devtools/browser/browser-current'},
            [pscustomobject]@{Name='mismatched-port';ResponseUri='http://127.0.0.1:9335/json/version';WebSocketDebuggerUrl='ws://127.0.0.1:9444/devtools/browser/browser-current'},
            [pscustomobject]@{Name='invalid-port';ResponseUri='http://127.0.0.1:9335/json/version';WebSocketDebuggerUrl='ws://127.0.0.1:70000/devtools/browser/browser-current'}
        )
        foreach($case in $cases){
            $adapters = New-CcodRendererAdapters -PortAvailable
            $document=[pscustomobject][ordered]@{ResponseUri=$case.ResponseUri;WebSocketDebuggerUrl=$case.WebSocketDebuggerUrl}
            $adapters.ReadBrowserId = { param([int]$Port) $document }.GetNewClosure()
            Assert-CcodEqual $null (Get-CcodRendererCurrentBrowserId -RendererPort 9335 -Adapters $adapters) "$($case.Name) Browser response is rejected"
        }
    }

    Invoke-CcodTest 'reports missing official start script as not installed' {
        $missingRoot = Join-Path $localAppData 'MissingRenderer'
        New-Item -ItemType Directory -Path (Join-Path $missingRoot 'engine\scripts') -Force | Out-Null
        $layout = Get-CcodRendererLayout -Root $missingRoot
        Assert-CcodEqual $false $layout.Installed 'the official start script defines installation'
    }

    Invoke-CcodTest 'recognizes a pre-2.1 legacy install without the standard root or script name' {
        $legacyDirName = 'Codex' + 'Dre' + 'am' + 'Skin'
        $legacyRoot = Join-Path $localAppData $legacyDirName
        $hiddenStandardRoot = $root + '.hidden-legacy-test'
        $movedStandard = $false
        if ([IO.Directory]::Exists($root)) {
            Move-Item -LiteralPath $root -Destination $hiddenStandardRoot
            $movedStandard = $true
        }
        try {
            New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'engine\scripts') -Force | Out-Null
            $legacyScriptName = 'start-' + 'dre' + 'am' + '-skin.ps1'
            [IO.File]::WriteAllText((Join-Path $legacyRoot "engine\scripts\$legacyScriptName"), '# legacy fixture', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $legacyRoot 'paused'), '', [Text.UTF8Encoding]::new($false))
            $layout = Get-CcodRendererLayout
            Assert-CcodEqual $true $layout.Installed 'legacy install is detected automatically'
            Assert-CcodEqual $legacyRoot $layout.Root 'legacy install root is selected when the standard root is absent'
            Assert-CcodEqual (Join-Path $legacyRoot "engine\scripts\$legacyScriptName") $layout.StartScript 'legacy start script name is resolved'
            Assert-CcodEqual (Join-Path $legacyRoot 'paused') $layout.PauseFile 'legacy paused marker is resolved'
            Assert-CcodEqual $true (Test-CcodRendererPaused -Layout $layout) 'legacy paused marker is honored'
        } finally {
            if ([IO.Directory]::Exists($legacyRoot)) { Remove-Item -LiteralPath $legacyRoot -Recurse -Force }
            if ($movedStandard -and [IO.Directory]::Exists($hiddenStandardRoot)) {
                Move-Item -LiteralPath $hiddenStandardRoot -Destination $root
            }
        }
    }

    Invoke-CcodTest 'prefers the standard renderer layout when both standard and legacy roots exist' {
        $legacyDirName = 'Codex' + 'Dre' + 'am' + 'Skin'
        $legacyRoot = Join-Path $localAppData $legacyDirName
        New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'engine\scripts') -Force | Out-Null
        $legacyScriptName = 'start-' + 'dre' + 'am' + '-skin.ps1'
        [IO.File]::WriteAllText((Join-Path $legacyRoot "engine\scripts\$legacyScriptName"), '# legacy fixture', [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Join-Path $root 'engine\scripts') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'engine\scripts\start-renderer.ps1'), '# standard fixture', [Text.UTF8Encoding]::new($false))
        $layout = Get-CcodRendererLayout
        Assert-CcodEqual $root $layout.Root 'standard root wins when both layouts exist'
        Assert-CcodEqual (Join-Path $root 'engine\scripts\start-renderer.ps1') $layout.StartScript 'standard start script wins'
    }

    Invoke-CcodTest 'returns null when the preferred port is occupied' {
        $adapters = New-CcodRendererAdapters -PortAvailable:$false
        Assert-CcodEqual $null (Get-CcodRendererPreferredPort -ExcludedPorts @() -Adapters $adapters) 'occupied port is never selected'
    }

    Invoke-CcodTest 'returns null when the default preferred port is excluded' {
        $adapters = New-CcodRendererAdapters -PortAvailable
        Assert-CcodEqual $null (Get-CcodRendererPreferredPort -ExcludedPorts @(9335) -Adapters $adapters) 'excluded default port is never selected'
    }

    Invoke-CcodTest 'rejects an install whose engine junction escapes the verified root' {
        $junctionRoot = Join-Path $localAppData 'JunctionRenderer'
        $outsideEngine = Join-Path $localAppData 'OutsideEngine'
        New-Item -ItemType Directory -Path (Join-Path $junctionRoot 'engine'), (Join-Path $outsideEngine 'scripts') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $outsideEngine 'scripts\start-renderer.ps1'), '# outside fixture', [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath (Join-Path $junctionRoot 'engine') -Force
        $junctionResult = & cmd.exe /c "mklink /J `"$(Join-Path $junctionRoot 'engine')`" `"$outsideEngine`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create junction fixture: $junctionResult" }
        $layout = Get-CcodRendererLayout -Root $junctionRoot
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -PortAvailable -Launches $launches
        $receipt = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodEqual $false $layout.Installed 'junction traversal makes the install unavailable'
        Assert-CcodEqual 'CCOD_RENDERER_NOT_INSTALLED' $receipt.Code 'handoff rejects an escaped start script'
        Assert-CcodEqual 0 $launches.Count 'escaped install does not launch a process'
    }

    Invoke-CcodTest 'skips handoff when the pause marker exists' {
        $pausedRoot = Join-Path $localAppData 'PausedRenderer'
        $savedRoot = $root
        $root = $pausedRoot
        New-CcodRendererFixture -Paused
        $layout = Get-CcodRendererLayout -Root $root
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -PortAvailable -Launches $launches
        $result = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodEqual 'Skipped' $result.Outcome 'pause marker prevents handoff'
        Assert-CcodEqual 'CCOD_RENDERER_PAUSED' $result.Code 'pause marker code'
        Assert-CcodEqual 0 $launches.Count 'pause marker does not launch a process'
        $root = $savedRoot
    }

    Invoke-CcodTest 'starts the official hidden handoff with port 9335' {
        $layout = Get-CcodRendererLayout -Root $root
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -PortAvailable -Launches $launches
        $result = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodPropertyOrder $result @('Outcome','Code','ProcessId') 'handoff receipt property order'
        Assert-CcodEqual 'Started' $result.Outcome 'valid install starts handoff'
        Assert-CcodEqual 'CCOD_RENDERER_HANDOFF_STARTED' $result.Code 'successful handoff code'
        Assert-CcodEqual 4242 $result.ProcessId 'process id is returned'
        Assert-CcodEqual 1 $launches.Count 'exactly one hidden process launch occurs'
        Assert-CcodEqual 'powershell.exe' $launches[0].FilePath 'hidden PowerShell hosts the official script'
        $expectedArguments = '-NoProfile,-ExecutionPolicy,Bypass,-WindowStyle,Hidden,-File,' + $layout.StartScript + ',-Port,9335'
        Assert-CcodEqual $expectedArguments ($launches[0].Arguments -join ',') 'hidden PowerShell arguments are exact'
    }

    Invoke-CcodTest 'allows handoff when the validated renderer is already listening' {
        $layout = Get-CcodRendererLayout -Root $root
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -Launches $launches
        $adapters.TestLoopbackPortAvailable = { param([int]$Port) $false }
        $adapters.ReadBrowserId = {
            param([int]$Port)
            [pscustomobject][ordered]@{
                ResponseUri = ('http://127.0.0.1:{0}/json/version' -f $Port)
                WebSocketDebuggerUrl = ('ws://127.0.0.1:{0}/devtools/browser/validated-browser' -f $Port)
            }
        }
        $result = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodEqual 'Started' $result.Outcome 'occupied validated renderer still starts handoff'
        Assert-CcodEqual 'CCOD_RENDERER_HANDOFF_STARTED' $result.Code 'occupied validated renderer handoff code'
        Assert-CcodEqual 1 $launches.Count 'occupied validated renderer launches exactly once'
    }

    Invoke-CcodTest 'default availability probe accepts an occupied validated renderer' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            $layout = Get-CcodRendererLayout -Root $root
            $launches = [Collections.Generic.List[object]]::new()
            $adapters = New-CcodRendererAdapters -Launches $launches
            [void]$adapters.Remove('TestLoopbackPortAvailable')
            $adapters.ReadBrowserId = {
                param([int]$RequestedPort)
                [pscustomobject][ordered]@{
                    ResponseUri = ('http://127.0.0.1:{0}/json/version' -f $RequestedPort)
                    WebSocketDebuggerUrl = ('ws://127.0.0.1:{0}/devtools/browser/default-adapter-browser' -f $RequestedPort)
                }
            }.GetNewClosure()
            $result = Start-CcodRendererHandoff -RendererPort $port -Layout $layout -Adapters $adapters
            Assert-CcodEqual 'Started' $result.Outcome 'default occupied-port probe allows validated renderer'
            Assert-CcodEqual 1 $launches.Count 'default occupied-port probe launches exactly once'
            Assert-CcodEqual ([string]$port) $launches[0].Arguments[-1] 'default occupied-port probe preserves renderer port'
        } finally {
            $listener.Stop()
        }
    }

    Invoke-CcodTest 'runs the complete default occupied-renderer handoff path' {
        $combinedRoot = Join-Path $localAppData 'Combined Default Handoff'
        $marker = Join-Path $combinedRoot 'received-port.txt'
        New-Item -ItemType Directory -Path (Join-Path $combinedRoot 'engine\scripts') -Force | Out-Null
        $escapedMarker = $marker.Replace("'", "''")
        $scriptText = "param([int]`$Port)`n[IO.File]::WriteAllText('$escapedMarker', [string]`$Port, [Text.UTF8Encoding]::new(`$false))"
        [IO.File]::WriteAllText((Join-Path $combinedRoot 'engine\scripts\start-renderer.ps1'), $scriptText, [Text.UTF8Encoding]::new($false))
        $reserve = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $reserve.Start()
        try { $port = ([Net.IPEndPoint]$reserve.LocalEndpoint).Port } finally { $reserve.Stop() }
        $server = Start-Job -ScriptBlock {
            param([int]$Port)
            $listener = [Net.HttpListener]::new()
            try {
                $listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $Port))
                $listener.Start()
                Write-Output 'READY'
                $context = $listener.GetContext()
                if ($context.Request.RawUrl -cne '/json/version') { throw 'unexpected request path' }
                $body = '{"Browser":"Chrome/Test","webSocketDebuggerUrl":"ws://127.0.0.1:' + $Port + '/devtools/browser/combined-default-browser"}'
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body)
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'application/json'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()
            } finally {
                if ($listener.IsListening) { $listener.Stop() }
                $listener.Close()
            }
        } -ArgumentList $port
        try {
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while ([DateTime]::UtcNow -lt $readyDeadline -and -not (@(Receive-Job -Job $server -Keep) -ccontains 'READY')) {
                if ($server.State -in @('Failed','Stopped','Completed')) { break }
                Start-Sleep -Milliseconds 50
            }
            Assert-CcodTrue (@(Receive-Job -Job $server -Keep) -ccontains 'READY') 'default HTTP fixture starts'
            $layout = Get-CcodRendererLayout -Root $combinedRoot
            $receipt = Start-CcodRendererHandoff -RendererPort $port -Layout $layout
            $markerDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $markerDeadline) { Start-Sleep -Milliseconds 50 }
            Assert-CcodEqual 'Started' $receipt.Outcome 'complete default path starts the official script'
            Assert-CcodTrue ([IO.File]::Exists($marker)) 'complete default path launches hidden PowerShell'
            Assert-CcodEqual ([string]$port) ([IO.File]::ReadAllText($marker, [Text.UTF8Encoding]::new($false))) 'complete default path preserves the occupied renderer port'
            Wait-Job -Job $server -Timeout 5 | Out-Null
            Assert-CcodEqual 'Completed' $server.State 'default HTTP fixture completes after one version request'
        } finally {
            if ($server.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $server -ErrorAction SilentlyContinue }
            Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-CcodTest 'rejects an occupied port that is not a validated renderer endpoint' {
        $layout = Get-CcodRendererLayout -Root $root
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -Launches $launches
        $adapters.TestLoopbackPortAvailable = { param([int]$Port) $false }
        $adapters.ReadBrowserId = { param([int]$Port) $null }
        $result = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodEqual 'Failed' $result.Outcome 'unknown occupied listener blocks handoff'
        Assert-CcodEqual 'CCOD_RENDERER_PORT_UNAVAILABLE' $result.Code 'unknown occupied listener code'
        Assert-CcodEqual 0 $launches.Count 'unknown occupied listener is never launched against'
    }

    Invoke-CcodTest 'passes the port to an official script below a path containing spaces' {
        $spaceRoot = Join-Path $localAppData 'External renderer With Spaces'
        $marker = Join-Path $spaceRoot 'received-port.txt'
        New-Item -ItemType Directory -Path (Join-Path $spaceRoot 'engine\scripts') -Force | Out-Null
        $escapedMarker = $marker.Replace("'", "''")
        $scriptText = "param([int]`$Port)`n[IO.File]::WriteAllText('$escapedMarker', [string]`$Port, [Text.UTF8Encoding]::new(`$false))"
        [IO.File]::WriteAllText((Join-Path $spaceRoot 'engine\scripts\start-renderer.ps1'), $scriptText, [Text.UTF8Encoding]::new($false))
        $layout = Get-CcodRendererLayout -Root $spaceRoot
        $receipt = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters @{ TestLoopbackPortAvailable = { param([int]$Port) $true } }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-CcodEqual 'Started' $receipt.Outcome 'default hidden process starts the official script'
        Assert-CcodTrue ([IO.File]::Exists($marker)) 'space-containing script path is invoked'
        Assert-CcodEqual '9335' ([IO.File]::ReadAllText($marker, [Text.UTF8Encoding]::new($false))) 'port survives the default process argument boundary'
    }

    Invoke-CcodTest 'rejects a malformed existing state before handoff' {
        $layout = Get-CcodRendererLayout -Root $root
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -StateExists -StateText '{not-json' -PortAvailable -Launches $launches
        $result = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodPropertyOrder $result @('Outcome','Code','ProcessId') 'invalid-state receipt property order'
        Assert-CcodEqual 'Failed' $result.Outcome 'malformed state blocks handoff'
        Assert-CcodEqual 'CCOD_RENDERER_STATE_INVALID' $result.Code 'malformed state code'
        Assert-CcodEqual 0 $launches.Count 'malformed state does not launch a process'
    }

    Invoke-CcodTest 'returns not installed without launching a process' {
        $layout = Get-CcodRendererLayout -Root (Join-Path $localAppData 'NoInstall')
        $launches = [Collections.Generic.List[object]]::new()
        $adapters = New-CcodRendererAdapters -PortAvailable -Launches $launches
        $result = Start-CcodRendererHandoff -RendererPort 9335 -Layout $layout -Adapters $adapters
        Assert-CcodEqual 'Skipped' $result.Outcome 'missing install skips handoff'
        Assert-CcodEqual 'CCOD_RENDERER_NOT_INSTALLED' $result.Code 'missing install code'
        Assert-CcodEqual 0 $launches.Count 'missing install does not launch a process'
    }
} catch {
    Write-Error $_
    exit 1
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path -LiteralPath $localAppData) { Remove-Item -LiteralPath $localAppData -Recurse -Force }
}
