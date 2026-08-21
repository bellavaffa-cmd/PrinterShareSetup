<#
    HostSetup.ps1 - configures this PC as the print server.
    Depends on Common.ps1 being dot-sourced first.
#>

function Get-PSSLocalPrinters {
    <#
        Returns real, physical local queues - the ones worth sharing.
    #>
    $result = @()
    try {
        $printers = Get-Printer -ErrorAction Stop
    } catch {
        Write-PSSLog "Could not enumerate printers: $($_.Exception.Message)" 'FAIL'
        return $result
    }

    foreach ($p in $printers) {
        if ($p.Type -ne 'Local') { continue }
        if (Test-PSSVirtualPrinter -Printer $p) { continue }

        $suggested = $p.ShareName
        if ([string]::IsNullOrWhiteSpace($suggested)) {
            $suggested = ConvertTo-PSSShareName -Name $p.Name
        }

        $result += [pscustomobject]@{
            Name          = $p.Name
            DriverName    = $p.DriverName
            PortName      = $p.PortName
            Shared        = [bool]$p.Shared
            ShareName     = $suggested
            SuggestedName = $suggested
            Attachment    = Get-PSSPortAttachment -PortName $p.PortName
        }
    }
    return $result
}

function Get-PSSPortAttachment {
    <#
        'Network' means the printer already has its own address on the LAN
        (WSD or a TCP/IP port), so every PC can reach it directly and sharing
        it through this PC is optional. 'Direct' means USB/LPT/dot4 - those
        only exist while this PC is on, which is what sharing is for.
    #>
    param([string]$PortName)
    if ([string]::IsNullOrWhiteSpace($PortName)) { return 'Unknown' }
    if ($PortName -match '^WSD-' -or
        $PortName -match '^IP_' -or
        $PortName -match '^\d{1,3}(\.\d{1,3}){3}' -or
        $PortName -match '^(TCPPort|StandardTCPPort)') { return 'Network' }
    if ($PortName -match '^(USB|LPT|COM|DOT4)') { return 'Direct' }
    return 'Unknown'
}

function Enable-PSSPrinterShare {
    param(
        [Parameter(Mandatory = $true)][string]$PrinterName,
        [Parameter(Mandatory = $true)][string]$ShareName,
        [switch]$ServerSideRendering,
        [switch]$GrantEveryonePrint
    )

    $clean = ConvertTo-PSSShareName -Name $ShareName
    if ($clean -ne $ShareName) {
        Write-PSSLog "Share name '$ShareName' adjusted to '$clean' for client compatibility" 'WARN'
    }

    try {
        $p = Get-Printer -Name $PrinterName -ErrorAction Stop

        # Capture the security descriptor too - Set-PSSPrinter -PermissionSDDL
        # replaces it wholesale, so without this the original ACL is lost.
        $oldSddl = $null
        $oldMode = "$($p.RenderingMode)"
        try {
            $full = Get-Printer -Name $PrinterName -Full -ErrorAction Stop
            $oldSddl = $full.PermissionSDDL
            if ("$($full.RenderingMode)") { $oldMode = "$($full.RenderingMode)" }
        } catch { }

        Add-PSSJournalEntry -Kind 'Printer' -Data @{
            Name = $PrinterName; OldShared = [bool]$p.Shared; OldShareName = $p.ShareName
            OldRenderingMode = $oldMode; OldPublished = [bool]$p.Published
            OldPermissionSDDL = $oldSddl
        }

        # Published = $false keeps the queue out of Active Directory. Publishing to a
        # directory that is missing or slow to answer is a classic source of long stalls.
        Set-Printer -Name $PrinterName -Shared $true -ShareName $clean -Published $false -ErrorAction Stop
        Write-PSSLog "Shared '$PrinterName' as \\$env:COMPUTERNAME\$clean" 'OK'
    } catch {
        Write-PSSLog "Could not share '$PrinterName': $($_.Exception.Message)" 'FAIL'
        return $null
    }

    if ($ServerSideRendering) {
        # Force the host to render every job. Slower per job, but it removes the
        # entire class of failures caused by clients running a different driver
        # version than the server.
        try {
            Set-Printer -Name $PrinterName -RenderingMode SSR -ErrorAction Stop
            Write-PSSLog "'$PrinterName' set to render on the server" 'OK'
        } catch {
            Write-PSSLog "Could not set rendering mode on '$PrinterName': $($_.Exception.Message)" 'WARN'
        }
    }

    if ($GrantEveryonePrint) {
        # Default printer security descriptor plus an explicit Print grant to
        # Everyone (WD). Admins and Power Users keep full management rights.
        $sddl = 'O:BAG:DUD:(A;;SWRC;;;WD)(A;OIIO;GA;;;CO)(A;;LCSWSDRCWDWO;;;BA)(A;OIIO;GA;;;BA)(A;;SWRC;;;AU)'
        try {
            Set-Printer -Name $PrinterName -PermissionSDDL $sddl -ErrorAction Stop
            Write-PSSLog "'$PrinterName' print permission granted to all users" 'OK'
        } catch {
            Write-PSSLog "Could not set permissions on '$PrinterName': $($_.Exception.Message)" 'WARN'
        }
    }

    return "\\$env:COMPUTERNAME\$clean"
}

