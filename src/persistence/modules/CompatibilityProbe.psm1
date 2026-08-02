Set-StrictMode -Version Latest

$script:CcodExpectedFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'
$script:CcodSignatureNames = @('invertedGate', 'deviceKeyModuleReference', 'macOnlyGuard', 'windowsControllerUi')

function ConvertTo-CcodProcessArgument {
    param([Parameter(Mandatory)][string]$Argument)

    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            [void]$quoted.Append(('\' * (($backslashes * 2) + 1)))
            [void]$quoted.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$quoted.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$quoted.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$quoted.Append(('\' * ($backslashes * 2)))
    }
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-CcodExternalNode {
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $NodePath
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-CcodProcessArgument -Argument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start Node.js.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function Get-CcodProbeAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetPackage = { @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue) }
        GetFullPath = { param($Path) [IO.Path]::GetFullPath($Path) }
        GetNodeVersion = {
            param($NodePath)
            $result = Invoke-CcodExternalNode -NodePath $NodePath -Arguments @('--version')
            if ($result.ExitCode -ne 0) { throw "Node.js --version failed: $($result.Stderr)" }
            return $result.Stdout.Trim()
        }
        InvokeNode = { param($NodePath, $Arguments) Invoke-CcodExternalNode -NodePath $NodePath -Arguments $Arguments }
        JoinPath = { param($Base, $Child) Join-Path -Path $Base -ChildPath $Child }
        TestPath = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) { $resolved[$name] = $Adapters[$name] }
    }
    return $resolved
}

function New-CcodUnknownProbeResult {
    param(
        [string]$Code,
        $Identity,
        $NodeCandidate,
        [string]$Message
    )

    $identityFound = $null -ne $Identity -and $null -ne $Identity.PSObject.Properties['Found'] -and [bool]$Identity.Found
    $identityFullName = if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['FullName']) { $null } else { $Identity.FullName }
    $identityFamilyName = if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['FamilyName']) { $null } else { $Identity.FamilyName }
    $identityVersion = if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['Version']) { $null } else { $Identity.Version }
    $identityExecutable = if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['ExecutablePath']) { $null } else { $Identity.ExecutablePath }
    $identityAsar = if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['AppAsarPath']) { $null } else { $Identity.AppAsarPath }
    return [pscustomobject][ordered]@{
        Ready = $false
        Code = $Code
        Message = $Message
        SchemaVersion = $null
        StaticClassification = 'UnknownOrIncompatible'
        AffectedBuildDetected = $false
        PackageInstalled = $identityFound
        PackageFullName = $identityFullName
        PackageFamilyName = $identityFamilyName
        FamilyName = $identityFamilyName
        PackageVersion = $identityVersion
        ExecutablePath = $identityExecutable
        AppAsarPath = $identityAsar
        AppAsarSha256 = $null
        NodePath = if ($null -eq $NodeCandidate -or -not $NodeCandidate.Found) { $null } else { $NodeCandidate.Path }
        NodeVersion = if ($null -eq $NodeCandidate) { $null } else { $NodeCandidate.Version }
        NodeMajor = if ($null -eq $NodeCandidate) { $null } else { $NodeCandidate.Major }
        NodeSupported = [bool]($null -ne $NodeCandidate -and $NodeCandidate.Capabilities.Supported)
        NodeCapabilities = if ($null -eq $NodeCandidate) { [pscustomobject]@{ Supported = $false; Version = $null; Major = $null } } else { $NodeCandidate.Capabilities }
        NativeModulePresent = $false
        PackageSignatures = $null
        Signatures = $null
    }
}

