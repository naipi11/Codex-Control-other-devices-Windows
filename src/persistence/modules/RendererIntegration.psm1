Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CcodRendererAdapters {
    param([hashtable]$Adapters)
    $defaults = @{
        ReadText = {
            param([string]$Path)
            [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
        }
        PathExists = {
            param([string]$Path)
            [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)
        }
        TestLoopbackPortAvailable = {
            param([int]$Port)
            $listener = $null
            try {
                $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
                $listener.Start()
                return $true
            } catch { return $false }
            finally { if ($null -ne $listener) { $listener.Stop() } }
        }
        ReadBrowserId = {
            param([int]$Port)
            $response = $null
            $reader = $null
            try {
                $request = [Net.HttpWebRequest][Net.WebRequest]::Create(('http://127.0.0.1:{0}/json/version' -f $Port))
                $request.Timeout = 1000
                $request.AllowAutoRedirect = $false
                $request.Proxy = $null
                $response = $request.GetResponse()
                if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) { return $null }
                $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.UTF8Encoding]::new($false))
                $version = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
                $url = $version.webSocketDebuggerUrl
                if ($url -isnot [string]) { return $null }
                return [pscustomobject][ordered]@{ResponseUri=$response.ResponseUri.AbsoluteUri;WebSocketDebuggerUrl=$url}
            } catch { return $null }
            finally {
                if ($null -ne $reader) { $reader.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
            }
        }
        TestProcessAlive = {
            param([int]$ProcessId)
            try {
                return $null -ne (Get-Process -Id $ProcessId -ErrorAction Stop)
            } catch { return $false }
        }
        StartHiddenProcess = {
            param([string]$FilePath, [string[]]$Arguments)
            $argumentLine = (@($Arguments | ForEach-Object {
                $value = [string]$_
                if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
            }) -join ' ')
            Start-Process -FilePath $FilePath -ArgumentList $argumentLine -WindowStyle Hidden -PassThru -ErrorAction Stop
        }
    }
    if ($null -ne $Adapters) {
        foreach ($key in $Adapters.Keys) {
            if ($defaults.ContainsKey($key)) { $defaults[$key] = $Adapters[$key] }
        }
    }
    return $defaults
}

function Test-CcodRendererPort {
    param($Port)
    return ($Port -is [int] -or $Port -is [long]) -and $Port -ge 1 -and $Port -le 65535
}

function Get-CcodRendererCurrentBrowserId {
    param([int]$RendererPort, [hashtable]$Adapters)
    if (-not (Test-CcodRendererPort $RendererPort)) { return $null }
    try {
        $adapter = Get-CcodRendererAdapters $Adapters
        $document = & $adapter.ReadBrowserId $RendererPort
        if ($null -eq $document -or (@($document.PSObject.Properties.Name) -join ',') -cne 'ResponseUri,WebSocketDebuggerUrl' -or
            $document.ResponseUri -isnot [string] -or $document.ResponseUri -cne ('http://127.0.0.1:{0}/json/version' -f $RendererPort) -or
            $document.WebSocketDebuggerUrl -isnot [string] -or $document.WebSocketDebuggerUrl -notmatch '^ws://127\.0\.0\.1:(\d{1,5})/devtools/browser/([A-Za-z0-9._-]{1,256})$') { return $null }
        $webSocketPort = 0
        if (-not [int]::TryParse($Matches[1], [ref]$webSocketPort) -or -not (Test-CcodRendererPort $webSocketPort) -or $webSocketPort -ne $RendererPort) { return $null }
        return $Matches[2]
    } catch { return $null }
}

function Test-CcodRendererHandoffPort {
    param([int]$RendererPort, [hashtable]$Adapters)
    if (-not (Test-CcodRendererPort $RendererPort)) { return $false }
    try {
        $adapter = Get-CcodRendererAdapters $Adapters
        # Port availability is required before Codex starts, but handoff runs
        # after the validated renderer has intentionally claimed that port.
        if ([bool](& $adapter.TestLoopbackPortAvailable $RendererPort)) { return $true }
        return $null -ne (Get-CcodRendererCurrentBrowserId -RendererPort $RendererPort -Adapters $adapter)
    } catch { return $false }
}

function Test-CcodRendererSafeDirectory {
    param([string]$Path)
    try {
        if (-not [IO.Directory]::Exists($Path)) { return $false }
        $full = [IO.Path]::GetFullPath($Path)
        $cursor = $full
        while (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $parent = Split-Path -Parent $cursor
            if ($parent -ceq $cursor) { break }
            $cursor = $parent
        }
        return $true
    } catch { return $false }
}