function Set-PSSNetworkProfilePrivate {
    <#
        File and printer sharing is blocked on Public networks. Flip only the
        adapters that actually carry the LAN.
    #>
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction Stop |
                    Where-Object { $_.NetworkCategory -eq 'Public' }
        if (-not $profiles) {
            Write-PSSLog 'Network already on a Private/Domain profile' 'OK'
            return $true
        }
        foreach ($pr in $profiles) {
            Set-NetConnectionProfile -InterfaceIndex $pr.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-PSSLog "Network '$($pr.Name)' switched from Public to Private" 'OK'
        }
        return $true
    } catch {
        Write-PSSLog "Could not change network profile: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Enable-PSSSharingFirewall {
    $groups = @(
        @{ Id = '@FirewallAPI.dll,-28502'; Label = 'File and Printer Sharing' },
        @{ Id = '@FirewallAPI.dll,-32752'; Label = 'Network Discovery' }
    )
    $ok = $true
    foreach ($g in $groups) {
        $enabled = 0
        # Enable-NetFirewallRule has no -Profile filter, so select the rules
        # first. Public-profile rules are deliberately left untouched.
        foreach ($lookup in @(
                @{ Param = 'DisplayGroup'; Value = $g.Label },
                @{ Param = 'Group';        Value = $g.Id }
            )) {
            try {
                if ($lookup.Param -eq 'DisplayGroup') {
                    $rules = Get-NetFirewallRule -DisplayGroup $lookup.Value -ErrorAction Stop
                } else {
                    $rules = Get-NetFirewallRule -Group $lookup.Value -ErrorAction Stop
                }
                # Rules scoped only to Public are left alone. Windows ships some
                # rules covering "Private, Public" together and a rule cannot be
                # enabled for one of its profiles, so those are enabled as-is -
                # the same thing Windows does from the Sharing control panel.
                $wanted  = $rules | Where-Object { "$($_.Profile)" -ne 'Public' }
                $skipped = @($rules).Count - @($wanted).Count
                if ($wanted) {
                    $wanted | Enable-NetFirewallRule -ErrorAction Stop
                    $enabled = @($wanted).Count
                    if ($skipped -gt 0) {
                        Write-PSSLog "$skipped Public-only rule(s) left disabled" 'INFO'
                    }
                    break
                }
            } catch {
                continue
            }
        }

        if ($enabled -gt 0) {
            Write-PSSLog "Firewall: $enabled '$($g.Label)' rule(s) enabled" 'OK'
        } else {
            Write-PSSLog "Could not enable the firewall rules for '$($g.Label)'" 'WARN'
            $ok = $false
        }
    }
    return $ok
}

