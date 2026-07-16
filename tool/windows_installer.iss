; Inno Setup script for the Markdown Studio Windows installer.
; Compiled by the release workflow:
;   iscc /DAppVersion=1.0.1 /DSourceDir=..\build\windows\x64\runner\Release ^
;        /DOutputDir=..\dist tool\windows_installer.iss
; Produces a classic setup.exe (per-user install under %LocalAppData%,
; Start-Menu entry, uninstaller). PrivilegesRequired=lowest means no admin
; prompt, so the in-app updater can run it silently. A signed MSIX for the
; Microsoft Store is a separate path — see the store-submission notes.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{9C1B0C7E-5E71-4E19-9C1D-3D2B65A11B6B}
AppName=Markdown Studio
AppVersion={#AppVersion}
AppPublisher=Markdown Studio
AppPublisherURL=https://github.com/TheSaltyKorean/md
DefaultDirName={localappdata}\Programs\Markdown Studio
DefaultGroupName=Markdown Studio
DisableProgramGroupPage=yes
; Per-user install: no admin/UAC on install or update.
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=markdown-studio-setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\markdown_studio.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; \
  GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Markdown Studio"; Filename: "{app}\markdown_studio.exe"
Name: "{autodesktop}\Markdown Studio"; Filename: "{app}\markdown_studio.exe"; \
  Tasks: desktopicon

; Register the app as a handler for .md at install time (per-user, so HKCU) —
; the app no longer has to self-register on first run. This mirrors the ProgID
; the runtime FileAssociationService writes (MarkdownStudio.md). We register the
; handler + icon + Open-With entry only; we do NOT force the UserChoice default,
; which modern Windows reserves for the user's explicit confirmation.
[Registry]
Root: HKCU; Subkey: "Software\Classes\MarkdownStudio.md"; \
  ValueType: string; ValueName: ""; ValueData: "Markdown Document"; \
  Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\MarkdownStudio.md\DefaultIcon"; \
  ValueType: string; ValueName: ""; ValueData: "{app}\markdown_studio.exe,0"
Root: HKCU; Subkey: "Software\Classes\MarkdownStudio.md\shell\open\command"; \
  ValueType: string; ValueName: ""; \
  ValueData: """{app}\markdown_studio.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\.md\OpenWithProgids"; \
  ValueType: none; ValueName: "MarkdownStudio.md"; \
  Flags: uninsdeletevalue

[Run]
Filename: "{app}\markdown_studio.exe"; \
  Description: "Launch Markdown Studio"; \
  Flags: nowait postinstall skipifsilent

[Code]
const
  SHCNE_ASSOCCHANGED = $08000000;
  SHCNF_IDLIST       = $0000;

procedure SHChangeNotify(wEventId: Integer; uFlags: Cardinal;
  dwItem1, dwItem2: Cardinal);
  external 'SHChangeNotify@shell32.dll stdcall';

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // Tell the shell the .md association changed so Explorer refreshes icons
  // and the Open-With list without needing a reboot or re-login.
  if CurStep = ssPostInstall then
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0);
end;
