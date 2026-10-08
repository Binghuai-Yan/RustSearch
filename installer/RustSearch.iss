#ifndef AppVersion
  #define AppVersion "0.1.3"
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
english.DeleteIndexPrompt=Delete this user's RustSearch search index and metadata? Other files and settings in the data folder will be kept. Choose No to keep the index.
chinesesimplified.DeleteIndexPrompt=是否删除当前用户的 RustSearch 搜索索引和元数据库？数据目录中的其他文件和设置会保留。选择“否”则保留索引。
english.DeleteIndexFailed=The search index could not be deleted (error code %1). The program will be uninstalled, but index files may remain.
chinesesimplified.DeleteIndexFailed=无法删除搜索索引（错误码 %1）。程序会继续卸载，但索引文件可能仍然保留。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\RustSearch"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\Assets\RustSearch.ico"
Name: "{autodesktop}\RustSearch"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\Assets\RustSearch.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,RustSearch}"; Flags: nowait postinstall skipifsilent

[Code]
var
  DeleteUserIndex: Boolean;

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
begin
  Result := True;
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
    '--delete-user-index', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if not Started or (ResultCode <> 0) then
  begin
    Log('RustSearch index deletion failed; code ' + IntToStr(ResultCode));
    if not UninstallSilent then
      MsgBox(Format(ExpandConstant('{cm:DeleteIndexFailed}'), [IntToStr(ResultCode)]),
        mbError, MB_OK);
  end;
end;