function Enable-PSSDiscoveryServices {
    <#
        These four are what make the host appear under Network in File Explorer
        and answer discovery requests promptly. When fdPHost/FDResPub are
        stopped, clients fall back to slow broadcast lookups.
    #>
    $svcs = @(
        @{ Name = 'Spooler';       Friendly = 'Print Spooler';                      Mode = 'Automatic' },
        @{ Name = 'LanmanServer';  Friendly = 'Server';                             Mode = 'Automatic' },
        @{ Name = 'FDResPub';      Friendly = 'Function Discovery Resource Publication'; Mode = 'Automatic' },
        @{ Name = 'fdPHost';       Friendly = 'Function Discovery Provider Host';    Mode = 'Automatic' },
        @{ Name = 'SSDPSRV';       Friendly = 'SSDP Discovery';                      Mode = 'Automatic' },
        @{ Name = 'upnphost';      Friendly = 'UPnP Device Host';                    Mode = 'Automatic' }
    )
    foreach ($s in $svcs) {
        Set-PSSService -Name $s.Name -StartupType $s.Mode -Start -Friendly $s.Friendly | Out-Null
    }
    Set-PSSServiceRecovery -Name 'Spooler' | Out-Null
    return $true
}

function Get-PSSPowerAcIndex {
    <#
        Reads the current AC index for a power setting, in seconds.
        Returns $null when it cannot be determined.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SubGroup,
        [Parameter(Mandatory = $true)][string]$Setting
    )
    try {
        $out = & "$env:SystemRoot\System32\powercfg.exe" /query SCHEME_CURRENT $SubGroup $Setting 2>&1
        $m = [regex]::Match(($out -join "`n"), 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)')
        if ($m.Success) { return [Convert]::ToInt64($m.Groups[1].Value, 16) }
    } catch { }
    return $null
}

function Set-PSSAlwaysOnPower {
    <#
        The single most common cause of "the shared printer disappeared":
        the host went to sleep, or Fast Startup left the spooler in a
        half-resumed state.
    #>
    Write-PSSLog 'Applying always-on power settings' 'STEP'

    $timeouts = @(
        @{ Flag = 'standby-timeout-ac';   Sub = 'SUB_SLEEP'; Set = 'STANDBYIDLE';   Label = 'Sleep on AC power disabled' },
        @{ Flag = 'hibernate-timeout-ac'; Sub = 'SUB_SLEEP'; Set = 'HIBERNATEIDLE'; Label = 'Hibernate on AC power disabled' },
        @{ Flag = 'disk-timeout-ac';      Sub = 'SUB_DISK';  Set = 'DISKIDLE';      Label = 'Hard disk sleep disabled' }
    )

    foreach ($t in $timeouts) {
        # Record the old value first so "Undo the last run" can put it back.
        $old = Get-PSSPowerAcIndex -SubGroup $t.Sub -Setting $t.Set
        if ($null -ne $old) {
            Add-PSSJournalEntry -Kind 'Powercfg' -Data @{
                Kind = 'timeout'; Setting = $t.Flag; OldSeconds = $old
            }
        }
        Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
            -Arguments @('/change', $t.Flag, '0') -Describe $t.Label | Out-Null
    }

    # USB selective suspend - USB printers "vanish" without this.
    $usbSub = '2a737441-1930-4402-8d77-b2bebba308a3'
    $usbSet = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    $oldUsb = Get-PSSPowerAcIndex -SubGroup $usbSub -Setting $usbSet
    if ($null -ne $oldUsb) {
        Add-PSSJournalEntry -Kind 'Powercfg' -Data @{
            Kind = 'value'; SubGroup = $usbSub; Setting = $usbSet; OldSeconds = $oldUsb
        }
    }
    Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
        -Arguments @('/setacvalueindex', 'SCHEME_CURRENT', $usbSub, $usbSet, '0') `
        -Describe 'USB selective suspend disabled' | Out-Null
    Invoke-PSSNative -FilePath "$env:SystemRoot\System32\powercfg.exe" `
        -Arguments @('/setactive', 'SCHEME_CURRENT') | Out-Null

    # Fast Startup leaves drivers in a stale hibernated state across reboots.
    Set-PSSRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name 'HiberbootEnabled' -Value 0 -Type DWord -Because 'Fast Startup off' | Out-Null

    return $true
}

