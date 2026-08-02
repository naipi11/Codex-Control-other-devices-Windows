Set-StrictMode -Version Latest

function Throw-CcodError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [System.Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [System.Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetItem = { param([string]$Path) Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        UtcNow = { [DateTime]::UtcNow }
        NewGuid = { [guid]::NewGuid() }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
}

function Get-CcodPathItem {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Adapters
    )

    return & $Adapters.GetItem $Path
}

function Test-CcodNoReparseAncestor {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf,
        [hashtable]$Adapters
    )

    $rootWithoutSeparator = $Root.TrimEnd('\')
    $rootItem = Get-CcodPathItem -Path $rootWithoutSeparator -Adapters $Adapters
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-CcodError 'CCOD_REPARSE_PATH' 'Install root is a reparse point' $Root
    }

    $relative = $Path.Substring($Root.Length)
    $cursor = $rootWithoutSeparator
    foreach ($segment in ($relative -split '\\' | Where-Object { $_.Length -gt 0 })) {
        $cursor = Join-Path $cursor $segment
        try {
            $item = Get-CcodPathItem -Path $cursor -Adapters $Adapters
        } catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissingLeaf) { break }
            Throw-CcodError 'CCOD_PATH_MISSING' 'Required contained path is missing' $cursor
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-CcodError 'CCOD_REPARSE_PATH' 'Contained path is a reparse point' $cursor
        }
    }
}

function Resolve-CcodContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$AllowMissingLeaf,
        [hashtable]$Adapters
    )

    $Adapters = Get-CcodAdapters -Adapters $Adapters
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Absolute child path rejected' $RelativePath
    }

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Path escapes root' $candidate
    }

    Test-CcodNoReparseAncestor -Root $rootFull -Path $candidate -AllowMissingLeaf:$AllowMissingLeaf -Adapters $Adapters
    return $candidate
}

