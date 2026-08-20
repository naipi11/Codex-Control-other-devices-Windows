[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'TrayHostBuild.psm1') -Force
Invoke-CcodTrayHostBuild -RepositoryRoot $repo -Version $Version.TrimStart('v') -OutputDirectory $OutputDirectory
