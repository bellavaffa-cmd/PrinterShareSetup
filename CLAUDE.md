# Printer Share Setup — project context

A Windows GUI tool that shares several printers from one PC and applies the
settings that keep that sharing stable. PowerShell + WinForms, packaged with
Inno Setup.

## Hard constraints

- **Windows PowerShell 5.1 only.** This ships to machines with nothing
  installed, so it must run on the inbox PowerShell. No PS7 syntax anywhere:
  no ternary `? :`, no `??`, no `&&`/`||` chains, no `-Parallel`,
  no `[type]::new()`, no `-AsHashtable`. Verify before committing.
- **No `Set-StrictMode`.** It was removed deliberately — the code reads
  optional hashtable keys and JSON properties that may be absent, and strict
  mode turns those into terminating errors.
- **Every system change must be reversible.** Anything that writes to the
  registry, a service, a printer or a power setting goes through a tracked
  helper that journals the prior value first (see `lib/Common.ps1`). If you add
  a new kind of change, add a matching case to `Invoke-PSSUndo` in
  `lib/Maintenance.ps1`. A change with no undo path is a bug.

## Layout

```
PrinterShareSetup.ps1        WinForms GUI + orchestration; self-elevates via UAC
lib/Common.ps1               logging, elevation, tracked registry/service writes,
                             rollback journal, share-name sanitiser
lib/HostSetup.ps1            print-server mode
lib/ClientSetup.ps1          client mode
lib/Maintenance.ps1          watchdog install/remove, health check, queue repair, undo
lib/Watchdog.ps1             scheduled-task body — deliberately self-contained,
                             it must keep working if the program folder is deleted
lib/UninstallCleanup.ps1     called from [UninstallRun]
installer/PrinterShareSetup.iss
```

`lib/*.ps1` are **dot-sourced**, not modules. `$PSScriptRoot` inside them
resolves to `lib\`.

## Running and testing

```powershell
# Run it (self-elevates)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PrinterShareSetup.ps1

# Syntax-check everything without executing — do this after every edit
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e.Count) { "FAIL $($_.Name)"; $e | ForEach-Object { "  line $($_.Extent.StartLineNumber): $($_.Message)" } }
    else { "OK   $($_.Name)" }
}
```

Build the installer: `iscc installer\PrinterShareSetup.iss` → `dist\PrinterShareSetup-Setup.exe`.
Needs Inno Setup 6. Installed here with `winget install JRSoftware.InnoSetup`,
which puts it in the **user** profile, not Program Files:

```
C:\Users\<you>\AppData\Local\Programs\Inno Setup 6\ISCC.exe
```

`ArchitecturesInstallIn64BitMode` is chosen by `#if Ver >= EncodeVer(6,3,0)`:
`x64compatible` on 6.3+, plain `x64` on older compilers, which keeps the build
warning-free on 6.7 without breaking 6.0–6.2.

### Verification status (2026-08-21, real Windows 11 26220, PS 5.1)

Verified on real hardware: all seven files parse; the GUI builds and every
panel renders; `Get-PSSLocalPrinters` correctly classified three real queues
(2× WSD, 1× USB); `Get-PSSHostReadiness`, `Invoke-PSSHealthCheck`,
`Get-PSSPowerAcIndex`, `Get-PSSHostIPv4`, `Test-PSSProtectedPrintMode`,
`ConvertTo-PSSShareName` all behave; the installer compiles, silently installs,
and silently uninstalls with no leftovers.

### Host write paths — run for real 2026-08-24

`Invoke-PSSHostSetup`, `Install-PSSWatchdog` and `Invoke-PSSUndo` have now been
run against a live spooler, and the machine was returned to its exact starting
state afterwards (18/18 settings verified). That run found four defects, all
fixed: the watchdog trigger, the `DU` SDDL, undo not consuming its rollback
point, and the silent watchdog log. The watchdog was also proved to work by
un-sharing a printer and watching it re-share and log the repair.

**Verified by execution:** sharing, firewall enable, service changes, power
changes, spooler tuning, watchdog install + repair + heartbeat, undo of
registry/service/powercfg/printer/task entries, and undo stepping back through
successive rollback points.

**Written but NOT yet executed** — the fixes for the gaps that same run exposed:

- `NetProfile` journal + undo case (network profile was previously not
  reversible at all)
- `Firewall` journal + undo case (the rules it enabled were previously not
  reversible at all)
- the exact-seconds powercfg restore (`/change` takes whole minutes, so a
  30-second disk timeout used to round to 0 and come back as "never")

