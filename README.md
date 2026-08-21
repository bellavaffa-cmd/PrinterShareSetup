# Printer Share Setup

Shares several printers from one Windows PC and applies the settings that keep
that sharing stable — no sleep, no USB power-down, firewall openings, spooler
auto-recovery, and a background helper that repairs things when they drift.

Two modes, chosen when you run it:

- **Print server** — run this on the PC the printers are plugged into.
- **Client** — run this on the other PCs that need to print.

---

## Building the installer

The source is PowerShell, so there is nothing to compile except the installer
itself. That step needs Windows.

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php).
2. Open `installer\PrinterShareSetup.iss` in the Inno Setup Compiler.
3. **Build → Compile**.

Output: `dist\PrinterShareSetup-Setup.exe`.

From a command line instead:

```
"C:\Program Files (x86)\Inno Setup 6\iscc.exe" installer\PrinterShareSetup.iss
```

### Running it without building anything

The installer is only packaging. To test immediately, right-click
**`Run as administrator.bat`** and choose *Run as administrator*. Everything
works identically.

If PowerShell refuses to run the script, the launcher already passes
`-ExecutionPolicy Bypass`, so this should not come up — but if you are running
`PrinterShareSetup.ps1` directly, use:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File PrinterShareSetup.ps1
```

---

## What it changes

### Print server mode

The printer list has a **Connection** column showing how each printer is
attached, and only the USB-connected ones are ticked to begin with. A printer
on a WSD or TCP/IP port already has its own address on the network, so every PC
can add it directly — sharing it through this PC still works, but it makes this
PC a single point of failure for a printer that did not need one. Tick it
anyway if you want one place to manage the queue.

| Area | Change | Why |
|---|---|---|
| Printers | Sets `Shared` with a clean share name; leaves them unpublished to AD | Publishing to a directory that is missing or slow is a classic source of long stalls |
| Network profile | Public → Private on the active adapter | Sharing is blocked outright on Public networks |
| Firewall | Enables the built-in File and Printer Sharing and Network Discovery rules; rules scoped **only** to Public are left disabled | A rule cannot be enabled for one of its profiles, so Windows' combined "Private, Public" rules are enabled as-is — the same thing the Sharing control panel does |
| Services | `Spooler`, `LanmanServer`, `FDResPub`, `fdPHost`, `SSDPSRV`, `upnphost` → Automatic + started | When the discovery services are stopped, clients fall back to slow broadcast lookups |
| Spooler recovery | `sc failure Spooler` → restart at 5s / 10s / 30s | Stops a one-off spooler crash from taking the printers down until someone notices |
| Power | Sleep, hibernate and disk timeouts → 0 on AC; USB selective suspend off; Fast Startup off | The single most common cause of "the shared printer disappeared" |
| Network adapter | "Allow the computer to turn off this device" → off | Stops the host dropping off the network while idle |
| Spooler tuning | `NetPopup` = 0 under `Control\Print\Providers`; `BeepEnabled` = 0 | Error balloons block the spooler thread waiting for someone who is not sitting at the server |
| Optional | Rendering mode → SSR | Removes the whole class of failures caused by clients running a different driver version |
| Optional | Print permission granted to all users | |

### Client mode

| Area | Change | Why |
|---|---|---|
| Point and Print | **Safe (default)**: `PackagePointAndPrintOnly` = 1 and an approved server list containing only your server | Keeps the PrintNightmare hardening intact while letting the connection succeed |
| Point and Print | **Compatibility (opt-in)**: relaxes `RestrictDriverInstallationToAdministrators` for the named server only | Needed for older v3-only drivers. Off by default, and the tool says why before you tick it |
| Printers | Connects `\\SERVER\Share`, optionally sets one as default | |
| Default printer | `LegacyDefaultPrinterMode` = 1 | Windows otherwise moves the default to whatever you printed to last, so jobs land on the wrong printer |
| Credentials | Optional `cmdkey` entry for the server | Stops a workgroup client getting a login prompt mid-print |
| Spooler | Automatic + auto-restart recovery | |

### The keep-alive helper

A scheduled task, installed optionally in either mode.

- **Server** — every 15 minutes and at startup, as SYSTEM. Starts the spooler if
  it died, re-applies the `Shared` flag if a driver or feature update cleared it,
  removes jobs that have been jammed for more than 20 minutes, restarts the
  discovery services if they drifted back to Manual.
- **Client** — at every sign-in and every 30 minutes, in the signed-in user's own
  profile. Re-adds any printer connection that dropped, skipping quietly when the
  server is switched off.

Its log is `C:\ProgramData\PrinterShareSetup\logs\watchdog.log`.

---

## Undoing it

Every registry value, service setting, sleep timeout and printer share the tool
changes is recorded first — including the printer's original security descriptor
and rendering mode, and any registry key it had to create.
**Check, repair or undo → Undo last run** puts them all back.

Rollback points are JSON files in `C:\ProgramData\PrinterShareSetup\rollback\`.

Uninstalling removes the scheduled tasks but deliberately leaves the printer
shares alone — uninstalling a setup tool should not take the office printers
offline. Undo first if you want the settings reverted too.

---

## Known limits

- **Printer connections are per-user.** If you satisfy the UAC prompt with a
  different admin account than the one signed in, the connection lands in that
  account's profile. The tool detects this and warns; the keep-alive helper
  fixes it at the next sign-in because it runs in each user's own context.
- **Windows Protected Print Mode** (Windows 11 24H2+) blocks printer sharing
  completely. The tool detects it and tells you where to turn it off, but cannot
  turn it off for you — it needs a reboot.
- **Driver architecture still matters.** If a client is on a driver version the
  server does not have, either install the driver on the client first or tick
  "Render print jobs on this PC" on the server.

---

## Layout

```
PrinterShareSetup.ps1        GUI and orchestration
Run as administrator.bat     launcher
lib\Common.ps1               logging, elevation, tracked writes, rollback journal
lib\HostSetup.ps1            print-server configuration
lib\ClientSetup.ps1          client configuration
lib\Maintenance.ps1          watchdog install, health check, queue repair, undo
lib\Watchdog.ps1             the scheduled-task body (self-contained)
lib\UninstallCleanup.ps1     called by the uninstaller
installer\PrinterShareSetup.iss   Inno Setup source
assets\app.ico
```

Requires Windows 10 or 11 and Windows PowerShell 5.1 (built in — nothing to
install).
