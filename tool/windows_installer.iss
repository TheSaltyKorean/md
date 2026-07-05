; Inno Setup script for the Markdown Studio Windows installer.
; Compiled by the release workflow:
;   iscc /DAppVersion=1.0.1 /DSourceDir=..\build\windows\x64\runner\Release ^
;        /DOutputDir=..\dist tool\windows_installer.iss
; Produces a classic setup.exe (Program Files install, Start-Menu entry,
; uninstaller). A signed MSIX for the Microsoft Store is a separate path —
; see the store-submission notes in README.md.

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
DefaultDirName={autopf}\Markdown Studio
DefaultGroupName=Markdown Studio
DisableProgramGroupPage=yes
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

[Run]
Filename: "{app}\markdown_studio.exe"; \
  Description: "Launch Markdown Studio"; \
  Flags: nowait postinstall skipifsilent
