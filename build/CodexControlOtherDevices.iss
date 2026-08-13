[Setup]
AppId={{2B9E9F2E-7A32-4A7E-9C1D-9F5B5C6D7E8F}
AppName=Codex Control other devices for Windows
AppVersion={#ProjectVersion}
AppVerName=Codex Control other devices for Windows {#ProjectVersion}
AppPublisher=naipi11
AppPublisherURL=https://github.com/naipi11/Codex-Control-other-devices-Windows
AppSupportURL=https://github.com/naipi11/Codex-Control-other-devices-Windows/issues
AppUpdatesURL=https://github.com/naipi11/Codex-Control-other-devices-Windows/releases
VersionInfoVersion={#ProjectVersion}.0
DefaultDirName={localappdata}\CodexControlOtherDevices-installer
DefaultGroupName=Codex Control other devices
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=CodexControlOtherDevices-{#ProjectVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no
SetupLogging=yes
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.zh-CN.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\NOTICE.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\package.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\tests\*"; DestDir: "{app}\tests"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\Install-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Uninstall-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Start-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Reset-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Test-CodexControlOtherDevices.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install-CodexControlOtherDevices.ps1"" -EnableCandidateCompatibleUpdates"; Flags: runhidden waituntilterminated; StatusMsg: "Installing the persistent tray supervisor..."

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-CodexControlOtherDevices.ps1"" -BackupDeviceKeyStore"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallCodexControlOtherDevices"

[Icons]
Name: "{group}\Codex Control other devices for Windows"; Filename: "{app}\README.md"
Name: "{group}\Open the tray supervisor"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Start-CodexControlOtherDevices.ps1"""; WorkingDir: "{app}"
Name: "{group}\Compatibility check"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Test-CodexControlOtherDevices.ps1"""; WorkingDir: "{app}"
Name: "{group}\Uninstall Codex Control other devices"; Filename: "{app}\unins000.exe"

[Code]
function IsAppInstalled(): Boolean;
begin
  Result := RegKeyExists(HKCU64, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{8B5E8A46-4B1B-4B1B-8C2B-1B9B2C2D2E3F}_is1');
end;

function InitializeSetup(): Boolean;
begin
  if IsAppInstalled() then
    MsgBox('Codex Control other devices is already installed. Run the new setup to upgrade the installed files, then the persistent supervisor will be updated.', mbInformation, MB_OK);
  Result := True;
end;
