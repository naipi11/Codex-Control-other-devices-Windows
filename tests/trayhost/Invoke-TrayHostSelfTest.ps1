[CmdletBinding()]
param(
    [switch]$ProtocolOnly
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $ProtocolOnly){throw 'CCOD_TRAYHOST_TEST_MODE_REQUIRED'}
$protocolPath=Join-Path $repositoryRoot 'src\trayhost\PipeProtocol.cs'
$presentationPath=Join-Path $repositoryRoot 'src\trayhost\PresentationSnapshot.cs'
$testPath=Join-Path $repositoryRoot 'tests\trayhost\TrayHostProtocolSelfTest.cs'
if(-not(Test-Path -LiteralPath $protocolPath -PathType Leaf) -or -not(Test-Path -LiteralPath $presentationPath -PathType Leaf) -or -not(Test-Path -LiteralPath $testPath -PathType Leaf)){throw 'CCOD_TRAYHOST_SOURCE_MISSING'}
Import-Module (Join-Path $repositoryRoot 'build\TrayHostReferencePack.psm1') -Force
$reference=Resolve-CcodTrayHostReferencePack -LockPath (Join-Path $repositoryRoot 'build\trayhost-packages.lock.json') -CacheRoot (Join-Path $env:TEMP 'ccod-trayhost-reference-pack')
$compilerCandidates=@((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
$compiler=$compilerCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if($null -eq $compiler){throw 'CCOD_TRAYHOST_COMPILER_MISSING'}
$temporaryRoot=Join-Path $env:TEMP ('ccod-trayhost-protocol-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporaryRoot -Force|Out-Null
try{
    $outputPath=Join-Path $temporaryRoot 'TrayHostProtocolSelfTest.exe'
    $args=@('/nologo','/noconfig','/nostdlib+','/target:exe','/platform:anycpu','/optimize+','/checked+','/warn:4','/warnaserror+',('/out:{0}' -f $outputPath),'/main:TrayHostProtocolSelfTest')
    foreach($leaf in @('mscorlib.dll','System.dll','System.Core.dll')){$args+=('/reference:'+ (Join-Path $reference.ReferenceRoot $leaf))}
    $args+=@($protocolPath,$presentationPath,$testPath)
    & $compiler @args
    if($LASTEXITCODE -ne 0){throw 'CCOD_TRAYHOST_PROTOCOL_COMPILE_FAILED'}
    & $outputPath
    if($LASTEXITCODE -ne 0){throw 'CCOD_TRAYHOST_PROTOCOL_TEST_FAILED'}
}finally{if(Test-Path -LiteralPath $temporaryRoot){Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue}}
