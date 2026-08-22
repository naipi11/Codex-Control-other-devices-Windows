[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [string]$InstallRoot,
    [ValidateSet('Restart','Later')][string]$Choice,
    [switch]$PreviewChinese
)

$ErrorActionPreference = 'Stop'

function Resolve-CcodPromptLanguage {
    param([string]$Root)
    try {
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            $preferencePath = Join-Path $Root 'state\ui-preferences.json'
            if ([IO.File]::Exists($preferencePath)) {
                $preference = Get-Content -LiteralPath $preferencePath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($preference.LanguageMode -eq 'zh-CN') { return 'zh-CN' }
                if ($preference.LanguageMode -eq 'en-US') { return 'en-US' }
            }
        }
    } catch { }
    if ([Globalization.CultureInfo]::CurrentUICulture.Name -match '^zh(?:-|$)') { return 'zh-CN' }
    return 'en-US'
}

function Get-CcodRestartPromptText {
    param([string]$Language)
    if ($Language -eq 'zh-CN') {
        $localized = ('{"title":"CodexRemote-fix","message":"\u9700\u8981\u91cd\u542f Codex \u624d\u80fd\u751f\u6548\u3002\r\n\r\n\u7acb\u5373\u91cd\u542f Codex \u5417\uff1f\r\n\u9009\u62e9 Yes \u7acb\u5373\u91cd\u542f\uff0c\u9009\u62e9 No \u7a0d\u540e\u624b\u52a8\u91cd\u542f\u3002"}' | ConvertFrom-Json)
        return [pscustomobject][ordered]@{Title=[string]$localized.title;Message=[string]$localized.message}
    } else {
        return [pscustomobject][ordered]@{Title='CodexRemote-fix';Message="Codex must be restarted for the fix to take effect.`r`n`r`nRestart Codex now?`r`nChoose Yes to restart now, or No to restart it manually later."}
    }
}

function Show-CcodRestartPrompt {
    param([string]$Language)
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $text = Get-CcodRestartPromptText -Language $Language
    $result = [Windows.Forms.MessageBox]::Show(
        $text.Message,
        $text.Title,
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Information,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($result -eq [Windows.Forms.DialogResult]::Yes) { return 'Restart' }
    return 'Later'
}

$preview = if ($PreviewChinese) { Get-CcodRestartPromptText -Language 'zh-CN' } else { $null }
if ($null -ne $preview) { Write-Output $preview.Message; exit 0 }

$selected = if ([string]::IsNullOrWhiteSpace($Choice)) { Show-CcodRestartPrompt -Language (Resolve-CcodPromptLanguage -Root $InstallRoot) } else { $Choice }
if ($selected -ceq 'Later') { exit 0 }

$startScript = [IO.Path]::GetFullPath((Join-Path $AppRoot 'Start-CodexControlOtherDevices.ps1'))
if (-not [IO.File]::Exists($startScript)) { exit 1 }
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$startScript)
$null = & $powershell @arguments 2>$null
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
