[CmdletBinding()]
param(
    [switch]$SelfTest,
    [ValidateRange(1, 100)][int]$Trials = 50
)

$ErrorActionPreference = 'Stop'
$spikeRoot = $PSScriptRoot
$repositoryRoot = Split-Path (Split-Path (Split-Path $spikeRoot -Parent) -Parent) -Parent
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -eq $compiler) { throw 'CCOD_SPIKE_COMPILER_MISSING' }

$sourcePath = Join-Path $spikeRoot 'NoHimcSpike.cs'
$testPath = Join-Path $spikeRoot 'NoHimcSpikeSelfTest.cs'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or ($SelfTest -and -not (Test-Path -LiteralPath $testPath -PathType Leaf))) {
    throw 'CCOD_SPIKE_SOURCE_MISSING'
}

$temporaryRoot = Join-Path $env:TEMP ('ccod-nohimc-spike-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $outputPath = Join-Path $temporaryRoot 'NoHimcSpike.exe'
    $reportPath = Join-Path $temporaryRoot 'spike-report.json'
    $compileSources = @($sourcePath)
    if ($SelfTest) { $compileSources += $testPath }
    $references = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\mscorlib.dll'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.dll'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.Core.dll')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $arguments = @('/nologo','/noconfig','/nostdlib+','/target:exe','/platform:anycpu','/optimize+','/checked+','/warn:4','/warnaserror+',('/out:{0}' -f $outputPath))
    if ($SelfTest) { $arguments += '/main:NoHimcSpikeSelfTest' }
    $arguments += ($references | ForEach-Object { '/reference:' + $_ })
    $arguments += $compileSources
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw 'CCOD_SPIKE_COMPILE_FAILED' }
    if ($SelfTest) {
        & $outputPath '--self-test'
        if ($LASTEXITCODE -ne 0) { throw 'CCOD_SPIKE_SELF_TEST_FAILED' }
    } else {
        & $outputPath '--manual' ([string]$Trials) $reportPath
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Get-Content -LiteralPath $reportPath -Raw }
            throw 'CCOD_SPIKE_MANUAL_FAILED'
        }
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'CCOD_SPIKE_REPORT_MISSING' }
        Get-Content -LiteralPath $reportPath -Raw
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
