$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$module = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\persistence\modules\PersistenceIO.psm1'
Import-Module $module -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-" + [guid]::NewGuid().ToString('N'))
$outside = Join-Path ([IO.Path]::GetTempPath()) ("ccod-io-outside-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root, $outside | Out-Null

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

    Invoke-CcodTest 'writes a UTF-8 JSON object without a BOM and reads its schema' {
        $path = Join-Path $root 'state\settings.json'
        Write-CcodAtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; automationEnabled = $false })
        $raw = [IO.File]::ReadAllBytes($path)
        Assert-CcodTrue ($raw.Length -gt 0 -and -not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'JSON must be UTF-8 without BOM'
        Assert-CcodEqual 1 (Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings').schemaVersion 'schema round-trip'
    }

    Invoke-CcodTest 'rejects malformed state and quarantines it beside the source' {
        $path = Join-Path $root 'state\truncated.json'
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
        [IO.File]::WriteAllText($path, '{"schemaVersion":', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Read-CcodStrictJson -Path $path -ExpectedSchema 1 -Kind 'settings' } 'CCOD_STATE_MALFORMED'
        $quarantined = Move-CcodCorruptState -Path $path -Reason 'truncated JSON'
        Assert-CcodTrue (-not [IO.File]::Exists($path)) 'corrupt source must be moved'
        Assert-CcodTrue ([IO.File]::Exists($quarantined)) 'quarantine destination must exist'
        Assert-CcodTrue ((Split-Path $quarantined -Parent) -eq (Split-Path $path -Parent)) 'quarantine must remain beside source'
        Assert-CcodTrue ((Split-Path $quarantined -Leaf) -match '^truncated\.json\.corrupt\.\d{8}T\d{6}Z\.[0-9a-f]{32}$') 'quarantine file name must be timestamped and unique'
    }

    Invoke-CcodTest 'does not quarantine a file reached through a nested junction ancestor' {
        $nested = Join-Path $outside 'nested'
        New-Item -ItemType Directory -Path $nested | Out-Null
        $path = Join-Path $root 'linked-state\nested\bad.json'
        [IO.File]::WriteAllText((Join-Path $nested 'bad.json'), '{', [Text.UTF8Encoding]::new($false))
        Assert-CcodThrows { Move-CcodCorruptState -Path $path -Reason 'nested junction' } 'CCOD_REPARSE_PATH'
    }

    Invoke-CcodTest 'rolls a log before appending after the 2 MiB limit' {
        $path = Join-Path $root 'logs\supervisor.log'
        Write-CcodRotatingLog -Path $path -Message ('x' * 2MB)
        Write-CcodRotatingLog -Path $path -Message 'after-rollover'
        $history = "$path.1"
        Assert-CcodTrue ([IO.File]::Exists($history)) 'a 2 MiB log must become generation 1 before the next append'
        Assert-CcodTrue ((Get-Content -LiteralPath $path -Raw) -match 'after-rollover') 'new message must be in the current log'
    }

    Invoke-CcodTest 'retains exactly ten log history files' {
        $path = Join-Path $root 'logs\retention.log'
        for ($i = 1; $i -le 11; $i++) {
            Write-CcodRotatingLog -Path $path -Message ('x' * 2MB)
            Write-CcodRotatingLog -Path $path -Message "rollover-$i"
        }
        $history = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File | Where-Object { $_.Name -match '^retention\.log\.\d+$' })
        Assert-CcodEqual 10 $history.Count 'exactly ten rolled log files must remain'
        Assert-CcodTrue ([IO.File]::Exists("$path.10")) 'the oldest retained generation must be 10'
        Assert-CcodTrue (-not [IO.File]::Exists("$path.11")) 'generation 11 must be removed'
    }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force }
}
