[CmdletBinding()]
param(
    [ValidateSet('All','zh-CN','en-US')]
    [string]$Locale = 'All',
    [ValidateSet('All','Waiting','Active','Suppressed','Error')]
    [string]$State = 'All',
    [ValidateRange(1,600)]
    [int]$DurationSeconds = 8,
    [switch]$OpenMenu
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The tray gallery must run in a Windows PowerShell STA.'
}

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$moduleRoot = Join-Path $repositoryRoot 'src\persistence\modules'
$resourcesRoot = Join-Path $repositoryRoot 'src\persistence\resources'

Import-Module (Join-Path $moduleRoot 'UiLocalization.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'TrayUi.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot 'SupervisorEngine.psm1') -Force -ErrorAction Stop

Write-Warning 'Visual-only gallery: it does not inspect, stop, launch, or modify Codex, and it never writes preference or safety state.'
Write-Host 'Right-click the tray icon to inspect the native bilingual menu. Close this window or wait for the selected gallery sequence to finish.'

$locales = if ($Locale -ceq 'All') { @('zh-CN','en-US') } else { @($Locale) }
$allFixtures = @(
    [pscustomobject][ordered]@{
        Name = 'Waiting'; SessionState = 'Waiting'; AutomationEnabled = $true; CandidateCompatibleOptIn = $false
        HasOrdinary = $true; ControllerRunning = $false; StateDamageBlocksActions = $false; HasActiveTransaction = $false
    },
    [pscustomobject][ordered]@{
        Name = 'Active'; SessionState = 'Active'; AutomationEnabled = $true; CandidateCompatibleOptIn = $false
        HasOrdinary = $false; ControllerRunning = $false; StateDamageBlocksActions = $false; HasActiveTransaction = $false
    },
    [pscustomobject][ordered]@{
        Name = 'Suppressed'; SessionState = 'Suppressed'; AutomationEnabled = $true; CandidateCompatibleOptIn = $false
        HasOrdinary = $true; ControllerRunning = $false; StateDamageBlocksActions = $false; HasActiveTransaction = $false
    },
    [pscustomobject][ordered]@{
        Name = 'Error'; SessionState = 'Error'; AutomationEnabled = $true; CandidateCompatibleOptIn = $false
        HasOrdinary = $true; ControllerRunning = $false; StateDamageBlocksActions = $false; HasActiveTransaction = $false
    }
)
$fixtures = if ($State -ceq 'All') {
    $allFixtures
} else {
    @($allFixtures | Where-Object { $_.Name -ceq $State })
}

$commandQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$galleryAdapters = @{
    # Accept commands in memory only so menu clicks cannot mutate preference/safety state.
    TryEnqueue = { param($Queue,$Value) $true }
    # Never open a destructive confirmation from a visual gallery.
    ConfirmUninstall = { param($Title,$Message) $false }
}

foreach ($selectedLocale in $locales) {
    $context = $null
    try {
        $catalog = Get-CcodUiCatalog -ResourcesRoot $resourcesRoot -LanguageMode $selectedLocale -SystemCultureName $selectedLocale
        $context = New-CcodTrayContext `
            -CommandQueue $commandQueue `
            -OnTick {} `
            -Catalog $catalog `
            -LanguageMode $selectedLocale `
            -SystemCultureName $selectedLocale `
            -Adapters $galleryAdapters

        foreach ($fixture in $fixtures) {
            $presentation = Get-CcodTrayPresentation `
                -SessionState $fixture.SessionState `
                -AutomationEnabled $fixture.AutomationEnabled `
                -CandidateCompatibleOptIn $fixture.CandidateCompatibleOptIn `
                -HasOrdinary $fixture.HasOrdinary `
                -ControllerRunning $fixture.ControllerRunning `
                -StateDamageBlocksActions $fixture.StateDamageBlocksActions `
                -HasActiveTransaction $fixture.HasActiveTransaction
            Set-CcodTrayPresentation `
                -Context $context `
                -Presentation $presentation `
                -Catalog $catalog `
                -LanguageMode $selectedLocale `
                -SystemCultureName $selectedLocale

            Write-Host ('Gallery state: {0} | locale: {1} | {2}s' -f $fixture.Name,$selectedLocale,$DurationSeconds)
            if($OpenMenu){
                # Screenshot helper only: open the native menu without synthesizing
                # a click, and keep all command callbacks in the in-memory queue.
                $context.Menu.Show([Drawing.Point]::new(360,220))
            }
            $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        if ($null -ne $context) {
            try {
                Close-CcodTrayContext -Context $context | Out-Null
            } catch {
                Write-Warning 'Visual gallery cleanup reported a contained tray-resource error.'
            }
        }
    }
}