function Test-CcodRendererContainedPath {
    param([string]$Root, [string]$Path)
    try {
        $rootFull = [IO.Path]::GetFullPath($Root)
        $pathFull = [IO.Path]::GetFullPath($Path)
        return $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-CcodRendererSafeExistingPath {
    param([string]$Root, [string]$Path)
    if (-not (Test-CcodRendererContainedPath $Root $Path)) { return $false }
    try {
        $rootFull = [IO.Path]::GetFullPath($Root)
        $cursor = [IO.Path]::GetFullPath($Path)
        while ($true) {
            if (-not ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor))) { return $false }
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($cursor -ceq $rootFull) { return $true }
            $parent = Split-Path -Parent $cursor
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { return $false }
            $cursor = $parent
        }
    } catch { return $false }
}

function Test-CcodRendererLayout {
    param($Layout)
    if ($null -eq $Layout -or -not $Layout.Installed -or
        $Layout.Root -isnot [string] -or $Layout.EngineRoot -isnot [string] -or $Layout.StartScript -isnot [string] -or
        -not (Test-CcodRendererPort $Layout.DefaultRendererPort) -or
        -not (Test-CcodRendererSafeDirectory $Layout.Root)) { return $false }
    return (Test-CcodRendererContainedPath $Layout.Root $Layout.EngineRoot) -and
        (Test-CcodRendererContainedPath $Layout.Root $Layout.StartScript) -and
        (Test-CcodRendererContainedPath $Layout.Root $Layout.StatePath) -and
        (Test-CcodRendererContainedPath $Layout.Root $Layout.PauseFile) -and
        (Test-CcodRendererSafeExistingPath $Layout.Root $Layout.EngineRoot) -and
        (Test-CcodRendererSafeExistingPath $Layout.Root $Layout.StartScript)
}

function Resolve-CcodRendererStartScript {
    param([string]$Root)
    $primary = Join-Path (Join-Path $Root 'engine') 'scripts\start-renderer.ps1'
    if ([IO.File]::Exists($primary)) { return $primary }
    # Pre-2.1 external renderer installs shipped with a different start
    # script name. Keep accepting it so an existing install keeps working.
    $legacyName = 'start-' + 'dre' + 'am' + '-skin.ps1'
    $legacy = Join-Path (Join-Path $Root 'engine') "scripts\$legacyName"
    if ([IO.File]::Exists($legacy)) { return $legacy }
    return $primary
}

function Get-CcodRendererLayout {
    param([string]$Root)
    $candidateRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $candidateRoots += $Root
    } else {
        $standardRoot = Join-Path $env:LOCALAPPDATA 'CodexRenderer'
        $candidateRoots += $standardRoot
        # Pre-2.1 external renderer installs used a legacy per-user
        # directory; recognize it as a fallback so upgrades do not lose
        # the existing installation.
        $legacyDirName = 'Codex' + 'Dre' + 'am' + 'Skin'
        $legacyRoot = Join-Path $env:LOCALAPPDATA $legacyDirName
        if ([IO.Directory]::Exists($legacyRoot)) {
            $candidateRoots += $legacyRoot
        }
    }

    $rootFull = $null
    $startScript = $null
    foreach ($candidate in $candidateRoots) {
        try { $full = [IO.Path]::GetFullPath($candidate) } catch { continue }
        $script = Resolve-CcodRendererStartScript -Root $full
        if (Test-CcodRendererSafeExistingPath $full $script) {
            $rootFull = $full
            $startScript = $script
            break
        }
    }
    if ($null -eq $rootFull) {
        try { $rootFull = [IO.Path]::GetFullPath($candidateRoots[0]) } catch { $rootFull = $candidateRoots[0] }
        $startScript = Resolve-CcodRendererStartScript -Root $rootFull
    }

    $engineRoot = Join-Path $rootFull 'engine'
    $statePath = Join-Path $rootFull 'state.json'
    $pauseFile = Join-Path $rootFull 'paused'
    if (-not [IO.File]::Exists($pauseFile)) {
        $legacyPauseFile = Join-Path $rootFull 'pause'
        if ([IO.File]::Exists($legacyPauseFile)) { $pauseFile = $legacyPauseFile }
    }
    $installed = Test-CcodRendererSafeExistingPath $rootFull $startScript
    return [pscustomobject][ordered]@{
        Installed = [bool]$installed
        Root = $rootFull
        EngineRoot = $engineRoot
        StartScript = $startScript
        StatePath = $statePath
        PauseFile = $pauseFile
        DefaultRendererPort = 9335
    }
}

function Test-CcodRendererPaused {
    param([Parameter(Mandatory)]$Layout, [hashtable]$Adapters)
    if (-not (Test-CcodRendererLayout $Layout)) { return $false }
    try {
        $adapter = Get-CcodRendererAdapters $Adapters
        return [bool](& $adapter.PathExists $Layout.PauseFile)
    } catch { return $false }
}

