<#
    Watchdog.ps1 - runs unattended from a scheduled task.
    Keeps the print server (or a client's connections) alive without anyone
    having to notice something broke. Self-contained on purpose: it must keep
    working even if the program folder is removed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Host', 'Client')][string]$Role = 'Host'
)

$ErrorActionPreference = 'SilentlyContinue'

$Root    = Join-Path $env:ProgramData 'PrinterShareSetup'
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'watchdog.log'
$CfgFile = Join-Path $Root 'watchdog.json'

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-WD {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] [{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Role, $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

# Keep the log from growing without bound.
try {
    if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 2MB)) {
        $keep = Get-Content -LiteralPath $LogFile -Tail 2000
        Set-Content -LiteralPath $LogFile -Value $keep -Encoding UTF8
    }
} catch { }

$cfg = $null
if (Test-Path -LiteralPath $CfgFile) {
    try { $cfg = Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json } catch { }
}

$repairs = 0

# --------------------------------------------------------------------------
# 1. The spooler must be running. Everything else depends on it.
# --------------------------------------------------------------------------
$svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Write-WD 'Print spooler was stopped - starting it' 'WARN'
    try {
        Start-Service -Name Spooler -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-WD 'Print spooler started' 'OK'
        $repairs++
    } catch {
        Write-WD "Print spooler would not start: $($_.Exception.Message)" 'FAIL'
    }
}

if ($Role -eq 'Host') {

    # ----------------------------------------------------------------------
    # 2. Re-assert sharing. A driver update or a Windows feature update can
    #    silently clear the Shared flag.
    # ----------------------------------------------------------------------
    if ($cfg -and $cfg.SharedPrinters) {
        foreach ($item in @($cfg.SharedPrinters)) {
            # Stored as "PrinterName|ShareName"
            $parts = "$item".Split('|')
            if ($parts.Count -lt 2) { continue }
            $pName = $parts[0]
            $sName = $parts[1]

            $p = Get-Printer -Name $pName -ErrorAction SilentlyContinue
            if (-not $p) {
                Write-WD "Printer '$pName' is no longer installed on this PC" 'WARN'
                continue
            }
            if (-not $p.Shared -or $p.ShareName -ne $sName) {
                try {
                    Set-Printer -Name $pName -Shared $true -ShareName $sName -Published $false -ErrorAction Stop
                    Write-WD "Re-shared '$pName' as '$sName'" 'OK'
                    $repairs++
                } catch {
                    Write-WD "Could not re-share '$pName': $($_.Exception.Message)" 'FAIL'
                }
            }
        }
    }

    # ----------------------------------------------------------------------
    # 3. Clear jobs that have been jammed long enough to block the queue for
    #    everyone else. Only genuinely stuck jobs, never a job that is printing.
    # ----------------------------------------------------------------------
    $cutoff = (Get-Date).AddMinutes(-20)
    foreach ($p in (Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'Local' })) {
        $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
        foreach ($j in $jobs) {
            $isBad = ("$($j.JobStatus)" -match 'Error|Blocked|Deleting|Offline')
            $isOld = ($j.SubmittedTime -and $j.SubmittedTime -lt $cutoff)
            if ($isBad -and $isOld) {
                try {
                    Remove-PrintJob -InputObject $j -ErrorAction Stop
                    Write-WD "Removed stuck job $($j.Id) ('$($j.DocumentName)') on '$($p.Name)'" 'OK'
                    $repairs++
                } catch { }
            }
        }
    }

    # ----------------------------------------------------------------------
    # 4. Sharing services drift back to Manual after some updates.
    # ----------------------------------------------------------------------
    foreach ($n in @('LanmanServer', 'FDResPub', 'fdPHost')) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') {
            try {
                Set-Service -Name $n -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name $n -ErrorAction Stop
                Write-WD "Restarted service '$n'" 'OK'
                $repairs++
            } catch { }
        }
    }

} else {

    # ----------------------------------------------------------------------
    # Client: restore any connection that dropped. Runs in the signed-in
    # user's own profile, which is where printer connections live.
    # ----------------------------------------------------------------------
    if ($cfg -and $cfg.Connections) {
        $existing = @(Get-Printer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        foreach ($c in @($cfg.Connections)) {
            $path = "$c"
            if (-not $path) { continue }
            if ($existing -contains $path) { continue }

            $server = $path.TrimStart('\').Split('\')[0]
            $up = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
            if (-not $up) {
                Write-WD "Print server '$server' is not reachable right now - will retry later" 'INFO'
                continue
            }
            try {
                Add-Printer -ConnectionName $path -ErrorAction Stop
                Write-WD "Reconnected '$path'" 'OK'
                $repairs++
            } catch {
                Write-WD "Could not reconnect '$path': $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

if ($repairs -gt 0) {
    Write-WD "Finished - $repairs repair(s) applied" 'OK'
} else {
    # Always leave a heartbeat. Without one the log stays empty while
    # everything is healthy, and an empty log is indistinguishable from a
    # helper that never ran or died on startup - which is the one thing
    # someone opening this file is trying to find out.
    Write-WD 'Checked - nothing needed fixing' 'OK'
}
exit 0
