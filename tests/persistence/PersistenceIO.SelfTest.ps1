$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$module = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\persistence\modules\PersistenceIO.psm1'
Import-Module $module -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-" + [guid]::NewGuid().ToString('N'))
$outside = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-outside-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root, $outside | Out-Null
$fixedUtc = [DateTime]::Parse('2030-02-03T04:05:06Z').ToUniversalTime()
$fixedGuid = [guid]'01234567-89ab-cdef-0123-456789abcdef'
$deterministicAdapters = @{
    UtcNow = { $fixedUtc }
    NewGuid = { $fixedGuid }
}

try {
    Invoke-CcodTest 'rejects a relative path that escapes the install root' {
        Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath '..\escape.json' } 'CCOD_PATH_OUTSIDE_ROOT'
    }

    Invoke-CcodTest 'rejects an existing junction ancestor' {
        $junction = Join-Path $root 'linked-state'
        $result = & cmd.exe /c "mklink /J `"$junction`" `"$outside`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not create junction for containment test: $result" }
        Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath 'linked-state\settings.json' -AllowMissingLeaf } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'rejects a dangling reparse ancestor supplied by the item adapter' {
        $dangling = Join-Path $root 'dangling-state'
        $danglingFull = [IO.Path]::GetFullPath($dangling)
        $adapters = @{
            GetItem = {
                param([string]$Path)
                if ([IO.Path]::GetFullPath($Path) -eq $danglingFull) {
                    return [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $true }
                }
                Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
        }
        Assert-CcodThrows { Resolve-CcodContainedPath -Root $root -RelativePath 'dangling-state\settings.json' -AllowMissingLeaf -Adapters $adapters } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'writes a UTF-8 JSON object without a BOM and reads its schema' {
        $path = Join-Path $root 'state\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; automationEnabled = $false })
        $raw = [IO.File]::ReadAllBytes($path)
        Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'JSON must be UTF-8 without BOM'
        Assert-CcodEqual 1 (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').schemaVersion 'schema round-trip'
    }

    Invoke-CcodTest 'atomically replaces an existing JSON file without temporary or backup leftovers' {
        $path = Join-Path $root 'replace\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' })
        $raw = [IO.File]::ReadAllBytes($path)
        $value = Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings'
        $siblings = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Force)
        Assert-CcodEqual 'after' $value.value 'replacement must expose the second JSON value'
        Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'replacement JSON must remain UTF-8 without BOM'
        Assert-CcodEqual 1 $siblings.Count 'replacement must not leave temporary or backup siblings'
        Assert-CcodEqual 'settings.json' $siblings[0].Name 'replacement must leave only the target file'
    }

    Invoke-CcodTest 'preserves a colliding non-owned backup and the old target when replacement fails' {
        $path = Join-Path $root 'replace-collision\settings.json'
        $directory = Split-Path $path -Parent
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $collision = Join-Path $directory 'non-owned-backup.json'
        [IO.File]::WriteAllText($collision, 'do not delete', [Text.UTF8Encoding]::new($false))
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $backupNames = [System.Collections.Generic.Queue[string]]::new()
        $backupNames.Enqueue('non-owned-backup.json')
        $backupNames.Enqueue('owned-backup.json')
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'temporary') { return 'controlled-temporary.json' }
                return $backupNames.Dequeue()
            }
            ReplaceFile = {
                param([string]$Source, [string]$Destination, [string]$Backup)
                throw [InvalidOperationException]::new('controlled replacement failure')
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_RECOVERY_FAILED'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'failed replacement must retain the old target bytes'
        Assert-CcodEqual 'do not delete' ([IO.File]::ReadAllText($collision, [Text.UTF8Encoding]::new($false))) 'a colliding non-owned backup must remain untouched'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $directory 'controlled-temporary.json'))) 'failed replacement must remove only its temporary file'
        Assert-CcodTrue ([IO.File]::Exists((Join-Path $directory 'owned-backup.json'))) 'an unverified owned backup must remain for fail-closed inspection'
    }

    Invoke-CcodTest 'restores the old target when a replacement failure leaves only its backup' {
        $path = Join-Path $root 'replace-recovery\settings.json'
        $directory = Split-Path $path -Parent
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'temporary') { return 'recovery-temporary.json' }
                return 'recovery-backup.json'
            }
            ReplaceFile = {
                param([string]$Source, [string]$Destination, [string]$Backup)
                [IO.File]::Copy($Destination, $Backup, $true)
                [IO.File]::Delete($Destination)
                throw [InvalidOperationException]::new('controlled replacement failure after backup')
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_REPLACE_FAILED'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'failed replacement must restore the old target from its backup'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $directory 'recovery-temporary.json'))) 'recovered failure must remove its temporary file'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $directory 'recovery-backup.json'))) 'restored backup must not remain after recovery'
    }

    Invoke-CcodTest 'restores the old target when replacement writes new bytes before failing' {
        $path = Join-Path $root 'replace-partial\settings.json'
        $directory = Split-Path $path -Parent
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'temporary') { return 'partial-temporary.json' }
                return 'partial-backup.json'
            }
            ReplaceFile = {
                param([string]$Source, [string]$Destination, [string]$Backup)
                [IO.File]::Copy($Destination, $Backup, $true)
                [IO.File]::Copy($Source, $Destination)
                throw [InvalidOperationException]::new('controlled replacement failure after target write')
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_REPLACE_FAILED'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'failed replacement must restore the old target after a partial target write'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $directory 'partial-temporary.json'))) 'partial failure must remove its temporary file'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $directory 'partial-backup.json'))) 'partial failure must consume its restored backup'
    }

    Invoke-CcodTest 'fails closed when a backup path is raced after the absence check' {
        $path = Join-Path $root 'replace-race\settings.json'
        $directory = Split-Path $path -Parent
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $racedBackup = Join-Path $directory 'raced-backup.json'
        $backupNames = [System.Collections.Generic.Queue[string]]::new()
        $backupNames.Enqueue('raced-backup.json')
        $backupNames.Enqueue('owned-backup.json')
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'temporary') { return 'race-temporary.json' }
                return $backupNames.Dequeue()
            }
            FileExists = {
                param([string]$Candidate)
                if ($Candidate -eq $racedBackup -and -not [IO.File]::Exists($Candidate)) {
                    [IO.File]::WriteAllText($Candidate, 'foreign backup bytes', [Text.UTF8Encoding]::new($false))
                    return $false
                }
                return [IO.File]::Exists($Candidate)
            }
            CreateNewFile = {
                param([string]$Candidate)
                if ($Candidate -eq $racedBackup -and -not [IO.File]::Exists($Candidate)) {
                    [IO.File]::WriteAllText($Candidate, 'foreign backup bytes', [Text.UTF8Encoding]::new($false))
                    throw [IO.IOException]::new('controlled backup claim collision')
                }
                return [IO.FileStream]::new($Candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            }
            ReplaceFile = {
                param([string]$Source, [string]$Destination, [string]$Backup)
                throw [InvalidOperationException]::new('controlled replacement failure')
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_RECOVERY_FAILED'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'raced backup must not overwrite the old target'
        Assert-CcodEqual 'foreign backup bytes' ([IO.File]::ReadAllText($racedBackup, [Text.UTF8Encoding]::new($false))) 'raced non-owned backup must not be deleted or moved'
        Assert-CcodTrue (-not [IO.File]::Exists((Join-Path $directory 'race-temporary.json'))) 'raced failure must remove only the owned temporary file'
    }

    Invoke-CcodTest 'does not call replacement after an owned backup placeholder is replaced' {
        $path = Join-Path $root 'replace-placeholder-race\settings.json'
        $directory = Split-Path $path -Parent
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'before' })
        $replaceState = [pscustomobject]@{ Called = $false }
        $adapters = @{
            GetRandomFileName = {
                param([string]$Purpose)
                if ($Purpose -eq 'temporary') { return 'placeholder-temporary.json' }
                return 'placeholder-backup.json'
            }
            BeforeReplace = {
                param([string]$Backup)
                [IO.File]::WriteAllText($Backup, 'foreign replacement', [Text.UTF8Encoding]::new($false))
            }
            ReplaceFile = {
                param([string]$Source, [string]$Destination, [string]$Backup)
                $replaceState.Called = $true
                throw [InvalidOperationException]::new('replacement must not be called after placeholder ownership loss')
            }
        }

        Assert-CcodThrows { Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; value = 'after' }) -Adapters $adapters } 'CCOD_ATOMIC_RECOVERY_FAILED'
        Assert-CcodEqual $false $replaceState.Called 'placeholder ownership loss must stop before replacement'
        Assert-CcodEqual 'before' (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').value 'placeholder ownership loss must retain the old target'
        Assert-CcodEqual 'foreign replacement' ([IO.File]::ReadAllText((Join-Path $directory 'placeholder-backup.json'), [Text.UTF8Encoding]::new($false))) 'untrusted replacement of the placeholder must remain untouched'
    }

    Invoke-CcodTest 'rejects malformed state and quarantines it beside the source' {
        $path = Join-Path $root 'state\truncated.json'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText($path, '{"schemaVersion":', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings' } 'CCOD_STATE_MALFORMED'
        $quarantined = Move-CcodCorruptState -Path $path -Reason 'truncated JSON' -Root $root -Adapters $deterministicAdapters
        Assert-CcodTrue (-not [IO.File]::Exists($path)) 'corrupt source must be moved'
        Assert-CcodTrue ([IO.File]::Exists($quarantined)) 'quarantine destination must exist'
        Assert-CcodTrue ((Split-Path $quarantined -Parent) -eq (Split-Path $path -Parent)) 'quarantine must remain beside source'
        Assert-CcodEqual 'truncated.json.corrupt.20300203T040506Z.0123456789abcdef0123456789abcdef' (Split-Path $quarantined -Leaf) 'quarantine name must use injected UTC clock and GUID'
    }

    Invoke-CcodTest 'refuses to quarantine an ordinary file outside the trusted root' {
        $path = Join-Path $outside 'unmanaged.json'
        [IO.File]::WriteAllText($path, '{', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Move-CcodCorruptState -Path $path -Reason 'outside root' -Root $root -Adapters $deterministicAdapters } 'CCOD_PATH_OUTSIDE_ROOT'
        Assert-CcodTrue ([IO.File]::Exists($path)) 'outside-root source must not be moved'
    }

    Invoke-CcodTest 'does not quarantine a file reached through a nested junction ancestor' {
        $nested = Join-Path $outside 'nested'
        New-Item -ItemType Directory -Path $nested | Out-Null
        $path = Join-Path $root 'linked-state\nested\bad.json'
        [IO.File]::WriteAllText((Join-Path $nested 'bad.json'), '{', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Move-CcodCorruptState -Path $path -Reason 'nested junction' -Root $root } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'rejects a first log entry that would exceed 2 MiB' {
        $path = Join-Path $root 'logs\oversized-first.log'
        Assert-CcodThrows { Write-CcodRotatingLog -Path $path -Message ('x' * 2MB) } 'CCOD_LOG_ENTRY_TOO_LARGE'
        Assert-CcodTrue (-not [IO.File]::Exists($path)) 'an oversized first entry must not create a log'
    }

    Invoke-CcodTest 'rolls a log before appending after the 2 MiB limit' {
        $path = Join-Path $root 'logs\supervisor.log'
        Write-CcodRotatingLog -Path $path -Message ('x' * (2MB - 2))
        Write-CcodRotatingLog -Path $path -Message 'after-rollover'
        $history = "$path.1"
        Assert-CcodTrue ([IO.File]::Exists($history)) 'a 2 MiB log must become generation 1 before the next append'
        Assert-CcodTrue ((Get-Content -LiteralPath $path -Raw) -match 'after-rollover') 'new message must be in the current log'
    }

    Invoke-CcodTest 'retains exactly ten log history files' {
        $path = Join-Path $root 'logs\retention.log'
        for ($i = 1; $i -le 11; $i++) {
            Write-CcodRotatingLog -Path $path -Message ('x' * (2MB - 2))
            Write-CcodRotatingLog -Path $path -Message "rollover-$i"
        }
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^retention\.log\.\d+$' })
        Assert-CcodEqual 10 $history.Count 'exactly ten rolled log files must remain'
        Assert-CcodTrue ([IO.File]::Exists("$path.10")) 'the oldest retained generation must be 10'
        Assert-CcodTrue (-not [IO.File]::Exists("$path.11")) 'generation 11 must be removed'
    }

    Invoke-CcodTest 'removes stale oversized and older log generations before a successful append' {
        $path = Join-Path $root 'logs\stale-history.log'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText("$path.1", ('x' * (2MB + 1)), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$path.11", 'old generation', [Text.UTF8Encoding]::new($false))
        Write-CcodRotatingLog -Path $path -Message 'safe append'
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^stale-history\.log\.\d+$' })
        Assert-CcodTrue (-not [IO.File]::Exists("$path.1")) 'oversized history generation must be removed'
        Assert-CcodTrue (-not [IO.File]::Exists("$path.11")) 'generation older than ten must be removed'
        Assert-CcodTrue (@($history | Where-Object { $_.Length -gt 2MB }).Count -eq 0) 'all retained history must be at most 2 MiB'
    }

    Invoke-CcodTest 'does not preserve an already oversized current log as history' {
        $path = Join-Path $root 'logs\oversized-current.log'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText($path, ('x' * (2MB + 1)), [Text.UTF8Encoding]::new($false))
        Write-CcodRotatingLog -Path $path -Message 'fresh bounded entry'
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^oversized-current\.log\.\d+$' })
        Assert-CcodTrue ((Get-Item -LiteralPath $path).Length -le 2MB) 'current log must be at most 2 MiB'
        Assert-CcodTrue (@($history | Where-Object { $_.Length -gt 2MB }).Count -eq 0) 'history must not retain the oversized current log'
        Assert-CcodTrue ((Get-Content -LiteralPath $path -Raw) -match 'fresh bounded entry') 'successful append must create a bounded current log'
    }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
}
