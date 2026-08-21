<#
    Common.ps1 - shared helpers for PrinterShareSetup
    Logging, elevation, tracked registry/service writes with a rollback journal.
    Targets Windows PowerShell 5.1 (no PS7-only syntax).
#>

$script:PSSRoot      = Join-Path $env:ProgramData 'PrinterShareSetup'
$script:PSSLogDir    = Join-Path $script:PSSRoot 'logs'
$script:PSSRollback  = Join-Path $script:PSSRoot 'rollback'
$script:PSSLogFile   = $null
$script:LogCallback  = $null
$script:Journal      = New-Object System.Collections.ArrayList

function Initialize-PSSEnvironment {
    foreach ($d in @($script:PSSRoot, $script:PSSLogDir, $script:PSSRollback)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $script:PSSLogFile = Join-Path $script:PSSLogDir ("run_$stamp.log")
    $script:Journal.Clear()
}

function Get-PSSLogFile { return $script:PSSLogFile }
function Get-PSSRoot    { return $script:PSSRoot }

function Register-PSSLogCallback {
    param([scriptblock]$Callback)
    $script:LogCallback = $Callback
}

function Write-PSSLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'FAIL', 'STEP')][string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    if ($script:PSSLogFile) {
        try { Add-Content -LiteralPath $script:PSSLogFile -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:LogCallback) {
        try { & $script:LogCallback $Message $Level } catch { }
    } else {
        switch ($Level) {
            'OK'   { Write-Host $line -ForegroundColor Green }
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'FAIL' { Write-Host $line -ForegroundColor Red }
            'STEP' { Write-Host $line -ForegroundColor Cyan }
            default { Write-Host $line }
        }
    }
}

function Test-PSSAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --------------------------------------------------------------------------
# Rollback journal
# --------------------------------------------------------------------------

function Add-PSSJournalEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,   # Registry | Service | Printer | Powercfg | Task | Port
        [Parameter(Mandatory = $true)][hashtable]$Data
    )
    $entry = @{ Kind = $Kind; Data = $Data; When = (Get-Date).ToString('o') }
    [void]$script:Journal.Add($entry)
}

function Save-PSSJournal {
    param([string]$Label = 'run')
    if ($script:Journal.Count -eq 0) { return $null }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $path  = Join-Path $script:PSSRollback ("$Label`_$stamp.json")
    try {
        $script:Journal | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
        # Start a fresh journal so a later run in the same session does not
        # bundle these entries into its own rollback point.
        $script:Journal.Clear()
        Write-PSSLog "Rollback point saved: $([IO.Path]::GetFileName($path))" 'INFO'
        return $path
    } catch {
        Write-PSSLog "Could not save rollback point: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-PSSLatestJournal {
    if (-not (Test-Path -LiteralPath $script:PSSRollback)) { return $null }
    $f = Get-ChildItem -LiteralPath $script:PSSRollback -Filter '*.json' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $f
}

# --------------------------------------------------------------------------
# Registry helpers (tracked)
# --------------------------------------------------------------------------

function Set-PSSRegValue {
    <#
        Sets a registry value, recording the prior state so it can be undone.
        Type: DWord | String | MultiString | ExpandString | QWord
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'String', 'MultiString', 'ExpandString', 'QWord')][string]$Type = 'DWord',
        [string]$Because = ''
    )
    try {
        $existed    = $false
        $old        = $null
        $keyCreated = $false

        if (Test-Path -LiteralPath $Path) {
            $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $prop -and $null -ne $prop.$Name) {
                $existed = $true
                $old     = $prop.$Name
            }
        } else {
            # Record that the key itself did not exist, so undo can remove it.
            $keyCreated = $true
            New-Item -Path $Path -Force | Out-Null
        }

        if ($existed -and ($old -is [int] -or $old -is [string]) -and "$old" -eq "$Value") {
            Write-PSSLog "Already set: $Name = $Value" 'INFO'
            return $true
        }

        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Add-PSSJournalEntry -Kind 'Registry' -Data @{
            Path = $Path; Name = $Name; Existed = $existed; Old = $old; Type = $Type
            KeyCreated = $keyCreated
        }
        $suffix = ''
        if ($Because) { $suffix = " ($Because)" }
        Write-PSSLog "Set $Name = $Value$suffix" 'OK'
        return $true
    } catch {
        Write-PSSLog "Failed to set $Path\$Name : $($_.Exception.Message)" 'FAIL'
        return $false
    }
}

function Get-PSSRegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$Name
}

