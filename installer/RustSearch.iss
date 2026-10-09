#ifndef AppVersion
  #define AppVersion "0.1.7"
#endif
#ifndef AppExeName
  #define AppExeName "RustSearch.WinUI.exe"
#endif
#ifndef PublishDir
  #define PublishDir "..\dist\RustSearch"
#endif
#ifndef InstallerOutputDir
  #define InstallerOutputDir "..\dist"
#endif
#ifndef InstallerBaseName
  #define InstallerBaseName "RustSearch-" + AppVersion + "-win-x64-setup"
#endif

[Setup]
AppId={{7A55EDDF-1CB8-4400-99EB-21209EC1E6DD}
AppName=RustSearch
AppVersion={#AppVersion}
AppVerName=RustSearch {#AppVersion}
AppPublisher=RustSearch
DefaultDirName={localappdata}\Programs\RustSearch
DefaultGroupName=RustSearch
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
SetupIconFile=..\RustSearch.UI\Assets\RustSearch.ico
UninstallDisplayIcon={app}\Assets\RustSearch.ico
OutputDir={#InstallerOutputDir}
OutputBaseFilename={#InstallerBaseName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[CustomMessages]
english.DeleteIndexPrompt=Delete this user's RustSearch index, metadata and application settings? Unrelated files in the data folder will be kept. Choose No to keep your data.
chinesesimplified.DeleteIndexPrompt=是否删除当前用户的 RustSearch 索引、元数据库和程序配置？数据目录中其他文件会保留。选择“否”则保留数据。
english.DeleteIndexFailed=RustSearch user data could not be deleted (error code %1). The program will be uninstalled, but data may remain.
chinesesimplified.DeleteIndexFailed=无法删除 RustSearch 用户数据（错误码 %1）。程序会继续卸载，但数据可能残留。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\RustSearch"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\Assets\RustSearch.ico"
Name: "{group}\RustSearch 输入法兼容界面"; Filename: "{app}\Compat\RustSearch.UI.exe"; IconFilename: "{app}\Assets\RustSearch.ico"; Check: IsWinUIBuild
Name: "{autodesktop}\RustSearch"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\Assets\RustSearch.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,RustSearch}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DeleteUserIndex: Boolean;

function IsWinUIBuild(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\Compat\RustSearch.UI.exe'));
end;

function HasDeleteIndexSwitch(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/DELETEUSERINDEX') = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if FileExists(ExpandConstant('{app}\RustSearch.WinUI.exe')) then
    Exec(ExpandConstant('{app}\RustSearch.WinUI.exe'), '--exit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if FileExists(ExpandConstant('{app}\Compat\RustSearch.UI.exe')) then
    Exec(ExpandConstant('{app}\Compat\RustSearch.UI.exe'), '--exit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1500);
  DeleteUserIndex := HasDeleteIndexSwitch();
  if not DeleteUserIndex and not UninstallSilent then
    DeleteUserIndex := MsgBox(ExpandConstant('{cm:DeleteIndexPrompt}'),
      mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  Started: Boolean;
begin
  if (CurUninstallStep <> usUninstall) or not DeleteUserIndex then
    Exit;

  Started := Exec(ExpandConstant('{app}\Backend\rustsearch-backend.exe'),
    '--delete-user-data', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Started or (ResultCode <> 0) then
  begin
    Log('RustSearch index deletion failed; code ' + IntToStr(ResultCode));
    if not UninstallSilent then
      MsgBox(Format(ExpandConstant('{cm:DeleteIndexFailed}'), [IntToStr(ResultCode)]),
        mbError, MB_OK);
  end;
end;
