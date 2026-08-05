$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestSupport.ps1')

$repositoryRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath=Join-Path $repositoryRoot 'src\persistence\modules\UiLocalization.psm1'
if(-not [IO.File]::Exists($modulePath)){throw 'MISSING_UI_LOCALIZATION_MODULE: src\persistence\modules\UiLocalization.psm1'}
Import-Module $modulePath -Force

function New-CcodUiFixture {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('ccod-ui-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root)|Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\persistence\resources\ui.en-US.json') -Destination (Join-Path $root 'ui.en-US.json') -Force
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\persistence\resources\ui.zh-CN.json') -Destination (Join-Path $root 'ui.zh-CN.json') -Force
    return $root
}

function Set-CcodUiFixtureText {
    param([string]$Root,[string]$Name,[string]$Text)
    [IO.File]::WriteAllText((Join-Path $Root $Name),$Text,[Text.UTF8Encoding]::new($false))
}

function Get-CcodUiFixtureJson {
    param([string]$Root,[string]$Name)
    return [IO.File]::ReadAllText((Join-Path $Root $Name),[Text.UTF8Encoding]::new($false))|ConvertFrom-Json
}

function Write-CcodUiFixtureJson {
    param([string]$Root,[string]$Name,$Value)
    Set-CcodUiFixtureText $Root $Name ($Value|ConvertTo-Json -Depth 4)
}

$results=[Collections.Generic.List[object]]::new()

$results.Add((Invoke-CcodTest 'resolves exact locales and exposes a fixed catalog shape' {
    $resources=Join-Path $repositoryRoot 'src\persistence\resources'
    $en=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode en-US -SystemCultureName zh-CN
    $zh=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode zh-CN -SystemCultureName en-US
    Assert-CcodEqual 'LanguageMode,EffectiveLocale,Strings,UsedEmergencyCatalog,ErrorCode' (($en.PSObject.Properties.Name)-join ',') 'catalog has exact ordered fields'
    Assert-CcodEqual 'en-US' $en.EffectiveLocale 'explicit English wins'
    Assert-CcodEqual 'zh-CN' $zh.EffectiveLocale 'explicit Chinese wins'
    Assert-CcodEqual (($en.Strings.PSObject.Properties.Name)-join ',') (($zh.Strings.PSObject.Properties.Name)-join ',') 'catalog keys and order match'
    Assert-CcodEqual 'zh-CN' (Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode System -SystemCultureName zh-Hans).EffectiveLocale 'all zh cultures map to Chinese'
    Assert-CcodEqual 'en-US' (Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode System -SystemCultureName fr-FR).EffectiveLocale 'other cultures map to English'
    Assert-CcodThrows { Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode 'zh-cn' -SystemCultureName zh-CN } 'CCOD_UI_LANGUAGE_INVALID'
    Assert-CcodThrows { Get-CcodUiString -Catalog $en -Key 'Unknown.Key' } 'CCOD_UI_STRING_INVALID'
    Assert-CcodEqual 'Follow system (zh-CN)' (Get-CcodUiString -Catalog $en -Key 'Menu.FollowSystem' -Arguments @('zh-CN')) 'formats bounded catalog string'
}))

