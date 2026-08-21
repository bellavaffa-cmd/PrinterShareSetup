<#
    ClientSetup.ps1 - connects this PC to printers shared by a print server.
    Depends on Common.ps1 being dot-sourced first.
#>

function Test-PSSHostReachable {
    param([Parameter(Mandatory = $true)][string]$ServerName)
    $clean = $ServerName.Trim().TrimStart('\')
    try {
        $r = Test-NetConnection -ComputerName $clean -Port 445 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($r.TcpTestSucceeded) {
            Write-PSSLog "Print server '$clean' is reachable on port 445" 'OK'
            return $true
        }
        Write-PSSLog "'$clean' answered a ping but not file/printer sharing on port 445. Check the firewall on the server." 'FAIL'
        return $false
    } catch {
        Write-PSSLog "Cannot reach '$clean': $($_.Exception.Message)" 'FAIL'
        return $false
    }
}

function Get-PSSRemoteShares {
    <#
        Lists shared printers on a print server. Tries three methods because
        any one of them can be blocked depending on how the server is locked down.
    #>
    param([Parameter(Mandatory = $true)][string]$ServerName)

    $clean  = $ServerName.Trim().TrimStart('\')
    $found  = @()

    # Method 1 - the print RPC interface. Richest data when it works.
    try {
        $remote = Get-Printer -ComputerName $clean -ErrorAction Stop | Where-Object { $_.Shared }
        foreach ($p in $remote) {
            $found += [pscustomobject]@{
                ShareName      = $p.ShareName
                PrinterName    = $p.Name
                DriverName     = $p.DriverName
                ConnectionPath = "\\$clean\$($p.ShareName)"
            }
        }
        if ($found.Count -gt 0) {
            Write-PSSLog "Found $($found.Count) shared printer(s) on '$clean'" 'OK'
            return $found
        }
    } catch {
        Write-PSSLog 'Print RPC query unavailable, trying WMI' 'INFO'
    }

    # Method 2 - WMI.
    try {
        $wmi = Get-CimInstance -ClassName Win32_Printer -ComputerName $clean -ErrorAction Stop |
               Where-Object { $_.Shared }
        foreach ($p in $wmi) {
            $found += [pscustomobject]@{
                ShareName      = $p.ShareName
                PrinterName    = $p.Name
                DriverName     = $p.DriverName
                ConnectionPath = "\\$clean\$($p.ShareName)"
            }
        }
        if ($found.Count -gt 0) {
            Write-PSSLog "Found $($found.Count) shared printer(s) on '$clean' via WMI" 'OK'
            return $found
        }
    } catch {
        Write-PSSLog 'WMI query unavailable, trying SMB browse' 'INFO'
    }

    # Method 3 - SMB browse. Works even when remote management is off.
    try {
        $raw = & "$env:SystemRoot\System32\net.exe" view "\\$clean" 2>&1
        foreach ($line in $raw) {
            $text = "$line"
            if ($text -match '^\s*(\S+)\s+Print\s') {
                $share = $Matches[1]
                $found += [pscustomobject]@{
                    ShareName      = $share
                    PrinterName    = $share
                    DriverName     = '(unknown - browse only)'
                    ConnectionPath = "\\$clean\$share"
                }
            }
        }
        if ($found.Count -gt 0) {
            Write-PSSLog "Found $($found.Count) shared printer(s) on '$clean' by browsing" 'OK'
            return $found
        }
    } catch { }

    Write-PSSLog "No shared printers could be listed on '$clean'. You can still type a share path in manually." 'WARN'
    return $found
}

function Set-PSSPointAndPrintPolicy {
    <#
        Mode 'Safe'   - allow driver installs only from named servers, and only
                        package-aware (v4) drivers. Keeps the PrintNightmare
                        hardening intact. Preferred.
        Mode 'Compat' - the classic "no admin prompt on connect" behaviour.
                        Needed for older v3-only drivers. Weakens driver-install
                        protection, so it is opt-in and the user is told why.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Safe', 'Compat')][string]$Mode,
        [Parameter(Mandatory = $true)][string[]]$Servers
    )

    $pkgKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PackagePointAndPrint'
    $pnpKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
    $listKey = Join-Path $pkgKey 'ListofServers'

    $names = @()
    foreach ($s in $Servers) {
        $n = $s.Trim().TrimStart('\')
        if ($n) { $names += $n }
    }
    if ($names.Count -eq 0) {
        Write-PSSLog 'No server names supplied for the Point and Print policy' 'FAIL'
        return $false
    }

    if ($Mode -eq 'Safe') {
        Write-PSSLog 'Applying the approved-server driver policy (recommended)' 'STEP'
        Set-PSSRegValue -Path $pkgKey -Name 'PackagePointAndPrintOnly' -Value 1 -Type DWord `
            -Because 'only package-aware drivers' | Out-Null
        Set-PSSRegValue -Path $pkgKey -Name 'PackagePointAndPrintServerList' -Value 1 -Type DWord `
            -Because 'restrict to an approved server list' | Out-Null

        if (-not (Test-Path -LiteralPath $listKey)) {
            New-Item -Path $listKey -Force | Out-Null
            # Journal the key itself so undo can take the empty key away, not
            # just the values inside it.
            Add-PSSJournalEntry -Kind 'RegistryKey' -Data @{ Path = $listKey }
        }
        foreach ($n in $names) {
            Set-PSSRegValue -Path $listKey -Name $n -Value $n -Type String -Because 'approved print server' | Out-Null
        }
        Write-PSSLog "Approved print servers: $($names -join ', ')" 'OK'
    } else {
        Write-PSSLog 'Applying compatibility mode for older (v3) printer drivers' 'STEP'
        Write-PSSLog 'This lets standard users install drivers from the servers listed below. Only the listed servers are trusted.' 'WARN'

        Set-PSSRegValue -Path $pnpKey -Name 'Restricted' -Value 1 -Type DWord | Out-Null
        Set-PSSRegValue -Path $pnpKey -Name 'TrustedServers' -Value 1 -Type DWord `
            -Because 'trust only the named servers' | Out-Null
        Set-PSSRegValue -Path $pnpKey -Name 'ServerList' -Value ($names -join ';') -Type String | Out-Null
        Set-PSSRegValue -Path $pnpKey -Name 'InForest' -Value 0 -Type DWord | Out-Null
        Set-PSSRegValue -Path $pnpKey -Name 'NoWarningNoElevationOnInstall' -Value 1 -Type DWord `
            -Because 'no admin prompt when first connecting' | Out-Null
        Set-PSSRegValue -Path $pnpKey -Name 'UpdatePromptSettings' -Value 2 -Type DWord `
            -Because 'no admin prompt on driver update' | Out-Null
        Set-PSSRegValue -Path $pnpKey -Name 'RestrictDriverInstallationToAdministrators' -Value 0 -Type DWord `
            -Because 'allow standard users to receive the shared driver' | Out-Null
    }

    return $true
}

function Add-PSSStoredCredential {
    <#
        Stores a credential for the print server so a workgroup client never
        gets a login prompt mid-print.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $clean = $ServerName.Trim().TrimStart('\')
    try {
        $r = & "$env:SystemRoot\System32\cmdkey.exe" "/add:$clean" "/user:$UserName" "/pass:$Password" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Add-PSSJournalEntry -Kind 'Credential' -Data @{ Target = $clean }
            Write-PSSLog "Saved credentials for '$clean'" 'OK'
            return $true
        }
        Write-PSSLog "cmdkey failed: $r" 'WARN'
        return $false
    } catch {
        Write-PSSLog "Could not save credentials: $($_.Exception.Message)" 'FAIL'
        return $false
    }
}

function Connect-PSSSharedPrinter {
    param(
        [Parameter(Mandatory = $true)][string]$ConnectionPath,
        [switch]$SetDefault
    )
    try {
        $existing = Get-Printer -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $ConnectionPath }
        if ($existing) {
            Write-PSSLog "Already connected: $ConnectionPath" 'OK'
        } else {
            Add-Printer -ConnectionName $ConnectionPath -ErrorAction Stop
            Add-PSSJournalEntry -Kind 'Connection' -Data @{ Path = $ConnectionPath }
            Write-PSSLog "Connected: $ConnectionPath" 'OK'
        }

        if ($SetDefault) {
            try {
                # WQL needs each backslash doubled. Use String.Replace - in a
                # -replace *replacement* string a backslash is literal, which
                # makes the escaping impossible to get right that way.
                $wql = $ConnectionPath.Replace('\', '\\').Replace("'", "\'")
                $p = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$wql'" -ErrorAction Stop
                if ($p) {
                    Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter -ErrorAction Stop | Out-Null
                    Write-PSSLog "Set as the default printer: $ConnectionPath" 'OK'
                } else {
                    Write-PSSLog "Could not find '$ConnectionPath' to make it the default" 'WARN'
                }
            } catch {
                Write-PSSLog "Could not set the default printer: $($_.Exception.Message)" 'WARN'
            }
        }
        return $true
    } catch {
        Write-PSSLog "Could not connect to $ConnectionPath : $($_.Exception.Message)" 'FAIL'
        Write-PSSLog 'If this says access denied or a driver is required, run the tool again and tick "Compatibility mode for older drivers", or install the printer driver on this PC first.' 'INFO'
        return $false
    }
}

function Set-PSSDefaultPrinterLock {
    <#
        Windows moves the default printer to whatever was used last. On a shared
        setup that means jobs land on the wrong printer. Turning it off is the
        single most-appreciated client-side fix.
    #>
    Set-PSSRegValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' `
        -Name 'LegacyDefaultPrinterMode' -Value 1 -Type DWord `
        -Because 'stop Windows changing the default printer on its own' | Out-Null
    return $true
}

function Test-PSSElevatedAsDifferentUser {
    <#
        Printer connections live in the user's own profile. If the UAC prompt was
        satisfied with a different admin account, the connection would land in
        that account instead of the person's. Detect and warn.
    #>
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $interactive = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($interactive -and $me -and ($interactive -ne $me)) {
            return $true
        }
    } catch { }
    return $false
}

function Invoke-PSSClientSetup {
    <#
        $Connections is an array of connection paths, e.g. "\\PRINTPC\Laser_1"
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][string[]]$Connections,
        [hashtable]$Options = @{}
    )

    $mode        = 'Safe'
    if ($Options['CompatDrivers']) { $mode = 'Compat' }
    $defaultPath = [string]$Options['DefaultPrinter']
    $optLock     = -not ($Options.ContainsKey('LockDefault') -and -not $Options['LockDefault'])
    $optWatchdog = [bool]$Options['Watchdog']
    $credUser    = [string]$Options['CredentialUser']
    $credPass    = [string]$Options['CredentialPassword']

    $clean     = $ServerName.Trim().TrimStart('\')
    $connected = @()

    Write-PSSLog '=== Connecting this PC to the shared printers ===' 'STEP'

    if (Test-PSSElevatedAsDifferentUser) {
        Write-PSSLog 'This tool is running as a different account than the one signed in. Printer connections are per-user, so they will be added for the admin account, not the signed-in user. Install the keep-alive helper (it reconnects at each logon) or run this tool from the signed-in account.' 'WARN'
    }

    Write-PSSLog 'Step 1 of 5: checking the server' 'STEP'
    Test-PSSHostReachable -ServerName $clean | Out-Null

    Write-PSSLog 'Step 2 of 5: spooler health' 'STEP'
    Set-PSSService -Name 'Spooler' -StartupType Automatic -Start -Friendly 'Print Spooler' | Out-Null
    Set-PSSServiceRecovery -Name 'Spooler' | Out-Null

    Write-PSSLog 'Step 3 of 5: driver installation policy' 'STEP'
    Set-PSSPointAndPrintPolicy -Mode $mode -Servers @($clean) | Out-Null

    if ($credUser -and $credPass) {
        Add-PSSStoredCredential -ServerName $clean -UserName $credUser -Password $credPass | Out-Null
    }

    Write-PSSLog 'Step 4 of 5: connecting printers' 'STEP'
    foreach ($c in $Connections) {
        $isDefault = ($defaultPath -and ($c -eq $defaultPath))
        if (Connect-PSSSharedPrinter -ConnectionPath $c -SetDefault:$isDefault) {
            $connected += $c
        }
    }

    Write-PSSLog 'Step 5 of 5: default printer behaviour' 'STEP'
    if ($optLock) { Set-PSSDefaultPrinterLock | Out-Null }

    if ($optWatchdog) {
        Install-PSSWatchdog -Role 'Client' -ServerName $clean -Connections $Connections | Out-Null
    }

    Save-PSSJournal -Label 'client' | Out-Null

    Write-PSSLog "=== Connected $($connected.Count) of $($Connections.Count) printer(s) ===" 'STEP'
    return $connected
}
