<#
    Maintenance.ps1 - watchdog install/remove, health check, queue repair, undo.
    Depends on Common.ps1 being dot-sourced first.
#>

$script:PSSHostTaskName   = 'PrinterShareSetup-HostKeepAlive'
$script:PSSClientTaskName = 'PrinterShareSetup-ClientReconnect'

function Get-PSSWatchdogConfigPath {
    return (Join-Path (Get-PSSRoot) 'watchdog.json')
}

function Get-PSSWatchdogScriptPath {
    $installed = Join-Path (Get-PSSRoot) 'Watchdog.ps1'
    if (Test-Path -LiteralPath $installed) { return $installed }
    return $null
}

function Publish-PSSWatchdogScript {
    <#
        Copies Watchdog.ps1 out of the install folder into ProgramData so the
        scheduled task keeps working even if the program folder is moved.
    #>
    $source = Join-Path $PSScriptRoot 'Watchdog.ps1'
    if (-not (Test-Path -LiteralPath $source)) {
        $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Watchdog.ps1'
    }
    if (-not (Test-Path -LiteralPath $source)) {
        Write-PSSLog 'Watchdog.ps1 not found next to the program files' 'FAIL'
        return $null
    }
    $dest = Join-Path (Get-PSSRoot) 'Watchdog.ps1'
    try {
        Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
        return $dest
    } catch {
        Write-PSSLog "Could not stage the watchdog script: $($_.Exception.Message)" 'FAIL'
        return $null
    }
}

function Install-PSSWatchdog {
    <#
        Host   : runs as SYSTEM at startup and every 15 minutes. Keeps the
                 spooler alive, re-asserts the shares, clears jammed jobs.
        Client : runs at every user logon and every 30 minutes in that user's
                 own context, restoring any printer connection that dropped.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Host', 'Client')][string]$Role,
        [string]$ServerName = '',
        [string[]]$Connections = @(),
        [string[]]$SharedPrinters = @()
    )

    $script = Publish-PSSWatchdogScript
    if (-not $script) { return $false }

    # Persist what the watchdog should enforce.
    $cfgPath = Get-PSSWatchdogConfigPath
    $cfg = @{ Role = $Role; ServerName = $ServerName; Connections = $Connections; SharedPrinters = $SharedPrinters }
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $old = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($Role -eq 'Host'   -and $old.Connections)    { $cfg.Connections    = @($old.Connections) }
            if ($Role -eq 'Client' -and $old.SharedPrinters) { $cfg.SharedPrinters = @($old.SharedPrinters) }
            if ($Role -eq 'Client' -and $old.Role -eq 'Host') { $cfg.Role = 'Both' }
            if ($Role -eq 'Host'   -and $old.Role -eq 'Client') { $cfg.Role = 'Both' }
        } catch { }
    }
    try {
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    } catch {
        Write-PSSLog "Could not write the watchdog configuration: $($_.Exception.Message)" 'FAIL'
        return $false
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    if ($Role -eq 'Host') {
        $taskName = $script:PSSHostTaskName
        $action   = New-ScheduledTaskAction -Execute $psExe `
                        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Role Host"
        # No -RepetitionDuration: an absent duration is what Task Scheduler
        # reads as "Indefinitely". Passing [TimeSpan]::MaxValue serialises to a
        # duration the task XML rejects outright ("contains a value which is
        # incorrectly formatted or out of range"), and so does [TimeSpan]::Zero.
        $triggers = @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes 15))
        )
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        $taskName = $script:PSSClientTaskName
        $action   = New-ScheduledTaskAction -Execute $psExe `
                        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Role Client"
        $triggers = @(
            (New-ScheduledTaskTrigger -AtLogOn),
            (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes 30))
        )
        # Runs in each interactive user's own profile, which is where printer
        # connections actually live.
        $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings `
            -Description 'Keeps shared printers available. Installed by PrinterShareSetup.' `
            -Force -ErrorAction Stop | Out-Null
        Add-PSSJournalEntry -Kind 'Task' -Data @{ Name = $taskName }
        Write-PSSLog "Keep-alive helper installed ($taskName)" 'OK'
        return $true
    } catch {
        Write-PSSLog "Could not install the keep-alive helper: $($_.Exception.Message)" 'FAIL'
        return $false
    }
}