function Initialize-CcodNativeAtomicReplace {
    if ($null -ne ('CcodNativeAtomicReplace' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CcodNativeAtomicReplace
{
    [DllImport("kernel32.dll", EntryPoint = "ReplaceFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ReplaceFile(string replacedFileName, string replacementFileName, string backupFileName, uint replaceFlags, IntPtr exclude, IntPtr reserved);

    public static int ReplaceFileNoBackup(string targetFileName, string replacementFileName)
    {
        return ReplaceFile(targetFileName, replacementFileName, null, 0, IntPtr.Zero, IntPtr.Zero) ? 0 : Marshal.GetLastWin32Error();
    }
}
'@
}

function Get-CcodAtomicWriteAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetRandomFileName = { param([string]$Purpose) [IO.Path]::GetRandomFileName() }
        FileExists = { param([string]$Path) [IO.File]::Exists($Path) }
        CreateNewFile = { param([string]$Path) [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        ReplaceFileNoBackup = {
            param([string]$Source, [string]$Destination)
            $errorCode = [CcodNativeAtomicReplace]::ReplaceFileNoBackup($Destination, $Source)
            return [pscustomobject]@{ Success = ($errorCode -eq 0); ErrorCode = $errorCode }
        }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
}

function New-CcodAtomicOwnedFile {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Purpose,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $leaf = [string](& $Adapters.GetRandomFileName $Purpose)
        if ([string]::IsNullOrWhiteSpace($leaf) -or [IO.Path]::IsPathRooted($leaf) -or $leaf -ne [IO.Path]::GetFileName($leaf)) {
            Throw-CcodError 'CCOD_ATOMIC_NAME_INVALID' 'Atomic JSON helper supplied an unsafe sibling name' $leaf
        }
        $candidate = Join-Path $Directory $leaf
        try {
            return [pscustomobject]@{ Path = $candidate; Stream = (& $Adapters.CreateNewFile $candidate) }
        } catch [IO.IOException] {
            continue
        }
    }
    Throw-CcodError 'CCOD_ATOMIC_NAME_EXHAUSTED' 'Could not atomically claim a unique JSON sibling name' $Directory
}

function Get-CcodByteFingerprint {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [pscustomobject]@{
            Length = [int64]$Bytes.LongLength
            Sha256 = [BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
        }
    } finally {
        $sha256.Dispose()
    }
}

function Test-CcodPathMatchesFingerprint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Fingerprint,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    if (-not (& $Adapters.FileExists $Path)) { return $false }
    try {
        $actual = Get-CcodByteFingerprint -Bytes ([IO.File]::ReadAllBytes($Path))
        return $actual.Length -eq $Fingerprint.Length -and $actual.Sha256 -ceq $Fingerprint.Sha256
    } catch {
        return $false
    }
}

function Write-CcodOwnedBytes {
    param(
        [Parameter(Mandatory)]$OwnedFile,
        [Parameter(Mandatory)][byte[]]$Bytes
    )

    try {
        $OwnedFile.Stream.Write($Bytes, 0, $Bytes.Length)
        if ($OwnedFile.Stream -is [IO.FileStream]) {
            $OwnedFile.Stream.Flush($true)
        } else {
            $OwnedFile.Stream.Flush()
        }
    } finally {
        $OwnedFile.Stream.Dispose()
    }
}

function New-CcodAtomicRecoveryArtifact {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][byte[]]$OldBytes,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    $artifact = New-CcodAtomicOwnedFile -Directory $Directory -Purpose 'recovery' -Adapters $Adapters
    Write-CcodOwnedBytes -OwnedFile $artifact -Bytes $OldBytes
    return $artifact.Path
}

function Restore-CcodAtomicOldTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$OldBytes,
        [Parameter(Mandatory)]$OldFingerprint,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    try {
        $target = [pscustomobject]@{ Path = $Path; Stream = (& $Adapters.CreateNewFile $Path) }
    } catch [IO.IOException] {
        return $false
    }
    Write-CcodOwnedBytes -OwnedFile $target -Bytes $OldBytes
    return Test-CcodPathMatchesFingerprint -Path $Path -Fingerprint $OldFingerprint -Adapters $Adapters
}

function Write-CcodAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [hashtable]$Adapters
    )

    Initialize-CcodNativeAtomicReplace
    $Adapters = Get-CcodAtomicWriteAdapters -Adapters $Adapters
    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $json = ($Value | ConvertTo-Json -Depth 16) + "`n"
    $encoding = [Text.UTF8Encoding]::new($false)
    $temporary = New-CcodAtomicOwnedFile -Directory $directory -Purpose 'replacement' -Adapters $Adapters
    Write-CcodOwnedBytes -OwnedFile $temporary -Bytes $encoding.GetBytes($json)

    if (-not [IO.File]::Exists($Path)) {
        [IO.File]::Move($temporary.Path, $Path)
        return
    }

    $oldBytes = [IO.File]::ReadAllBytes($Path)
    $oldFingerprint = Get-CcodByteFingerprint -Bytes $oldBytes
    $result = & $Adapters.ReplaceFileNoBackup $temporary.Path $Path
    if ($result.Success) { return }

    if (Test-CcodPathMatchesFingerprint -Path $Path -Fingerprint $oldFingerprint -Adapters $Adapters) {
        Throw-CcodError 'CCOD_ATOMIC_REPLACE_FAILED' "Native atomic JSON replacement failed with Windows error $($result.ErrorCode); the old target remains valid" $Path
    }

    if (-not (& $Adapters.FileExists $Path) -and (Restore-CcodAtomicOldTarget -Path $Path -OldBytes $oldBytes -OldFingerprint $oldFingerprint -Adapters $Adapters)) {
        Throw-CcodError 'CCOD_ATOMIC_REPLACE_FAILED' "Native atomic JSON replacement failed with Windows error $($result.ErrorCode); the old target was restored" $Path
    }

    $artifact = New-CcodAtomicRecoveryArtifact -Directory $directory -OldBytes $oldBytes -Adapters $Adapters
    Throw-CcodError 'CCOD_ATOMIC_RECOVERY_FAILED' "Native atomic JSON replacement failed with Windows error $($result.ErrorCode); old bytes were retained in a recovery artifact" ([pscustomobject]@{ TargetPath = $Path; RecoveryArtifact = $artifact })
}

