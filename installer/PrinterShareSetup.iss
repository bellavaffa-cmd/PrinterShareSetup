; ---------------------------------------------------------------------------
;  Printer Share Setup - Inno Setup script
;
;  Build:
;    1. Install Inno Setup 6.0 or newer from https://jrsoftware.org/isdl.php
;    2. Open this file in the Inno Setup Compiler
;    3. Build > Compile  (or run: iscc PrinterShareSetup.iss)
;
;  Output: ..\dist\PrinterShareSetup-Setup.exe
; ---------------------------------------------------------------------------

#define AppName        "Printer Share Setup"
#define AppVersion     "1.0.0"
#define AppPublisher   "Printer Share Setup"
#define AppExeAlias    "PrinterShareSetup.ps1"

[Setup]
AppId={{8C4A5F27-31B6-4E9D-9A15-7C2E4D8B6A31}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\Printer Share Setup
DefaultGroupName=Printer Share Setup
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=PrinterShareSetup-Setup
SetupIconFile=..\assets\app.ico
UninstallDisplayIcon={app}\assets\app.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Every action this tool performs needs administrator rights, so ask once here.
PrivilegesRequired=admin
; "x64compatible" is preferred and also covers ARM64 running x64 code, but it
; needs Inno Setup 6.3+. Older compilers only understand "x64", which 6.7
; still accepts with a deprecation warning. Pick per compiler so this builds
; clean on 6.0 through 7.x.
#if Ver >= EncodeVer(6,3,0)
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesInstallIn64BitMode=x64
#endif
MinVersion=10.0
AppReadmeFile={app}\README.md

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\PrinterShareSetup.ps1";        DestDir: "{app}";        Flags: ignoreversion
Source: "..\Run as administrator.bat";     DestDir: "{app}";        Flags: ignoreversion
Source: "..\README.md";                    DestDir: "{app}";        Flags: ignoreversion isreadme
Source: "..\lib\*.ps1";                    DestDir: "{app}\lib";    Flags: ignoreversion
Source: "..\assets\app.ico";               DestDir: "{app}\assets"; Flags: ignoreversion

[Icons]
; The shortcuts point at powershell.exe. The script raises its own UAC prompt,
; so the user is asked to elevate only when they actually run it.
Name: "{group}\Printer Share Setup"; \
    Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\PrinterShareSetup.ps1"""; \
    WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; \
    Comment: "Share printers from this PC, or connect to shared printers"

Name: "{group}\Printer Share Setup - log folder"; \
    Filename: "{commonappdata}\PrinterShareSetup\logs"

Name: "{group}\Uninstall Printer Share Setup"; Filename: "{uninstallexe}"

Name: "{autodesktop}\Printer Share Setup"; \
    Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\PrinterShareSetup.ps1"""; \
    WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; \
    Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\PrinterShareSetup.ps1"""; \
    Description: "Run Printer Share Setup now"; \
    Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove the background keep-alive tasks. Printer shares and system settings
; are left in place on purpose - use "Undo the last run" in the app first if
; you want those reverted.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\lib\UninstallCleanup.ps1"""; \
    Flags: runhidden; RunOnceId: "RemoveKeepAliveTasks"

[Code]
function InitializeSetup(): Boolean;
var
  Version: TWindowsVersion;
begin
  Result := True;
  GetWindowsVersionEx(Version);
  if Version.Major < 10 then
  begin
    MsgBox('Printer Share Setup needs Windows 10 or Windows 11.', mbCriticalError, MB_OK);
    Result := False;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // A suppressed MB_YESNO returns IDYES, so an unattended uninstall would
    // wipe the logs without anyone agreeing to it. Only ask - and only
    // delete - when there is a person there to answer.
    if UninstallSilent() then
      Exit;
    if MsgBox('Also delete the log files in ProgramData?',
              mbConfirmation, MB_YESNO) = IDYES then
      DelTree(ExpandConstant('{commonappdata}\PrinterShareSetup'), True, True, True);
  end;
end;
