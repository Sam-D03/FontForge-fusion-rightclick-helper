#ifndef AppVersion
#define AppVersion "1.0.0"
#endif

#define AppName "Fusion FontForge Helper"
#define AppPublisher "Sam-D03"
#define AppURL "https://github.com/Sam-D03/FontForge-fusion-rightclick-helper"

[Setup]
AppId={{15C37511-5FF1-4B12-8886-A52B4AD172DF}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={autopf}\Fusion FontForge Helper
DefaultGroupName=Fusion FontForge Helper
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=FusionFontForgeHelperSetup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
ChangesAssociations=yes
CloseApplications=no
UninstallDisplayName={#AppName}
UninstallDisplayIcon={uninstallexe}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}

[Files]
Source: "..\Repair-FusionFont.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\fusion_font_repair.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Install-ContextMenu.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Uninstall-ContextMenu.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Remove-FusionFont.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Fusion FontForge Helper README"; Filename: "{app}\README.md"
Name: "{group}\Uninstall Fusion FontForge Helper"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-ContextMenu.ps1"" -Scope Both"; StatusMsg: "Removing older right-click menu entries..."; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install-ContextMenu.ps1"" -Scope AllUsers"; StatusMsg: "Registering the Make Fusion Font right-click menu..."; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-ContextMenu.ps1"" -Scope Both"; StatusMsg: "Removing the Make Fusion Font right-click menu..."; Flags: runhidden waituntilterminated; RunOnceId: "RemoveContextMenu"

[Code]
var
  FontForgePage: TInputFileWizardPage;
  DownloadLink: TNewStaticText;

function DetectFFPython: String;
var
  Candidate: String;
begin
  Result := '';

  Candidate := ExpandConstant('{pf}\FontForgeBuilds\bin\ffpython.exe');
  if FileExists(Candidate) then
  begin
    Result := Candidate;
    Exit;
  end;

  Candidate := ExpandConstant('{pf32}\FontForgeBuilds\bin\ffpython.exe');
  if FileExists(Candidate) then
  begin
    Result := Candidate;
    Exit;
  end;
end;

procedure OpenFontForgeDownload(Sender: TObject);
var
  ErrorCode: Integer;
begin
  ShellExec('open', 'https://fontforge.org/en-US/downloads/windows/', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;

procedure InitializeWizard;
begin
  FontForgePage := CreateInputFilePage(
    wpSelectDir,
    'FontForge Location',
    'Select FontForge''s ffpython.exe',
    'Fusion FontForge Helper uses FontForge''s bundled Python runtime to repair fonts. If FontForge is not installed yet, open the download link below, install FontForge, then return to this installer.'
  );

  FontForgePage.Add(
    'FontForge Python executable:',
    'FontForge Python (ffpython.exe)|ffpython.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*',
    '.exe'
  );
  FontForgePage.Values[0] := DetectFFPython;

  DownloadLink := TNewStaticText.Create(FontForgePage);
  DownloadLink.Parent := FontForgePage.Surface;
  DownloadLink.Caption := 'Download FontForge for Windows';
  DownloadLink.Left := ScaleX(0);
  DownloadLink.Top := ScaleY(130);
  DownloadLink.Font.Color := clBlue;
  DownloadLink.Font.Style := DownloadLink.Font.Style + [fsUnderline];
  DownloadLink.Cursor := crHand;
  DownloadLink.OnClick := @OpenFontForgeDownload;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  FFPythonPath: String;
begin
  Result := True;

  if CurPageID = FontForgePage.ID then
  begin
    FFPythonPath := Trim(FontForgePage.Values[0]);

    if (FFPythonPath = '') or (not FileExists(FFPythonPath)) then
    begin
      if MsgBox('FontForge ffpython.exe was not found. Open the FontForge download page now?', mbConfirmation, MB_YESNO) = IDYES then
      begin
        OpenFontForgeDownload(nil);
      end;
      Result := False;
      Exit;
    end;

    if CompareText(ExtractFileName(FFPythonPath), 'ffpython.exe') <> 0 then
    begin
      MsgBox('Please select FontForge''s ffpython.exe, not a different executable.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

function JsonEscape(Value: String): String;
begin
  Result := Value;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigPath: String;
  ConfigText: String;
  FFPythonPath: String;
begin
  if CurStep = ssPostInstall then
  begin
    FFPythonPath := JsonEscape(FontForgePage.Values[0]);
    ConfigPath := ExpandConstant('{app}\fusion-font-repair.config.json');
    ConfigText := '{' + #13#10 +
      '  "ffpython_path": "' + FFPythonPath + '"' + #13#10 +
      '}' + #13#10;

    if not SaveStringToFile(ConfigPath, ConfigText, False) then
    begin
      MsgBox('The installer could not write the FontForge configuration file. You can still set FUSION_FONTFORGE_FFPYTHON manually later.', mbError, MB_OK);
    end;
  end;
end;
