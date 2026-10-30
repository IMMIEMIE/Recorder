#ifndef PublishDir
  #error PublishDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
[Setup]
AppId={{BD44B8C1-FF60-4D9E-96B5-B82E179D1E53}
AppName=声笺 Windows x86
AppVersion=0.5.0
AppPublisher=Recorder contributors
AppPublisherURL=https://github.com/IMMIEMIE/Recorder
DefaultDirName={localappdata}\Programs\Shengjian
DefaultGroupName=声笺
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x86compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=Shengjian-0.5.0-windows-x86-setup
SetupIconFile=..\Recorder.Windows\AppIcon.ico
UninstallDisplayIcon={app}\Shengjian.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
LicenseFile=..\..\LICENSE
InfoBeforeFile=..\INSTALL-NOTES.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\声笺"; Filename: "{app}\Shengjian.exe"
Name: "{autodesktop}\声笺"; Filename: "{app}\Shengjian.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Shengjian.exe"; Description: "启动声笺"; Flags: nowait postinstall skipifsilent