$results.Add((Invoke-CcodTest 'rejects malformed catalog fixtures and falls back only through validated English' {
    $resources=New-CcodUiFixture
    try {
        $base=Get-CcodUiFixtureJson $resources 'ui.zh-CN.json'
        $cases=@(
            @{Name='duplicate';Text=([IO.File]::ReadAllText((Join-Path $resources 'ui.zh-CN.json'),[Text.UTF8Encoding]::new($false)) -replace '"Tray.Title":', '"Tray.Title":"duplicate","Tray.Title":')},
            @{Name='extra';Value=([pscustomobject][ordered]@{schemaVersion=1;locale='zh-CN';strings=$base.strings;extra=$true})},
            @{Name='missing';Value=([pscustomobject][ordered]@{schemaVersion=1;locale='zh-CN'})},
            @{Name='order';Value=([pscustomobject][ordered]@{locale='zh-CN';schemaVersion=1;strings=$base.strings})},
            @{Name='schema';Value=([pscustomobject][ordered]@{schemaVersion=2;locale='zh-CN';strings=$base.strings})},
            @{Name='nonstring';Mutate={param($v)$v.strings.'Tray.Title'=1}},
            @{Name='control';Mutate={param($v)$v.strings.'Tray.Title'="bad`nvalue"}},
            @{Name='oversized';Mutate={param($v)$v.strings.'Tray.Title'=('x'*301)}},
            @{Name='malformed';Text='{'}
        )
        foreach($case in $cases){
            if($case.ContainsKey('Text')){Set-CcodUiFixtureText $resources 'ui.zh-CN.json' $case.Text}
            else {$value=$case.Value;if($null -eq $value){$value=Get-CcodUiFixtureJson $resources 'ui.zh-CN.json';& $case.Mutate $value};Write-CcodUiFixtureJson $resources 'ui.zh-CN.json' $value}
            $catalog=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode zh-CN -SystemCultureName en-US
            Assert-CcodEqual 'en-US' $catalog.EffectiveLocale "$($case.Name) selected Chinese falls back to English"
            Assert-CcodEqual $false $catalog.UsedEmergencyCatalog "$($case.Name) uses validated English"
            Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\persistence\resources\ui.zh-CN.json') -Destination (Join-Path $resources 'ui.zh-CN.json') -Force
        }
        $valid=[IO.File]::ReadAllText((Join-Path $resources 'ui.zh-CN.json'),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllBytes((Join-Path $resources 'ui.zh-CN.json'),[byte[]](@(0xef,0xbb,0xbf)+[Text.Encoding]::UTF8.GetBytes($valid)))
        $bom=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode zh-CN -SystemCultureName en-US
        Assert-CcodEqual 'en-US' $bom.EffectiveLocale 'BOM selected Chinese falls back to English'
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'src\persistence\resources\ui.zh-CN.json') -Destination (Join-Path $resources 'ui.zh-CN.json') -Force
        Set-CcodUiFixtureText $resources 'ui.zh-CN.json' '{'
        Set-CcodUiFixtureText $resources 'ui.en-US.json' '{'
        $emergency=Get-CcodUiCatalog -ResourcesRoot $resources -LanguageMode zh-CN -SystemCultureName en-US
        Assert-CcodEqual 'en-US' $emergency.EffectiveLocale 'unvalidated English uses emergency locale'
        Assert-CcodEqual $true $emergency.UsedEmergencyCatalog 'unvalidated English uses embedded emergency catalog'
        Assert-CcodEqual 'CCOD_UI_RESOURCE_INVALID' $emergency.ErrorCode 'emergency error code is stable'
    } finally {if([IO.Directory]::Exists($resources)){Remove-Item -LiteralPath $resources -Recurse -Force}}
}))

$results.Add((Invoke-CcodTest 'rejects reparse and root containment violations' {
    $resources=New-CcodUiFixture;$linkRoot=Join-Path ([IO.Path]::GetTempPath()) ('ccod-ui-link-'+[Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Junction -Path $linkRoot -Target $resources -ErrorAction Stop|Out-Null
        $catalog=Get-CcodUiCatalog -ResourcesRoot $linkRoot -LanguageMode en-US -SystemCultureName en-US
        Assert-CcodEqual $true $catalog.UsedEmergencyCatalog 'reparse English cannot be trusted'
        Assert-CcodEqual 'CCOD_UI_RESOURCE_INVALID' $catalog.ErrorCode 'reparse produces stable emergency error'
        $contained=Get-CcodUiCatalog -ResourcesRoot 'relative\resources' -LanguageMode en-US -SystemCultureName en-US
        Assert-CcodEqual $true $contained.UsedEmergencyCatalog 'relative root cannot escape to a resource'
        Assert-CcodEqual 'CCOD_UI_RESOURCE_INVALID' $contained.ErrorCode 'containment produces stable emergency error'
    } finally {if([IO.Directory]::Exists($linkRoot)){[IO.Directory]::Delete($linkRoot)};if([IO.Directory]::Exists($resources)){Remove-Item -LiteralPath $resources -Recurse -Force}}
}))

foreach($result in $results){Write-Host $(if($result.Ok){'PASS '}else{'FAIL '})$result.Name}