function Get-CcodPackageIdentity {
    [CmdletBinding()]
    param([hashtable]$Adapters)

    $adapters = Get-CcodProbeAdapters -Adapters $Adapters
    try {
        $packages = @(& $adapters.GetPackage | Where-Object { $null -ne $_ })
        if ($packages.Count -eq 0) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_NOT_FOUND'; Message = 'The OpenAI.Codex package is not installed.' }
        }
        if ($packages.Count -ne 1) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_AMBIGUOUS'; Message = 'Expected exactly one current-user OpenAI.Codex package.' }
        }

        $package = $packages[0]
        $metadata = @{}
        foreach ($name in @('PackageFullName', 'PackageFamilyName', 'Version', 'InstallLocation')) {
            $property = $package.PSObject.Properties[$name]
            if ($null -eq $property -or $null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_METADATA_INVALID'; Message = "The installed package is missing valid $name metadata." }
            }
            $metadata[$name] = [string]$property.Value
        }
        if ($metadata.PackageFamilyName -cne $script:CcodExpectedFamilyName) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_FAMILY_MISMATCH'; Message = 'The installed package family is not the expected OpenAI.Codex package.' }
        }
        if (-not [IO.Path]::IsPathRooted($metadata.InstallLocation)) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_LOCATION_INVALID'; Message = 'The installed package does not have an absolute install location.' }
        }

        $executablePath = [string](& $adapters.JoinPath $metadata.InstallLocation 'app\ChatGPT.exe')
        $appAsarPath = [string](& $adapters.JoinPath $metadata.InstallLocation 'app\resources\app.asar')
        $nativeDirectory = [string](& $adapters.JoinPath $metadata.InstallLocation 'app\resources\native')
        if ([string]::IsNullOrWhiteSpace($executablePath) -or [string]::IsNullOrWhiteSpace($appAsarPath) -or [string]::IsNullOrWhiteSpace($nativeDirectory)) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_METADATA_INVALID'; Message = 'The installed package produced invalid resource paths.' }
        }
        if (-not (& $adapters.TestPath $executablePath)) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_EXECUTABLE_MISSING'; Message = 'The installed package executable was not found.' }
        }
        if (-not (& $adapters.TestPath $appAsarPath)) {
            return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_ASAR_MISSING'; Message = 'The installed package app.asar was not found.' }
        }
        return [pscustomobject]@{
            Found = $true
            Code = 'PACKAGE_FOUND'
            FullName = $metadata.PackageFullName
            FamilyName = $metadata.PackageFamilyName
            Version = $metadata.Version
            ExecutablePath = $executablePath
            AppAsarPath = $appAsarPath
            NativeDirectory = $nativeDirectory
        }
    } catch {
        return [pscustomobject]@{ Found = $false; StaticClassification = 'UnknownOrIncompatible'; Code = 'PACKAGE_METADATA_INVALID'; Message = 'The installed package metadata could not be validated.' }
    }
}

function Resolve-CcodNodeCandidate {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$NodeCandidates,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodProbeAdapters -Adapters $Adapters
    $lastCapabilities = [pscustomobject]@{ Supported = $false; Version = $null; Major = $null }
    foreach ($candidate in @($NodeCandidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not [IO.Path]::IsPathRooted($candidate)) { continue }
        try {
            $path = [string](& $adapters.GetFullPath $candidate)
            if (-not [IO.Path]::IsPathRooted($path) -or -not (& $adapters.TestPath $path)) { continue }
            $version = [string](& $adapters.GetNodeVersion $path)
        } catch {
            continue
        }
        $match = [regex]::Match($version.Trim(), '^v(?<major>\d+)\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')
        if (-not $match.Success) { continue }
        $major = [int]$match.Groups['major'].Value
        $capabilities = [pscustomobject]@{ Supported = $major -ge 22; Version = $version.Trim(); Major = $major }
        if (-not $capabilities.Supported) {
            $lastCapabilities = $capabilities
            continue
        }
        return [pscustomobject]@{ Found = $true; Code = 'NODE_SUPPORTED'; Path = $path; Version = $capabilities.Version; Major = $major; Capabilities = $capabilities }
    }
    return [pscustomobject]@{ Found = $false; Code = if ($null -ne $lastCapabilities.Version) { 'NODE_VERSION_UNSUPPORTED' } else { 'NODE_NOT_FOUND' }; Path = $null; Version = $lastCapabilities.Version; Major = $lastCapabilities.Major; Capabilities = $lastCapabilities }
}

function Get-CcodPackageClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CheckerState)

    $required = @('schemaVersion', 'affected', 'classification', 'appAsarSha256', 'nativeModulePresent', 'signatures')
    foreach ($name in $required) {
        if ($null -eq $CheckerState.PSObject.Properties[$name]) { return $null }
    }
    if ($CheckerState.schemaVersion -ne 1 -or
        $CheckerState.affected -isnot [bool] -or
        $CheckerState.classification -isnot [string] -or
        $CheckerState.appAsarSha256 -isnot [string] -or $CheckerState.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $CheckerState.nativeModulePresent -isnot [bool] -or
        $null -eq $CheckerState.signatures) { return $null }
    if ($CheckerState.classification -cnotin @('CandidateCompatible', 'NativeModulePresent', 'UnknownOrIncompatible')) { return $null }

    $signatures = $CheckerState.signatures
    $signatureNames = @($signatures.PSObject.Properties.Name)
    if ($signatureNames.Count -ne $script:CcodSignatureNames.Count -or @($signatureNames | Where-Object { $_ -cnotin $script:CcodSignatureNames }).Count -ne 0) { return $null }
    foreach ($name in $script:CcodSignatureNames) {
        if ($null -eq $signatures.PSObject.Properties[$name] -or $signatures.$name -isnot [bool]) { return $null }
    }
    $allSentinels = @($script:CcodSignatureNames | ForEach-Object { $signatures.$_ } | Where-Object { -not $_ }).Count -eq 0
    switch ($CheckerState.classification) {
        'CandidateCompatible' { if ($CheckerState.nativeModulePresent -or -not $CheckerState.affected -or -not $allSentinels) { return $null } }
        'NativeModulePresent' { if (-not $CheckerState.nativeModulePresent -or $CheckerState.affected) { return $null } }
        'UnknownOrIncompatible' { if ($CheckerState.nativeModulePresent -or $CheckerState.affected -or $allSentinels) { return $null } }
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        StaticClassification = $CheckerState.classification
        AffectedBuildDetected = $CheckerState.classification -ceq 'CandidateCompatible'
        Ready = $CheckerState.classification -ceq 'CandidateCompatible'
        AppAsarSha256 = $CheckerState.appAsarSha256
        NativeModulePresent = $CheckerState.nativeModulePresent
        Signatures = $signatures
        CheckerState = $CheckerState
    }
}

