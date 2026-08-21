<#
    UninstallCleanup.ps1
    Called by the uninstaller. Removes the scheduled tasks this tool installed.
    Printer shares and settings are deliberately left alone - uninstalling the
    tool should not take the office printers offline. Use "Undo the last run"
    inside the app first if you want the settings reverted too.
#>
param([switch]$KeepLogs)

$ErrorActionPreference = 'SilentlyContinue'

foreach ($t in @('PrinterShareSetup-HostKeepAlive', 'PrinterShareSetup-ClientReconnect')) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if (-not $KeepLogs) {
    $root = Join-Path $env:ProgramData 'PrinterShareSetup'
    Remove-Item -LiteralPath (Join-Path $root 'Watchdog.ps1')  -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root 'watchdog.json') -Force -ErrorAction SilentlyContinue
}

exit 0