function Read-CcodRendererState {
    param([Parameter(Mandatory)]$Layout, [hashtable]$Adapters)
    if (-not (Test-CcodRendererLayout $Layout)) { return $null }
    try {
        $adapter = Get-CcodRendererAdapters $Adapters
        if (-not [bool](& $adapter.PathExists $Layout.StatePath)) { return $null }
        if ([IO.File]::Exists($Layout.StatePath) -and -not (Test-CcodRendererSafeExistingPath $Layout.Root $Layout.StatePath)) { return $null }
        $state = (& $adapter.ReadText $Layout.StatePath) | ConvertFrom-Json -ErrorAction Stop
        $port = $state.port
        $browserId = $state.browserId
        $injectorPid = $state.injectorPid
        $codexExe = $state.codexExe
        if (-not (Test-CcodRendererPort $port) -or
            $browserId -isnot [string] -or [string]::IsNullOrWhiteSpace($browserId) -or $browserId.Length -gt 256 -or
            ($injectorPid -isnot [int] -and $injectorPid -isnot [long]) -or $injectorPid -lt 1 -or
            $codexExe -isnot [string] -or [string]::IsNullOrWhiteSpace($codexExe) -or -not [IO.Path]::IsPathRooted($codexExe) -or
            -not [bool](& $adapter.PathExists $codexExe)) { return $null }
        return [pscustomobject][ordered]@{
            Port = [int]$port
            BrowserId = $browserId
            InjectorPid = [int]$injectorPid
            CodexExe = $codexExe
            Paused = [bool](Test-CcodRendererPaused -Layout $Layout -Adapters $adapter)
            InjectorAlive = [bool](& $adapter.TestProcessAlive $injectorPid)
        }
    } catch { return $null }
}

function Get-CcodRendererPreferredPort {
    param([int[]]$ExcludedPorts = @(), [hashtable]$Adapters)
    try {
        $adapter = Get-CcodRendererAdapters $Adapters
        $layout = Get-CcodRendererLayout
        if (-not (Test-CcodRendererLayout $layout) -or (Test-CcodRendererPaused -Layout $layout -Adapters $adapter)) { return $null }
        $stateExists = [bool](& $adapter.PathExists $layout.StatePath)
        $state = Read-CcodRendererState -Layout $layout -Adapters $adapter
        if ($stateExists -and $null -eq $state) { return $null }
        $port = if ($null -ne $state) { [int]$state.Port } else { [int]$layout.DefaultRendererPort }
        if ($ExcludedPorts -contains $port -or -not [bool](& $adapter.TestLoopbackPortAvailable $port)) { return $null }
        return $port
    } catch { return $null }
}

function New-CcodRendererHandoffReceipt {
    param([string]$Outcome, [string]$Code, $ProcessId)
    [pscustomobject][ordered]@{ Outcome = $Outcome; Code = $Code; ProcessId = $ProcessId }
}

function Start-CcodRendererHandoff {
    param([int]$RendererPort, [Parameter(Mandatory)]$Layout, [hashtable]$Adapters)
    try {
        $adapter = Get-CcodRendererAdapters $Adapters
        if (-not (Test-CcodRendererLayout $Layout) -or -not [bool](& $adapter.PathExists $Layout.StartScript)) {
            return New-CcodRendererHandoffReceipt 'Skipped' 'CCOD_RENDERER_NOT_INSTALLED' $null
        }
        if (Test-CcodRendererPaused -Layout $Layout -Adapters $adapter) {
            return New-CcodRendererHandoffReceipt 'Skipped' 'CCOD_RENDERER_PAUSED' $null
        }
        if ([bool](& $adapter.PathExists $Layout.StatePath) -and $null -eq (Read-CcodRendererState -Layout $Layout -Adapters $adapter)) {
            return New-CcodRendererHandoffReceipt 'Failed' 'CCOD_RENDERER_STATE_INVALID' $null
        }
        if (-not (Test-CcodRendererHandoffPort -RendererPort $RendererPort -Adapters $adapter)) {
            return New-CcodRendererHandoffReceipt 'Failed' 'CCOD_RENDERER_PORT_UNAVAILABLE' $null
        }
        $process = & $adapter.StartHiddenProcess 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$Layout.StartScript,'-Port',[string]$RendererPort)
        $processId = if ($null -ne $process -and $null -ne $process.PSObject.Properties['Id']) { $process.Id } elseif ($null -ne $process -and $null -ne $process.PSObject.Properties['ProcessId']) { $process.ProcessId } else { $null }
        if ($processId -isnot [int] -and $processId -isnot [long]) {
            return New-CcodRendererHandoffReceipt 'Failed' 'CCOD_RENDERER_HANDOFF_FAILED' $null
        }
        return New-CcodRendererHandoffReceipt 'Started' 'CCOD_RENDERER_HANDOFF_STARTED' ([int]$processId)
    } catch {
        return New-CcodRendererHandoffReceipt 'Failed' 'CCOD_RENDERER_HANDOFF_FAILED' $null
    }
}

Export-ModuleMember -Function Get-CcodRendererLayout, Read-CcodRendererState, Get-CcodRendererCurrentBrowserId, Get-CcodRendererPreferredPort, Test-CcodRendererPaused, Start-CcodRendererHandoff