function Invoke-CcodStaticProbe {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$NodeCandidates,
        [Parameter(Mandatory)][string]$CheckerPath,
        [hashtable]$Adapters
    )

    $adapters = Get-CcodProbeAdapters -Adapters $Adapters
    $identity = Get-CcodPackageIdentity -Adapters $adapters
    if (-not $identity.Found) { return New-CcodUnknownProbeResult -Code $identity.Code -Identity $identity -Message $identity.Message }
    $node = Resolve-CcodNodeCandidate -NodeCandidates $NodeCandidates -Adapters $adapters
    if (-not $node.Found) { return New-CcodUnknownProbeResult -Code $node.Code -Identity $identity -NodeCandidate $node -Message 'No supported installer-verified Node.js candidate is available.' }
    if (-not [IO.Path]::IsPathRooted($CheckerPath)) { return New-CcodUnknownProbeResult -Code 'CHECKER_PATH_INVALID' -Identity $identity -NodeCandidate $node -Message 'The package checker path must be absolute.' }
    try {
        $checkerPath = [string](& $adapters.GetFullPath $CheckerPath)
        if (-not [IO.Path]::IsPathRooted($checkerPath) -or -not (& $adapters.TestPath $checkerPath)) {
            return New-CcodUnknownProbeResult -Code 'CHECKER_NOT_FOUND' -Identity $identity -NodeCandidate $node -Message 'The package checker was not found.'
        }
        $process = & $adapters.InvokeNode $node.Path @($checkerPath, $identity.AppAsarPath, $identity.NativeDirectory)
        if ($null -eq $process -or $process.ExitCode -ne 0) {
            return New-CcodUnknownProbeResult -Code 'CHECKER_FAILED' -Identity $identity -NodeCandidate $node -Message 'The package checker did not complete successfully.'
        }
        $stdout = [string]$process.Stdout
        if ($stdout -notmatch '^\s*\{[\s\S]*\}\s*$') {
            return New-CcodUnknownProbeResult -Code 'CHECKER_JSON_INVALID' -Identity $identity -NodeCandidate $node -Message 'The package checker did not emit exactly one JSON object.'
        }
        $checkerState = $stdout | ConvertFrom-Json -ErrorAction Stop
        if (@($checkerState).Count -ne 1) {
            return New-CcodUnknownProbeResult -Code 'CHECKER_JSON_INVALID' -Identity $identity -NodeCandidate $node -Message 'The package checker did not emit exactly one JSON object.'
        }
        $classification = Get-CcodPackageClassification -CheckerState $checkerState
        if ($null -eq $classification) {
            return New-CcodUnknownProbeResult -Code 'CHECKER_SCHEMA_INVALID' -Identity $identity -NodeCandidate $node -Message 'The package checker emitted an incomplete or inconsistent schema.'
        }
    } catch {
        return New-CcodUnknownProbeResult -Code 'CHECKER_JSON_INVALID' -Identity $identity -NodeCandidate $node -Message 'The package checker emitted malformed JSON.'
    }

    return [pscustomobject][ordered]@{
        Ready = $classification.Ready
        Code = 'CHECKER_OK'
        Message = $null
        SchemaVersion = $classification.SchemaVersion
        StaticClassification = $classification.StaticClassification
        AffectedBuildDetected = $classification.AffectedBuildDetected
        PackageInstalled = $true
        PackageFullName = $identity.FullName
        PackageFamilyName = $identity.FamilyName
        FamilyName = $identity.FamilyName
        PackageVersion = $identity.Version
        ExecutablePath = $identity.ExecutablePath
        AppAsarPath = $identity.AppAsarPath
        AppAsarSha256 = $classification.AppAsarSha256
        NodePath = $node.Path
        NodeVersion = $node.Version
        NodeMajor = $node.Major
        NodeSupported = $node.Capabilities.Supported
        NodeCapabilities = $node.Capabilities
        NativeModulePresent = $classification.NativeModulePresent
        PackageSignatures = $classification.CheckerState
        Signatures = $classification.Signatures
    }
}

Export-ModuleMember -Function Get-CcodPackageIdentity, Resolve-CcodNodeCandidate, Invoke-CcodStaticProbe, Get-CcodPackageClassification