# --------------------------------------------------------------------------
# Service helpers (tracked)
# --------------------------------------------------------------------------

function Set-PSSService {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType = 'Automatic',
        [switch]$Start,
        [string]$Friendly = ''
    )
    $label = $Name
    if ($Friendly) { $label = "$Friendly ($Name)" }

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-PSSLog "Service not present on this system: $label" 'WARN'
        return $false
    }

    try {
        $wmi     = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        $oldMode = 'Unknown'
        if ($wmi) { $oldMode = $wmi.StartMode }
        $oldState = $svc.Status.ToString()

        Add-PSSJournalEntry -Kind 'Service' -Data @{ Name = $Name; OldStartMode = $oldMode; OldState = $oldState }

        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-PSSLog "$label startup set to $StartupType" 'OK'

        if ($Start -and $svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
            Write-PSSLog "$label started" 'OK'
        }
        return $true
    } catch {
        Write-PSSLog "Could not configure $label : $($_.Exception.Message)" 'FAIL'
        return $false
    }
}

function Set-PSSServiceRecovery {
    <#
        Configures Windows Service Recovery so the service auto-restarts on crash.
        This is what keeps the print spooler from staying dead after a fault.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$ResetSeconds = 86400
    )
    try {
        $scArgs = @('failure', $Name, 'reset=', "$ResetSeconds", 'actions=', 'restart/5000/restart/10000/restart/30000')
        $out    = & "$env:SystemRoot\System32\sc.exe" @scArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-PSSLog "$Name recovery set to auto-restart (5s / 10s / 30s)" 'OK'
            return $true
        }
        Write-PSSLog "sc.exe failure returned $LASTEXITCODE : $out" 'WARN'
        return $false
    } catch {
        Write-PSSLog "Could not set recovery for $Name : $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# --------------------------------------------------------------------------
# Misc
# --------------------------------------------------------------------------

function Invoke-PSSNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Describe = ''
    )
    try {
        $out = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            if ($Describe) { Write-PSSLog $Describe 'OK' }
            return @{ Success = $true; Output = ($out -join "`n") }
        }
        Write-PSSLog "$FilePath exited $code : $($out -join ' ')" 'WARN'
        return @{ Success = $false; Output = ($out -join "`n") }
    } catch {
        Write-PSSLog "$FilePath failed: $($_.Exception.Message)" 'FAIL'
        return @{ Success = $false; Output = $_.Exception.Message }
    }
}

function ConvertTo-PSSShareName {
    <#
        Produces a share name that every Windows client can reach:
        no spaces, no reserved characters, <= 40 chars.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $s = $Name -replace "[\\/:\*\?`"<>\|,;\[\]\+=']", ''
    $s = $s -replace '\s+', '_'
    $s = $s -replace '_+', '_'
    $s = $s.Trim('_')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('_') }
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'Printer' }
    return $s
}

function Test-PSSVirtualPrinter {
    param([Parameter(Mandatory = $true)]$Printer)
    $virtualNames = @(
        'Microsoft Print to PDF', 'Microsoft XPS Document Writer', 'Fax',
        'OneNote', 'OneNote (Desktop)', 'OneNote for Windows 10',
        'Send To OneNote', 'Adobe PDF', 'Print to PDF'
    )
    foreach ($v in $virtualNames) {
        if ($Printer.Name -like "*$v*") { return $true }
    }
    if ($Printer.DriverName -like '*XPS*' -or $Printer.PortName -like 'nul*') { return $true }
    return $false
}

function Get-PSSHostIPv4 {
    try {
        $addr = Get-NetIPConfiguration -ErrorAction Stop |
                Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } |
                Select-Object -First 1
        if ($addr) {
            return [pscustomobject]@{
                IPAddress = $addr.IPv4Address.IPAddress
                Interface = $addr.InterfaceAlias
                Dhcp      = ($addr.NetIPv4Interface.Dhcp -eq 'Enabled')
            }
        }
    } catch { }
    return $null
}

function Test-PSSProtectedPrintMode {
    <#
        Windows 11 24H2 "Windows Protected Print Mode" (WPP) blocks classic
        v3 drivers AND printer sharing entirely. Detect it so we can warn
        instead of silently producing a share nobody can use.
    #>
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP'
    )
    foreach ($p in $paths) {
        foreach ($n in @('WindowsProtectedPrintMode', 'WindowsProtectedPrintGroupPolicyState')) {
            $v = Get-PSSRegValue -Path $p -Name $n
            if ($null -ne $v -and [int]$v -ge 1) { return $true }
        }
    }
    return $false
}
