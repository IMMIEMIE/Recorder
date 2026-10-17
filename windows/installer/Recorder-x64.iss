#ifndef PublishDir
  #error PublishDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #define AppVersion "0.6.1"
#endif
#ifndef OutputName
  #define OutputName "Shengjian-" + AppVersion + "-windows-x64-preview-setup"
#endif
[Setup]
AppId={{DE0906A7-1D55-45C8-A047-75636159D0A4}
AppName=声笺 Windows x64
AppVersion={#AppVersion}
AppPublisher=Recorder contributors
DefaultDirName={localappdata}\Programs\Shengjian-x64
DefaultGroupName=声笺 Windows x64
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\Recorder.Windows\AppIcon.ico
UninstallDisplayIcon={app}\Shengjian.exe
Compression=lzma2/ultra64
LZMAUseSeparateProcess=yes
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
LicenseFile=..\..\LICENSE
InfoBeforeFile=..\INSTALL-NOTES-x64.txt
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
[Tasks]
Name: "desktopicon"; Description: "创建声笺 x64 桌面快捷方式"; Flags: unchecked
[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\声笺 Windows x64"; Filename: "{app}\Shengjian.exe"
Name: "{autodesktop}\声笺 Windows x64"; Filename: "{app}\Shengjian.exe"; Tasks: desktopicon
[Run]
Filename: "{app}\Shengjian.exe"; Description: "启动声笺 x64"; Flags: nowait postinstall skipifsilent