function Disable-PSSNicPowerSaving {
    <#
        "Allow the computer to turn off this device to save power" on the NIC
        drops the host off the network during idle periods.
    #>
    $any = $false
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        foreach ($a in $adapters) {
            try {
                Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                Write-PSSLog "Power saving disabled on network adapter '$($a.Name)'" 'OK'
                $any = $true
            } catch {
                Write-PSSLog "Adapter '$($a.Name)' does not expose power management (this is normal for some drivers)" 'INFO'
            }
        }
    } catch {
        Write-PSSLog "Could not enumerate network adapters: $($_.Exception.Message)" 'WARN'
    }
    return $any
}

function Optimize-PSSSpooler {
    <#
        Spooler-level tuning that keeps a multi-printer host from wedging.
    #>
    $printKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print'

    # Do not let a single failing job block the queue forever.
    Set-PSSRegValue -Path $printKey -Name 'SchedulerThreadPriority' -Value 1 -Type DWord `
        -Because 'spooler scheduling priority' | Out-Null

    # Suppress the network-printer error balloons that block the spooler thread
    # waiting for a user who is not sitting at the server. This value is read
    # from the Providers subkey, not from Control\Print itself.
    Set-PSSRegValue -Path "$printKey\Providers" -Name 'NetPopup' -Value 0 -Type DWord `
        -Because 'no blocking error popups on the server' | Out-Null

    Set-PSSRegValue -Path $printKey -Name 'BeepEnabled' -Value 0 -Type DWord | Out-Null

    return $true
}

function Get-PSSHostReadiness {
    <#
        Non-destructive pre-flight check. Returns a list of findings to show
        the user before anything is changed.
    #>
    $findings = @()

    if (Test-PSSProtectedPrintMode) {
        $findings += [pscustomobject]@{
            Level   = 'FAIL'
            Message = 'Windows Protected Print Mode is ON. It blocks printer sharing completely. Turn it off in Settings > Bluetooth & devices > Printers & scanners > Windows protected print mode, then reboot and run this again.'
        }
    }

    $ip = Get-PSSHostIPv4
    if ($ip) {
        if ($ip.Dhcp) {
            $findings += [pscustomobject]@{
                Level   = 'WARN'
                Message = "This PC's address ($($ip.IPAddress) on $($ip.Interface)) comes from DHCP and can change. Add a DHCP reservation on your router, or clients may lose the printers after a reboot."
            }
        } else {
            $findings += [pscustomobject]@{
                Level   = 'OK'
                Message = "Static address $($ip.IPAddress) on $($ip.Interface)."
            }
        }
    }

    $wifi = $null
    try {
        $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' }
    } catch { }
    if ($wifi) {
        $findings += [pscustomobject]@{
            Level   = 'WARN'
            Message = 'This PC is on Wi-Fi. A wired connection for the print server is noticeably more reliable and faster for large jobs.'
        }
    }

    $printers = Get-PSSLocalPrinters
    if ($printers.Count -eq 0) {
        $findings += [pscustomobject]@{
            Level   = 'FAIL'
            Message = 'No physical local printers found. Install the printer drivers on this PC first.'
        }
    } else {
        $findings += [pscustomobject]@{
            Level   = 'OK'
            Message = "$($printers.Count) local printer(s) available to share."
        }

        # A printer on a WSD or TCP/IP port already has its own address on the
        # LAN. Sharing it works, but it makes this PC a needless single point
        # of failure - if it sleeps, a printer that was fine goes away.
        $net = @($printers | Where-Object { $_.Attachment -eq 'Network' })
        if ($net.Count -gt 0) {
            $names = ($net | ForEach-Object { $_.Name }) -join ', '
            $findings += [pscustomobject]@{
                Level   = 'INFO'
                Message = "$($net.Count) of these are already on the network by themselves ($names). You can share them, but each PC can also just add them directly - that keeps them working when this PC is off. The ones worth sharing are the USB-connected printers."
            }
        }
    }

    return $findings
}