These parse clean and were derived from observed behaviour, but the apply→undo
round trip that would prove them has not been run. Do that before trusting
them: apply, confirm `Firewall`/`NetProfile` entries appear in the journal
under `C:\ProgramData\PrinterShareSetup\rollback\`, undo, then check the
firewall counts, network category and disk timeout are back.

**`Invoke-PSSClientSetup` remains entirely unexercised.**

Beware: an elevated child process died silently once mid-undo, writing only its
first log line and no error. It was not reproducible. If undo stops early,
check the app's own log in `C:\ProgramData\PrinterShareSetup\logs\` — the
transcript loses buffered output when the process dies, the app log does not.

To exercise read-only paths without the GUI, dot-source the four `lib` files
and call the `Get-*`/`Test-*` functions directly. Note that **RichTextBox
renders blank under `DrawToBitmap`** — check `.Text`/`.TextLength` instead of
believing a screenshot of the findings or log boxes.

Useful state to inspect while testing:

```
C:\ProgramData\PrinterShareSetup\logs\        run + watchdog logs
C:\ProgramData\PrinterShareSetup\rollback\    JSON rollback points
schtasks /query /tn PrinterShareSetup-HostKeepAlive
schtasks /query /tn PrinterShareSetup-ClientReconnect
```

## GUI layout rules

WinForms panels use absolute coordinates. Usable content area is about
**890 × 570** before scrollbars appear.

- Controls added **earlier** sit in **front** and paint over later ones. Two
  overlapping panels means the earlier one wins — this caused three separate
  bugs already.
- `New-PSSCheck` returns a Panel: height 38 with no sub-line, 46 with one, and
  the sub-label is sized from the `$Width` **parameter**. Pass the width in;
  setting `.Width` after the call leaves an oversized clipped label.
- Sub-label text must fit one line — roughly 5.7 px per character against
  `(width - 24)`. Longer text silently clips at 20 px tall.
- Two-column option rows are x=0 and x=440, each 420 wide.

## Traps already hit — do not reintroduce

- **PowerShell variable names are case-insensitive.** The theme hashtable was
  `$T`, and `New-PSSChoiceCard`/`New-PSSActionRow` used `$t` for a local Label.
  They are the *same variable*: `$t = New-Object ...Label` destroyed the theme,
  then `$T.Text` read the Label's `Text` and the GUI died on the first control
  with `Cannot convert "Set up this PC as the print server" to ...Color`. The
  whole app failed to open. The theme is now `$Theme` — never reintroduce a
  one- or two-letter global, and never name a local the same letter as one.
- `Enable-NetFirewallRule` has **no** `-Profile` parameter. Filter with
  `Get-NetFirewallRule | Where-Object` first.
- WQL needs `.Replace('\','\\')`. A `-replace` *replacement* string treats
  backslash as literal, so `'\\\\'` produces four backslashes, not two.
- `powercfg /query` always prints `Minimum Possible Setting: 0x00000000`, so
  matching bare `0x00000000` always succeeds. Anchor on
  `Current AC Power Setting Index:`.
- `NetPopup` lives under `Control\Print\Providers`, not `Control\Print`.
- `New-ScheduledTaskTrigger`: **omit `-RepetitionDuration` entirely** for
  "indefinitely". An earlier note here claimed `[TimeSpan]::MaxValue` was
  wanted — that is exactly backwards, and it silently cost the host watchdog:
  `Register-ScheduledTask` fails with "The task XML contains a value which is
  incorrectly formatted or out of range." `[TimeSpan]::Zero` fails the same
  way. Verified against the real Task Scheduler: `AtStartup` alone passes,
  omitted duration passes, 3650 days passes, MaxValue and Zero both fail.
- Printer `PermissionSDDL` must not name `DU` (Domain Users). On a workgroup
  PC that SID cannot be translated and `Set-Printer` rejects the entire
  descriptor, so "Let everyone print" degraded to a warning on every
  non-domain machine. Use `G:BA`.
- Printer connections and `HKCU` writes are **per-user**. If UAC is satisfied
  with a different admin account than the one signed in, they land in the wrong
  profile. The client watchdog runs as `BUILTIN\Users` at logon to compensate.
- `Start-PSSRun` pumps `DoEvents()` so the log paints, which makes re-entrancy
  possible. The `$script:PSSRunning` guard exists for that reason — keep it.

## Environment notes

- **Windows Protected Print Mode** (Win 11 24H2+) blocks printer sharing
  outright. `Test-PSSProtectedPrintMode` detects it; it cannot be turned off
  without a reboot, so the tool only warns.
- Point-and-Print defaults to the **safe** policy (package-aware drivers +
  approved server list). Compatibility mode relaxes
  `RestrictDriverInstallationToAdministrators` and is opt-in only, scoped to the
  one named server. Do not make it the default.

## Git

`main` tracks `origin` at https://github.com/bellavaffa-cmd/PrinterShareSetup
(public). The repo name deliberately matches the folder name — it was briefly
`printer-share-setup` and that made it unfindable by searching for the folder.
Commit as `bellavaffa-cmd <bellavaffa-cmd@users.noreply.github.com>`
— the identity is set per-repo here, not globally.

`dist/*.exe` is gitignored on purpose: the installer is a build artifact, so
rebuild it with `iscc` rather than committing it. Releases can carry the binary.