function Uninstall-PSSWatchdog {
    $removed = 0
    foreach ($t in @($script:PSSHostTaskName, $script:PSSClientTaskName)) {
        $existing = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($existing) {
            try {
                Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
                Write-PSSLog "Removed keep-alive helper: $t" 'OK'
                $removed++
            } catch {
                Write-PSSLog "Could not remove $t : $($_.Exception.Message)" 'WARN'
            }
        }
    }
    if ($removed -eq 0) { Write-PSSLog 'No keep-alive helper was installed' 'INFO' }
    return $removed
}

function Test-PSSWatchdogInstalled {
    foreach ($t in @($script:PSSHostTaskName, $script:PSSClientTaskName)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# --------------------------------------------------------------------------
# Health check and repair
# --------------------------------------------------------------------------

function Invoke-PSSHealthCheck {
    Write-PSSLog '=== Health check ===' 'STEP'

    $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-PSSLog 'Print spooler is running' 'OK'
    } else {
        Write-PSSLog 'Print spooler is NOT running' 'FAIL'
    }

    if (Test-PSSProtectedPrintMode) {
        Write-PSSLog 'Windows Protected Print Mode is ON - printer sharing cannot work while it is enabled' 'FAIL'
    } else {
        Write-PSSLog 'Windows Protected Print Mode is off' 'OK'
    }

    try {
        $pub = Get-NetConnectionProfile -ErrorAction Stop | Where-Object { $_.NetworkCategory -eq 'Public' }
        if ($pub) {
            Write-PSSLog "Network '$($pub[0].Name)' is set to Public - sharing is blocked on Public networks" 'FAIL'
        } else {
            Write-PSSLog 'Network profile allows sharing' 'OK'
        }
    } catch { }

    try {
        $shared = Get-Printer -ErrorAction Stop | Where-Object { $_.Shared -and $_.Type -eq 'Local' }
        if ($shared) {
            foreach ($s in $shared) {
                Write-PSSLog "Shared: \\$env:COMPUTERNAME\$($s.ShareName)  ->  $($s.Name)" 'OK'
            }
        } else {
            Write-PSSLog 'No printers are currently shared from this PC' 'INFO'
        }

        $conns = Get-Printer -ErrorAction Stop | Where-Object { $_.Type -eq 'Connection' }
        foreach ($c in $conns) {
            Write-PSSLog "Connected to: $($c.Name)" 'OK'
        }
    } catch {
        Write-PSSLog "Could not read the printer list: $($_.Exception.Message)" 'FAIL'
    }

    try {
        $stuck = Get-Printer -ErrorAction Stop | ForEach-Object {
            Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue
        } | Where-Object { $_.JobStatus -match 'Error|Blocked|Offline|PaperOut|Deleting' }
        if ($stuck) {
            Write-PSSLog "$(@($stuck).Count) print job(s) are stuck - use Clear stuck jobs to remove them" 'WARN'
        } else {
            Write-PSSLog 'No stuck print jobs' 'OK'
        }
    } catch { }

    # Read the AC index specifically. "Minimum Possible Setting: 0x00000000"
    # appears in this output unconditionally, so a naive match always passes.
    try {
        $sleep = & "$env:SystemRoot\System32\powercfg.exe" /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1
        $m = [regex]::Match(($sleep -join "`n"), 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
        if ($m.Success) {
            $acIndex = [Convert]::ToInt64($m.Groups[1].Value, 16)
            if ($acIndex -eq 0) {
                Write-PSSLog 'Sleep on AC power is disabled' 'OK'
            } else {
                Write-PSSLog "This PC sleeps after $([math]::Round($acIndex / 60)) minute(s) on AC power - re-run the print server setup to fix" 'WARN'
            }
        } else {
            Write-PSSLog 'Could not read the sleep timeout' 'INFO'
        }
    } catch {
        Write-PSSLog 'Could not read the sleep timeout' 'INFO'
    }

    if (Test-PSSWatchdogInstalled) {
        Write-PSSLog 'Keep-alive helper is installed' 'OK'
    } else {
        Write-PSSLog 'Keep-alive helper is not installed' 'INFO'
    }

    Write-PSSLog '=== Health check complete ===' 'STEP'
    return $true
}

function Clear-PSSStuckJobs {
    <#
        Stops the spooler, empties the spool folder, restarts. The blunt fix
        that resolves the majority of "nothing prints any more" calls.
    #>
    param([switch]$PurgeSpoolFolder)

    try {
        $removed = 0
        foreach ($p in (Get-Printer -ErrorAction Stop)) {
            $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
            foreach ($j in $jobs) {
                try {
                    Remove-PrintJob -InputObject $j -ErrorAction Stop
                    $removed++
                } catch { }
            }
        }
        Write-PSSLog "Cancelled $removed queued job(s)" 'OK'
    } catch {
        Write-PSSLog "Could not enumerate print jobs: $($_.Exception.Message)" 'WARN'
    }

    if ($PurgeSpoolFolder) {
        try {
            Stop-Service -Name Spooler -Force -ErrorAction Stop
            Write-PSSLog 'Spooler stopped' 'INFO'
            $spool = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            if (Test-Path -LiteralPath $spool) {
                Get-ChildItem -LiteralPath $spool -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                Write-PSSLog 'Spool folder emptied' 'OK'
            }
        } catch {
            Write-PSSLog "Could not empty the spool folder: $($_.Exception.Message)" 'WARN'
        } finally {
            try {
                Start-Service -Name Spooler -ErrorAction Stop
                Write-PSSLog 'Spooler restarted' 'OK'
            } catch {
                Write-PSSLog "Spooler failed to restart: $($_.Exception.Message)" 'FAIL'
            }
        }
    }
    return $true
}

# --------------------------------------------------------------------------
# Undo
# --------------------------------------------------------------------------

function Invoke-PSSUndo {
    param([string]$JournalPath = '')

    if (-not $JournalPath) {
        $f = Get-PSSLatestJournal
        if (-not $f) {
            Write-PSSLog 'There is nothing to undo - no previous run was recorded' 'WARN'
            return $false
        }
        $JournalPath = $f.FullName
    }

    Write-PSSLog "=== Undoing $([IO.Path]::GetFileName($JournalPath)) ===" 'STEP'

    try {
        $entries = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
    } catch {
        Write-PSSLog "Could not read the rollback file: $($_.Exception.Message)" 'FAIL'
        return $false
    }

    # Reverse order so later changes are undone first.
    $list = @($entries)
    [array]::Reverse($list)

    foreach ($e in $list) {
        $d = $e.Data
        switch ($e.Kind) {
            'Registry' {
                try {
                    if ($d.Existed) {
                        New-ItemProperty -LiteralPath $d.Path -Name $d.Name -Value $d.Old `
                            -PropertyType $d.Type -Force -ErrorAction Stop | Out-Null
                        Write-PSSLog "Restored $($d.Name) to its previous value" 'OK'
                    } else {
                        Remove-ItemProperty -LiteralPath $d.Path -Name $d.Name -Force -ErrorAction SilentlyContinue
                        Write-PSSLog "Removed $($d.Name)" 'OK'

                        # If this tool also created the key, and nothing else has
                        # been put in it since, take the key away too.
                        $createdKey = $false
                        try { $createdKey = [bool]$d.KeyCreated } catch { }
                        if ($createdKey -and (Test-Path -LiteralPath $d.Path)) {
                            $item = Get-Item -LiteralPath $d.Path -ErrorAction SilentlyContinue
                            $valueCount = 0
                            $childCount = 0
                            if ($item) {
                                $valueCount = @($item.GetValueNames()).Count
                                $childCount = @(Get-ChildItem -LiteralPath $d.Path -ErrorAction SilentlyContinue).Count
                            }
                            if ($valueCount -eq 0 -and $childCount -eq 0) {
                                Remove-Item -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue
                                Write-PSSLog "Removed the empty key $($d.Path)" 'OK'
                            }
                        }
                    }
                } catch {
                    Write-PSSLog "Could not restore $($d.Path)\$($d.Name): $($_.Exception.Message)" 'WARN'
                }
            }
            'RegistryKey' {
                try {
                    if (Test-Path -LiteralPath $d.Path) {
                        $item = Get-Item -LiteralPath $d.Path -ErrorAction SilentlyContinue
                        $vals = 0
                        $kids = 0
                        if ($item) {
                            $vals = @($item.GetValueNames()).Count
                            $kids = @(Get-ChildItem -LiteralPath $d.Path -ErrorAction SilentlyContinue).Count
                        }
                        if ($vals -eq 0 -and $kids -eq 0) {
                            Remove-Item -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue
                            Write-PSSLog "Removed the empty key $($d.Path)" 'OK'
                        }
                    }
                } catch { }
            }
            'Powercfg' {
                try {
                    if ($d.Kind -eq 'timeout') {
                        # Prefer the exact seconds path. /change rounds to whole
                        # minutes, which turns a 30-second timeout into 0 = never.
                        $sub = "$($d.SubGroup)"
                        $gid = "$($d.SettingGuid)"
                        if ($sub -and $gid) {
                            Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
                                -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $sub, $gid, "$($d.OldSeconds)") | Out-Null
                            Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
                                -Arguments @('/setactive', 'SCHEME_CURRENT') | Out-Null
                            Write-PSSLog "Restored $($d.Setting) to $($d.OldSeconds) second(s)" 'OK'
                        } else {
                            # Rollback point written before the subgroup was recorded.
                            $mins = [int]([math]::Round([double]$d.OldSeconds / 60))
                            Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
                                -Arguments @('/change', $d.Setting, "$mins") `
                                -Describe "Restored $($d.Setting) to $mins minute(s)" | Out-Null
                        }
                    } else {
                        Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
                            -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $d.SubGroup, $d.Setting, "$($d.OldSeconds)") | Out-Null
                        Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
                            -Arguments @('/setactive', 'SCHEME_CURRENT') | Out-Null
                        Write-PSSLog 'Restored the USB selective suspend setting' 'OK'
                    }
                } catch {
                    Write-PSSLog "Could not restore power setting $($d.Setting): $($_.Exception.Message)" 'WARN'
                }
            }
            'Service' {
                try {
                    $mode = "$($d.OldStartMode)"
                    $map  = @{ 'Auto' = 'Automatic'; 'Automatic' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }
                    if ($map.ContainsKey($mode)) {
                        Set-Service -Name $d.Name -StartupType $map[$mode] -ErrorAction Stop
                        Write-PSSLog "Restored service $($d.Name) to $($map[$mode])" 'OK'
                    }
                } catch {
                    Write-PSSLog "Could not restore service $($d.Name): $($_.Exception.Message)" 'WARN'
                }
            }
            'Printer' {
                try {
                    if ($d.OldShared) {
                        Set-Printer -Name $d.Name -Shared $true -ShareName $d.OldShareName `
                            -Published ([bool]$d.OldPublished) -ErrorAction Stop
                    } else {
                        Set-Printer -Name $d.Name -Shared $false -ErrorAction Stop
                    }
                    Write-PSSLog "Restored sharing state of '$($d.Name)'" 'OK'

                    $mode = "$($d.OldRenderingMode)"
                    if ($mode -and $mode -ne 'None') {
                        Set-Printer -Name $d.Name -RenderingMode $mode -ErrorAction SilentlyContinue
                        Write-PSSLog "Restored rendering mode of '$($d.Name)' to $mode" 'OK'
                    }

                    $sddl = "$($d.OldPermissionSDDL)"
                    if ($sddl) {
                        Set-Printer -Name $d.Name -PermissionSDDL $sddl -ErrorAction SilentlyContinue
                        Write-PSSLog "Restored permissions on '$($d.Name)'" 'OK'
                    }
                } catch {
                    Write-PSSLog "Could not restore printer '$($d.Name)': $($_.Exception.Message)" 'WARN'
                }
            }
            'Connection' {
                try {
                    Remove-Printer -Name $d.Path -ErrorAction Stop
                    Write-PSSLog "Removed connection $($d.Path)" 'OK'
                } catch {
                    Write-PSSLog "Could not remove connection $($d.Path): $($_.Exception.Message)" 'WARN'
                }
            }
            'Credential' {
                try {
                    & "$env:SystemRoot\System32\cmdkey.exe" "/delete:$($d.Target)" | Out-Null
                    Write-PSSLog "Removed saved credentials for $($d.Target)" 'OK'
                } catch { }
            }
            'Task' {
                try {
                    Unregister-ScheduledTask -TaskName $d.Name -Confirm:$false -ErrorAction Stop
                    Write-PSSLog "Removed scheduled task $($d.Name)" 'OK'
                } catch { }
            }
            'NetProfile' {
                try {
                    $old = "$($d.OldCategory)"
                    if ($old) {
                        Set-NetConnectionProfile -InterfaceIndex $d.InterfaceIndex `
                            -NetworkCategory $old -ErrorAction Stop
                        Write-PSSLog "Network '$($d.Name)' set back to $old" 'OK'
                    }
                } catch {
                    Write-PSSLog "Could not restore the network profile for '$($d.Name)': $($_.Exception.Message)" 'WARN'
                }
            }
            'Firewall' {
                $off = 0
                foreach ($rn in @($d.RuleNames)) {
                    if (-not "$rn") { continue }
                    try {
                        Set-NetFirewallRule -Name "$rn" -Enabled False -ErrorAction Stop
                        $off++
                    } catch { }
                }
                if ($off -gt 0) {
                    Write-PSSLog "Disabled $off '$($d.Label)' firewall rule(s) that were turned on" 'OK'
                }
            }
        }
    }

    try {
        Restart-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    } catch { }

    # Consume the rollback point. Without this Get-PSSLatestJournal keeps
    # handing back the same file, so a second Undo replays the same restore
    # instead of stepping further back, and every earlier rollback point is
    # unreachable from the UI for good.
    try {
        $used = $JournalPath + '.undone'
        if (Test-Path -LiteralPath $used) { Remove-Item -LiteralPath $used -Force -ErrorAction SilentlyContinue }
        Rename-Item -LiteralPath $JournalPath -NewName ([IO.Path]::GetFileName($used)) -Force -ErrorAction Stop
    } catch {
        Write-PSSLog "Could not mark the rollback point as used: $($_.Exception.Message)" 'WARN'
    }

    # Running the setup twice makes two rollback points, and one Undo only
    # walks back one of them. Say so, rather than letting a screen full of
    # "Restored ..." lines imply the PC is back to how it started.
    $remaining = 0
    try {
        $remaining = @(Get-ChildItem -LiteralPath (Split-Path -Parent $JournalPath) `
                        -Filter '*.json' -ErrorAction SilentlyContinue).Count
    } catch { }
    if ($remaining -gt 0) {
        Write-PSSLog "$remaining earlier rollback point(s) remain. This undid only the most recent run - use Undo again to step further back." 'WARN'
    }

    Write-PSSLog '=== Undo complete ===' 'STEP'
    return $true
}