function Invoke-PSSHostSetup {
    <#
        Runs the full print-server configuration.
        $Selections is an array of @{ PrinterName = ''; ShareName = '' }
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Selections,
        [hashtable]$Options = @{}
    )

    $optPower      = -not ($Options.ContainsKey('AlwaysOn')    -and -not $Options['AlwaysOn'])
    $optFirewall   = -not ($Options.ContainsKey('Firewall')    -and -not $Options['Firewall'])
    $optServices   = -not ($Options.ContainsKey('Services')    -and -not $Options['Services'])
    $optNic        = -not ($Options.ContainsKey('NicPower')    -and -not $Options['NicPower'])
    $optSpooler    = -not ($Options.ContainsKey('SpoolerTune') -and -not $Options['SpoolerTune'])
    $optSSR        = [bool]$Options['ServerSideRendering']
    $optEveryone   = [bool]$Options['GrantEveryone']
    $optWatchdog   = [bool]$Options['Watchdog']

    $shares = @()

    Write-PSSLog '=== Configuring this PC as a print server ===' 'STEP'

    if (Test-PSSProtectedPrintMode) {
        Write-PSSLog 'Windows Protected Print Mode is enabled - sharing will not work until it is turned off. Continuing anyway so the rest is ready.' 'FAIL'
    }

    Write-PSSLog 'Step 1 of 7: network profile' 'STEP'
    Set-PSSNetworkProfilePrivate | Out-Null

    if ($optFirewall) {
        Write-PSSLog 'Step 2 of 7: firewall rules' 'STEP'
        Enable-PSSSharingFirewall | Out-Null
    }

    if ($optServices) {
        Write-PSSLog 'Step 3 of 7: services and spooler recovery' 'STEP'
        Enable-PSSDiscoveryServices | Out-Null
    }

    Write-PSSLog 'Step 4 of 7: sharing printers' 'STEP'
    $watchList = @()
    foreach ($sel in $Selections) {
        $path = Enable-PSSPrinterShare -PrinterName $sel.PrinterName -ShareName $sel.ShareName `
                    -ServerSideRendering:$optSSR -GrantEveryonePrint:$optEveryone
        if ($path) {
            $shares += $path
            $watchList += ('{0}|{1}' -f $sel.PrinterName, (ConvertTo-PSSShareName -Name $sel.ShareName))
        }
    }

    if ($optPower) {
        Write-PSSLog 'Step 5 of 7: power settings' 'STEP'
        Set-PSSAlwaysOnPower | Out-Null
    }

    if ($optNic) {
        Write-PSSLog 'Step 6 of 7: network adapter power management' 'STEP'
        Disable-PSSNicPowerSaving | Out-Null
    }

    if ($optSpooler) {
        Write-PSSLog 'Step 7 of 7: spooler tuning' 'STEP'
        Optimize-PSSSpooler | Out-Null
    }

    if ($optWatchdog) {
        Write-PSSLog 'Installing the keep-alive watchdog' 'STEP'
        Install-PSSWatchdog -Role 'Host' -SharedPrinters $watchList | Out-Null
    }

    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Write-PSSLog 'Print spooler restarted to apply changes' 'OK'
    } catch {
        Write-PSSLog "Could not restart the spooler: $($_.Exception.Message)" 'WARN'
    }

    Save-PSSJournal -Label 'host' | Out-Null

    Write-PSSLog '=== Print server configuration complete ===' 'STEP'
    return $shares
}
