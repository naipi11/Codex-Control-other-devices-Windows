[CmdletBinding()]
param(
    [switch]$ProtocolOnly,
    [switch]$NativeOnly
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($ProtocolOnly -eq $NativeOnly){throw 'CCOD_TRAYHOST_TEST_MODE_REQUIRED'}
$protocolPath=Join-Path $repositoryRoot 'src\trayhost\PipeProtocol.cs'
$presentationPath=Join-Path $repositoryRoot 'src\trayhost\PresentationSnapshot.cs'
$nativeFiles=@(
    (Join-Path $repositoryRoot 'src\trayhost\AssemblyInfo.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\NativeMethods.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\InputModeGuard.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\NativeMenu.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\TrayWindow.cs'),
    (Join-Path $repositoryRoot 'src\trayhost\TrayHostApplication.cs')
)
$testPath=if($ProtocolOnly){Join-Path $repositoryRoot 'tests\trayhost\TrayHostProtocolSelfTest.cs'}else{Join-Path $repositoryRoot 'tests\trayhost\TrayHostNativeSelfTest.cs'}
$requiredFiles=@($protocolPath,$presentationPath,$testPath)
if($NativeOnly){$requiredFiles+=$nativeFiles}
if($requiredFiles|Where-Object{ -not(Test-Path -LiteralPath $_ -PathType Leaf)}){throw 'CCOD_TRAYHOST_SOURCE_MISSING'}
Import-Module (Join-Path $repositoryRoot 'build\TrayHostReferencePack.psm1') -Force
$reference=Resolve-CcodTrayHostReferencePack -LockPath (Join-Path $repositoryRoot 'build\trayhost-packages.lock.json') -CacheRoot (Join-Path $env:TEMP 'ccod-trayhost-reference-pack')
$compilerCandidates=@((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
$compiler=$compilerCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if($null -eq $compiler){throw 'CCOD_TRAYHOST_COMPILER_MISSING'}
$temporaryRoot=Join-Path $env:TEMP ('ccod-trayhost-protocol-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporaryRoot -Force|Out-Null
try{
    $outputName=if($ProtocolOnly){'TrayHostProtocolSelfTest.exe'}else{'TrayHostNativeSelfTest.exe'}
    $mainType=if($ProtocolOnly){'TrayHostProtocolSelfTest'}else{'TrayHostNativeSelfTest'}
    $outputPath=Join-Path $temporaryRoot $outputName
    $args=@('/nologo','/noconfig','/nostdlib+','/target:exe','/platform:anycpu','/optimize+','/checked+','/warn:4','/warnaserror+',('/out:{0}' -f $outputPath),('/main:{0}' -f $mainType))
    foreach($leaf in @('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll')){$args+=('/reference:'+ (Join-Path $reference.ReferenceRoot $leaf))}
    $args+=@($protocolPath,$presentationPath)
    if($NativeOnly){$args+=$nativeFiles}
    $args+=$testPath
    & $compiler @args
    if($LASTEXITCODE -ne 0){if($ProtocolOnly){throw 'CCOD_TRAYHOST_PROTOCOL_COMPILE_FAILED'}else{throw 'CCOD_TRAYHOST_NATIVE_COMPILE_FAILED'}}
    & $outputPath
    if($LASTEXITCODE -ne 0){if($ProtocolOnly){throw 'CCOD_TRAYHOST_PROTOCOL_TEST_FAILED'}else{throw 'CCOD_TRAYHOST_NATIVE_TEST_FAILED'}}
}finally{if(Test-Path -LiteralPath $temporaryRoot){Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue}}
