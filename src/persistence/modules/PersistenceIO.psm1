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

function Write-CcodAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $directory = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName())
    try {
        $json = ($Value | ConvertTo-Json -Depth 16) + "`n"
        $encoding = [Text.UTF8Encoding]::new($false)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
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
            [IO.File]::Replace($temporary, $Path, $null, $true)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
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
