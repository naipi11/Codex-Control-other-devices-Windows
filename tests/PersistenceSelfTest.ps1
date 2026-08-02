$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'persistence') -Filter '*.SelfTest.ps1' | Sort-Object Name
foreach ($test in $tests) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Persistence self-test failed: $($test.Name)" }
}