function Read-CcodStrictJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ExpectedSchema,
        [Parameter(Mandatory)][string]$Kind
    )

    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodError 'CCOD_STATE_MISSING' "Required $Kind state is missing" $Path
    }

    try {
        $value = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Throw-CcodError 'CCOD_STATE_MALFORMED' "$Kind state is not valid JSON" $Path
    }

    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        Throw-CcodError 'CCOD_STATE_MALFORMED' "$Kind state must have an object root" $Path
    }

    $schemaProperty = $value.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or $schemaProperty.Value -ne $ExpectedSchema) {
        Throw-CcodError 'CCOD_SCHEMA_UNSUPPORTED' "$Kind state has an unsupported schema" $Path
    }

    return $value
}

function Move-CcodCorruptState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Root = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexControlOtherDevices'),
        [hashtable]$Adapters
    )

    $source = [IO.Path]::GetFullPath($Path)
    $Adapters = Get-CcodAdapters -Adapters $Adapters
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $source.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-CcodError 'CCOD_PATH_OUTSIDE_ROOT' 'Corrupt state is outside the trusted root' $source
    }

    $relative = $source.Substring($rootFull.Length)
    $source = Resolve-CcodContainedPath -Root $Root -RelativePath $relative -Adapters $Adapters
    if (-not [IO.File]::Exists($source)) {
        Throw-CcodError 'CCOD_STATE_MISSING' 'Corrupt state file is missing' $source
    }

    $sourceItem = Get-CcodPathItem -Path $source -Adapters $Adapters
    if ($sourceItem.PSIsContainer) {
        Throw-CcodError 'CCOD_REPARSE_PATH' 'Corrupt state must be a regular file' $source
    }

    $directory = Split-Path -Path $source -Parent
    $utcNow = & $Adapters.UtcNow
    $newGuid = & $Adapters.NewGuid
    $destination = Join-Path $directory ((Split-Path $source -Leaf) + '.corrupt.' + $utcNow.ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.' + $newGuid.ToString('N'))
    [IO.File]::Move($source, $destination)
    return $destination
}

function Remove-CcodUnsafeLogHistory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Int64]$Limit
    )

    $directory = Split-Path -Path $Path -Parent
    $leaf = Split-Path -Path $Path -Leaf
    $pattern = '^' + [Regex]::Escape($leaf) + '\.(\d+)$'
    foreach ($item in Get-ChildItem -LiteralPath $directory -File -Force) {
        if ($item.Name -match $pattern) {
            [Int64]$generation = $Matches[1]
            if ($generation -gt 10 -or $item.Length -gt $Limit) {
                [IO.File]::Delete($item.FullName)
            }
        }
    }
}

function Write-CcodRotatingLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $limit = 2MB
    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $encoding = [Text.UTF8Encoding]::new($false)
    $entry = $Message + [Environment]::NewLine
    $entryLength = $encoding.GetByteCount($entry)
    if ($entryLength -gt $limit) {
        Throw-CcodError 'CCOD_LOG_ENTRY_TOO_LARGE' 'A single log entry exceeds the 2 MiB limit' $Path
    }
    Remove-CcodUnsafeLogHistory -Path $Path -Limit $limit

    if ([IO.File]::Exists($Path)) {
        $currentLength = (Get-Item -LiteralPath $Path).Length
        if ($currentLength -gt 0 -and ($currentLength + $entryLength -gt $limit)) {
            if ($currentLength -gt $limit) {
                [IO.File]::Delete($Path)
            } else {
                $oldest = "$Path.10"
                if ([IO.File]::Exists($oldest)) { [IO.File]::Delete($oldest) }
                for ($generation = 9; $generation -ge 1; $generation--) {
                    $source = "$Path.$generation"
                    if ([IO.File]::Exists($source)) {
                        [IO.File]::Move($source, "$Path.$($generation + 1)")
                    }
                }
                [IO.File]::Move($Path, "$Path.1")
            }
        }
    }

    [IO.File]::AppendAllText($Path, $entry, $encoding)
}

Export-ModuleMember -Function Resolve-CcodContainedPath, Read-CcodStrictJson, Write-CcodAtomicJson, Move-CcodCorruptState, Write-CcodRotatingLog
