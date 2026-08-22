[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [string]$InstallRoot,
    [ValidateSet('Restart','Later')][string]$Choice,
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'

function Get-CcodRestartPromptText {
    return [pscustomobject][ordered]@{
        Title = 'CodexRemote-fix'
        Message = "Codex must be restarted for the fix to take effect.`r`n`r`nRestart Codex now?`r`nChoose Yes to restart now, or No to restart it manually later."
    }
}

function Show-CcodRestartPrompt {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $text = Get-CcodRestartPromptText
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

$previewText = if ($Preview) { Get-CcodRestartPromptText } else { $null }
if ($null -ne $previewText) { Write-Output $previewText.Message; exit 0 }

$selected = if ([string]::IsNullOrWhiteSpace($Choice)) { Show-CcodRestartPrompt } else { $Choice }
if ($selected -ceq 'Later') { exit 0 }

$startScript = [IO.Path]::GetFullPath((Join-Path $AppRoot 'Start-CodexControlOtherDevices.ps1'))
if (-not [IO.File]::Exists($startScript)) { exit 1 }
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$startScript)
$null = & $powershell @arguments 2>$null
if ($LASTEXITCODE -ne 0) { exit 1 }
exit 0
