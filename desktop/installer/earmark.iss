; Earmark for Windows: the installer (Inno Setup 6).
;
; Installs for the current user only, without administrator rights: the program goes into
; %LOCALAPPDATA%\Programs\Earmark, with a Start menu entry and an uninstaller (Settings > Apps).
; The library's data (%APPDATA%\Earmark) is not touched by installing or uninstalling.
;
; Built by the Desktop workflow:
;   iscc /DAppVersion=0.1.0 /DSourceExe=path\to\Earmark.exe /DOutputDir=out desktop\installer\earmark.iss
; Not signed yet: Windows SmartScreen warns the first time it is opened.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\target\release\earmark-desktop.exe"
#endif
#ifndef OutputDir
  #define OutputDir "..\target\installer"
#endif

[Setup]
; The same id on every version, so a new installer replaces the old one.
AppId={{16DB78F3-A040-4DAE-934B-78B6E9C01725}
AppName=Earmark
AppVersion={#AppVersion}
AppVerName=Earmark {#AppVersion}
AppPublisher=Earmark
AppPublisherURL=https://github.com/christian-ofigueiredo/earmark-sound-library
DefaultDirName={autopf}\Earmark
DefaultGroupName=Earmark
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\Earmark.exe
UninstallDisplayName=Earmark
OutputDir={#OutputDir}
OutputBaseFilename=Earmark-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "Earmark.exe"; Flags: ignoreversion
; The fonts are compiled into Earmark.exe; their licences travel beside it (Inter: SIL OFL 1.1).
Source: "..\assets\fonts\OFL.txt"; DestDir: "{app}\licenses"; DestName: "Inter-OFL.txt"; Flags: ignoreversion
Source: "..\assets\fonts\Inter-NOTE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}\licenses"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}\licenses"; DestName: "Earmark-LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Earmark"; Filename: "{app}\Earmark.exe"
Name: "{autodesktop}\Earmark"; Filename: "{app}\Earmark.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
Filename: "{app}\Earmark.exe"; Description: "{cm:LaunchProgram,Earmark}"; Flags: nowait postinstall skipifsilent
