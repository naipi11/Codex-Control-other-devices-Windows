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

function Get-CcodAtomicWriteAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetRandomFileName = { param([string]$Purpose) [IO.Path]::GetRandomFileName() }
        FileExists = { param([string]$Path) [IO.File]::Exists($Path) }
        DeleteFile = { param([string]$Path) [IO.File]::Delete($Path) }
        MoveFile = { param([string]$Source, [string]$Destination) [IO.File]::Move($Source, $Destination) }
        CopyFile = { param([string]$Source, [string]$Destination) [IO.File]::Copy($Source, $Destination, $true) }
        CreateNewFile = { param([string]$Path) [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        BeforeReplace = { param([string]$Backup) }
        ReplaceFile = { param([string]$Source, [string]$Destination, [string]$Backup) [IO.File]::Replace($Source, $Destination, $Backup, $true) }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) {
            $resolved[$name] = $Adapters[$name]
        }
    }
    return $resolved
}

function Get-CcodAtomicUnusedSiblingPath {
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
        if (-not (& $Adapters.FileExists $candidate)) {
            return $candidate
        }
    }
    Throw-CcodError 'CCOD_ATOMIC_NAME_EXHAUSTED' 'Could not allocate a unique atomic JSON sibling name' $Directory
}

function New-CcodAtomicBackupPlaceholder {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $leaf = [string](& $Adapters.GetRandomFileName 'backup')
        if ([string]::IsNullOrWhiteSpace($leaf) -or [IO.Path]::IsPathRooted($leaf) -or $leaf -ne [IO.Path]::GetFileName($leaf)) {
            Throw-CcodError 'CCOD_ATOMIC_NAME_INVALID' 'Atomic JSON helper supplied an unsafe sibling name' $leaf
        }
        $candidate = Join-Path $Directory $leaf
        $stream = $null
        try {
            $stream = & $Adapters.CreateNewFile $candidate
        } catch [IO.IOException] {
            continue
        }
        try {
            $marker = [Text.Encoding]::UTF8.GetBytes('CCOD-atomic-backup-' + [guid]::NewGuid().ToString('N'))
            $stream.Write($marker, 0, $marker.Length)
            if ($stream -is [IO.FileStream]) {
                $stream.Flush($true)
            } else {
                $stream.Flush()
            }
            $stream.Dispose()
            $stream = $null
            return [pscustomobject]@{
                Path = $candidate
                PlaceholderFingerprint = Get-CcodFileFingerprint -Path $candidate
            }
        } catch {
            if (& $Adapters.FileExists $candidate) { & $Adapters.DeleteFile $candidate }
            throw
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    Throw-CcodError 'CCOD_ATOMIC_NAME_EXHAUSTED' 'Could not atomically claim a unique backup name' $Directory
}

function Get-CcodFileFingerprint {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return [pscustomobject]@{
        Length = [int64]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
}

function Test-CcodFileFingerprint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Fingerprint,
        [Parameter(Mandatory)][hashtable]$Adapters
    )

    if (-not (& $Adapters.FileExists $Path)) { return $false }
    try {
        $actual = Get-CcodFileFingerprint -Path $Path
        return $actual.Length -eq $Fingerprint.Length -and $actual.Sha256 -ceq $Fingerprint.Sha256
    } catch {
        return $false
    }
}

function Write-CcodAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [hashtable]$Adapters
    )

    $Adapters = Get-CcodAtomicWriteAdapters -Adapters $Adapters
    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Get-CcodAtomicUnusedSiblingPath -Directory $directory -Purpose 'temporary' -Adapters $Adapters
    $backup = $null
    $temporaryOwned = $false
    $backupOwned = $false
    $backupConsumable = $false
    $replaceCompleted = $false
    try {
        $json = ($Value | ConvertTo-Json -Depth 16) + "`n"
        $encoding = [Text.UTF8Encoding]::new($false)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $temporaryOwned = $true
        try {
            $writer = [IO.StreamWriter]::new($stream, $encoding)
            try {
                $writer.Write($json)
                $writer.Flush()
                $stream.Flush($true)
            } finally {
                $writer.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        if ([IO.File]::Exists($Path)) {
            $oldTarget = Get-CcodFileFingerprint -Path $Path
            $backupClaim = New-CcodAtomicBackupPlaceholder -Directory $directory -Adapters $Adapters
            $backup = $backupClaim.Path
            $backupOwned = $true
            & $Adapters.BeforeReplace $backup
            if (-not (Test-CcodFileFingerprint -Path $backup -Fingerprint $backupClaim.PlaceholderFingerprint -Adapters $Adapters)) {
                Throw-CcodError 'CCOD_ATOMIC_RECOVERY_FAILED' 'Atomic JSON backup placeholder ownership cannot be verified before replacement' $backup
            }
            try {
                & $Adapters.ReplaceFile $temporary $Path $backup
                $replaceCompleted = $true
                $temporaryOwned = $false
                if (-not (Test-CcodFileFingerprint -Path $backup -Fingerprint $oldTarget -Adapters $Adapters)) {
                    Throw-CcodError 'CCOD_ATOMIC_RECOVERY_FAILED' 'Atomic JSON replacement backup cannot be verified as the old target' $backup
                }
                $backupConsumable = $true
            } catch {
                if ($backupOwned -and (Test-CcodFileFingerprint -Path $backup -Fingerprint $oldTarget -Adapters $Adapters)) {
                    try {
                        if (& $Adapters.FileExists $Path) {
                            & $Adapters.CopyFile $backup $Path
                            & $Adapters.DeleteFile $backup
                        } else {
                            & $Adapters.MoveFile $backup $Path
                        }
                    } catch {
                        Throw-CcodError 'CCOD_ATOMIC_RECOVERY_FAILED' 'Atomic JSON replacement failed and the old target could not be restored' $Path
                    }
                } elseif ($backupOwned) {
                    Throw-CcodError 'CCOD_ATOMIC_RECOVERY_FAILED' 'Atomic JSON replacement failed and its backup cannot be verified as the old target' $backup
                }
                Throw-CcodError 'CCOD_ATOMIC_REPLACE_FAILED' 'Atomic JSON replacement failed; the old target was preserved or restored' $Path
            }
        } else {
            [IO.File]::Move($temporary, $Path)
            $temporaryOwned = $false
        }
    } finally {
        if ($temporaryOwned -and (& $Adapters.FileExists $temporary)) { & $Adapters.DeleteFile $temporary }
        if ($replaceCompleted -and $backupOwned -and $backupConsumable -and (& $Adapters.FileExists $backup)) { & $Adapters.DeleteFile $backup }
    }
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
