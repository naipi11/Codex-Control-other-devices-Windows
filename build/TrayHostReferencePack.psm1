Set-StrictMode -Version Latest

function Throw-CcodTrayHostBuildError {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][string]$Message)
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),$Code,[Management.Automation.ErrorCategory]::InvalidData,$null
    )
}

function Get-CcodTrayHostPackageHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha=[Security.Cryptography.SHA512]::Create()
    try{
        $bytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
        return [Convert]::ToBase64String($sha.ComputeHash($bytes))
    }finally{$sha.Dispose()}
}

function Resolve-CcodTrayHostReferencePack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$CacheRoot,
        [hashtable]$Adapters
    )
    $lock=Get-Content -LiteralPath ([IO.Path]::GetFullPath($LockPath)) -Raw -ErrorAction Stop|ConvertFrom-Json
    if($null -eq $lock -or [int]$lock.schemaVersion -ne 1 -or @($lock.packages).Count -ne 1){Throw-CcodTrayHostBuildError 'CCOD_TRAYHOST_REFERENCE_LOCK_INVALID' 'TrayHost reference lock is invalid.'}
    $package=@($lock.packages)[0]
    if([string]$package.id -cne 'Microsoft.NETFramework.ReferenceAssemblies.net48' -or [string]$package.version -cne '1.0.3' -or [string]$package.sha512 -cne 'XWKgyeNadNcTQaIVvQB8BrdCNrEar6fo/de1OdQRZ9HFy0jcBSaM8IV5q64ZampsSnC8AlTsACaGZUuoFw41RA=='){
        Throw-CcodTrayHostBuildError 'CCOD_TRAYHOST_REFERENCE_LOCK_INVALID' 'TrayHost reference package lock does not match the approved net48 package.'
    }
    $cache=[IO.Path]::GetFullPath($CacheRoot)
    $packageRoot=Join-Path $cache 'Microsoft.NETFramework.ReferenceAssemblies.net48\1.0.3'
    $referenceRoot=Join-Path $packageRoot 'build\.NETFramework\v4.8'
    $required=@('mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll')
    if(-not (Test-Path -LiteralPath $referenceRoot -PathType Container)){
        $download=Join-Path $cache 'microsoft.netframework.referenceassemblies.net48.1.0.3.nupkg'
        New-Item -ItemType Directory -Path $cache -Force|Out-Null
        if(-not (Test-Path -LiteralPath $download -PathType Leaf)){
            $uri='https://api.nuget.org/v3-flatcontainer/microsoft.netframework.referenceassemblies.net48/1.0.3/microsoft.netframework.referenceassemblies.net48.1.0.3.nupkg'
            Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $download
        }
        if((Get-CcodTrayHostPackageHash $download)-cne [string]$package.sha512){Throw-CcodTrayHostBuildError 'CCOD_TRAYHOST_REFERENCE_HASH_MISMATCH' 'TrayHost reference package hash does not match the lock.'}
        $extract=Join-Path $cache ('.extract-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $extract -Force|Out-Null
        try{$archive=Join-Path $extract 'package.zip';Copy-Item -LiteralPath $download -Destination $archive -Force;Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force;$target=Join-Path $extract 'build\.NETFramework\v4.8';if(-not(Test-Path $target -PathType Container)){Throw-CcodTrayHostBuildError 'CCOD_TRAYHOST_REFERENCE_MISSING' 'Locked package has no net48 reference directory.'};New-Item -ItemType Directory -Path (Split-Path $referenceRoot -Parent) -Force|Out-Null;Move-Item -LiteralPath $target -Destination $referenceRoot -Force}finally{if(Test-Path $extract){Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue}}
    }
    foreach($leaf in $required){$path=Join-Path $referenceRoot $leaf;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){Throw-CcodTrayHostBuildError 'CCOD_TRAYHOST_REFERENCE_MISSING' "Locked net48 reference is missing: $leaf"}}
    return [pscustomobject][ordered]@{PackageId=[string]$package.id;Version=[string]$package.version;Sha512=[string]$package.sha512;ReferenceRoot=$referenceRoot;RequiredFiles=[object[]]@($required)}
}

Export-ModuleMember -Function Resolve-CcodTrayHostReferencePack
