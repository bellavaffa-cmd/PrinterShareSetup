<#
    PrinterShareSetup.ps1
    Sets up Windows printer sharing - one PC hosting several printers for the
    rest of the network - and applies the settings that keep it stable.

    Run elevated. The launcher and the installer shortcut both do that for you.
#>
[CmdletBinding()]
param(
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir 'lib\Common.ps1')
. (Join-Path $ScriptDir 'lib\HostSetup.ps1')
. (Join-Path $ScriptDir 'lib\ClientSetup.ps1')
. (Join-Path $ScriptDir 'lib\Maintenance.ps1')

# The shortcuts launch this hidden, so there is no console to print to.
# Load WinForms up front and say everything through message boxes.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------------------------------------------------
# Elevation
# --------------------------------------------------------------------------
if (-not (Test-PSSAdmin)) {
    if ($NoElevate) {
        [System.Windows.Forms.MessageBox]::Show(
            'This tool needs to run as administrator. Right-click it and choose "Run as administrator".',
            'Printer Share Setup', 'OK', 'Warning') | Out-Null
        exit 1
    }
    try {
        $self = $MyInvocation.MyCommand.Definition
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Verb RunAs `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$self`"", '-NoElevate')
        exit 0
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Printer Share Setup needs administrator rights to change printer and network settings.`r`n`r`nIt was not given them, so nothing has been changed. Start it again and choose Yes at the Windows prompt.",
            'Administrator rights needed', 'OK', 'Warning') | Out-Null
        exit 1
    }
}

Initialize-PSSEnvironment

# --------------------------------------------------------------------------
# Theme
# --------------------------------------------------------------------------
$Theme = @{
    Bg        = [System.Drawing.Color]::FromArgb(248, 250, 252)
    HeaderBg  = [System.Drawing.Color]::FromArgb(30, 41, 59)
    HeaderTx  = [System.Drawing.Color]::FromArgb(248, 250, 252)
    Muted     = [System.Drawing.Color]::FromArgb(100, 116, 139)
    Text      = [System.Drawing.Color]::FromArgb(15, 23, 42)
    Accent    = [System.Drawing.Color]::FromArgb(37, 99, 235)
    AccentTx  = [System.Drawing.Color]::White
    Card      = [System.Drawing.Color]::White
    Border    = [System.Drawing.Color]::FromArgb(203, 213, 225)
    Ok        = [System.Drawing.Color]::FromArgb(21, 128, 61)
    Warn      = [System.Drawing.Color]::FromArgb(180, 83, 9)
    Fail      = [System.Drawing.Color]::FromArgb(185, 28, 28)
    LogBg     = [System.Drawing.Color]::FromArgb(24, 31, 45)
}
$FontBase  = New-Object System.Drawing.Font('Segoe UI', 9.75)
$FontBold  = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$FontH1    = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$FontH2    = New-Object System.Drawing.Font('Segoe UI Semibold', 11.5)
$FontSmall = New-Object System.Drawing.Font('Segoe UI', 8.75)
$FontMono  = New-Object System.Drawing.Font('Consolas', 9)

function New-PSSButton {
    param(
        [string]$Text, [int]$Width = 150, [int]$Height = 34,
        [switch]$Primary, [switch]$Danger
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Width     = $Width
    $b.Height    = $Height
    $b.Font      = $FontBase
    $b.FlatStyle = 'Flat'
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor = $Theme.Accent
        $b.ForeColor = $Theme.AccentTx
        $b.Font      = $FontBold
        $b.FlatAppearance.BorderSize = 0
    } elseif ($Danger) {
        $b.BackColor = $Theme.Card
        $b.ForeColor = $Theme.Fail
        $b.FlatAppearance.BorderColor = $Theme.Border
    } else {
        $b.BackColor = $Theme.Card
        $b.ForeColor = $Theme.Text
        $b.FlatAppearance.BorderColor = $Theme.Border
    }
    return $b
}

function New-PSSLabel {
    param([string]$Text, $Font = $null, $Color = $null, [int]$Width = 700)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.AutoSize  = $false
    $l.Width     = $Width
    $l.Height    = 22
    if ($Font)  { $l.Font = $Font }  else { $l.Font = $FontBase }
    if ($Color) { $l.ForeColor = $Color } else { $l.ForeColor = $Theme.Text }
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-PSSCheck {
    param([string]$Text, [string]$Sub = '', [bool]$Checked = $true, [int]$Width = 820)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Width  = $Width
    $panel.Height = 38
    if ($Sub) { $panel.Height = 46 }

    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text     = $Text
    $cb.Checked  = $Checked
    $cb.Font     = $FontBase
    $cb.ForeColor = $Theme.Text
    $cb.AutoSize = $true
    $cb.Location = New-Object System.Drawing.Point(0, 2)
    $panel.Controls.Add($cb)

    if ($Sub) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text      = $Sub
        $lbl.Font      = $FontSmall
        $lbl.ForeColor = $Theme.Muted
        $lbl.AutoSize  = $false
        $lbl.Width     = $Width - 24
        $lbl.Height    = 20
        $lbl.Location  = New-Object System.Drawing.Point(20, 21)
        $panel.Controls.Add($lbl)
    }

    $panel | Add-Member -NotePropertyName CheckBox -NotePropertyValue $cb -Force
    return $panel
}

# --------------------------------------------------------------------------
# Form shell
# --------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Printer Share Setup'
$form.Size            = New-Object System.Drawing.Size(960, 720)
$form.MinimumSize     = New-Object System.Drawing.Size(880, 640)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $Theme.Bg
$form.Font            = $FontBase

$header = New-Object System.Windows.Forms.Panel
$header.Dock      = 'Top'
$header.Height    = 74
$header.BackColor = $Theme.HeaderBg

$hTitle = New-Object System.Windows.Forms.Label
$hTitle.Text      = 'Printer Share Setup'
$hTitle.Font      = $FontH1
$hTitle.ForeColor = $Theme.HeaderTx
$hTitle.AutoSize  = $true
$hTitle.Location  = New-Object System.Drawing.Point(24, 14)
$header.Controls.Add($hTitle)

$hSub = New-Object System.Windows.Forms.Label
$hSub.Text      = 'Share several printers from one PC, and keep the connection stable'
$hSub.Font      = $FontSmall
$hSub.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$hSub.AutoSize  = $true
$hSub.Location  = New-Object System.Drawing.Point(26, 44)
$header.Controls.Add($hSub)

$hMachine = New-Object System.Windows.Forms.Label
$hMachine.Text      = "This PC: $env:COMPUTERNAME"
$hMachine.Font      = $FontSmall
$hMachine.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$hMachine.AutoSize  = $true
$hMachine.Anchor    = 'Top,Right'
$hMachine.Location  = New-Object System.Drawing.Point(($form.ClientSize.Width - 200), 46)
$header.Controls.Add($hMachine)

$form.Controls.Add($header)

$content = New-Object System.Windows.Forms.Panel
$content.Dock      = 'Fill'
$content.BackColor = $Theme.Bg
$content.Padding   = New-Object System.Windows.Forms.Padding(24, 18, 24, 18)
$form.Controls.Add($content)
$content.BringToFront()

$script:Panels = @{}

function Show-PSSPanel {
    param([string]$Name)
    foreach ($k in $script:Panels.Keys) {
        $script:Panels[$k].Visible = ($k -eq $Name)
    }
    if ($script:Panels.ContainsKey($Name)) {
        $script:Panels[$Name].BringToFront()
    }
}

function New-PSSPanel {
    param([string]$Name)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock      = 'Fill'
    $p.BackColor = $Theme.Bg
    $p.AutoScroll = $true
    $p.Visible   = $false
    $content.Controls.Add($p)
    $script:Panels[$Name] = $p
    return $p
}

# ==========================================================================
# RUN panel (shared log view)
# ==========================================================================
$pnlRun = New-PSSPanel 'Run'

$runTitle = New-PSSLabel 'Working...' $FontH2
$runTitle.Location = New-Object System.Drawing.Point(0, 0)
$runTitle.Width = 700
$pnlRun.Controls.Add($runTitle)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location    = New-Object System.Drawing.Point(0, 34)
$logBox.Size        = New-Object System.Drawing.Size(870, 360)
$logBox.Anchor      = 'Top,Left,Right,Bottom'
$logBox.ReadOnly    = $true
$logBox.BackColor   = $Theme.LogBg
$logBox.ForeColor   = [System.Drawing.Color]::FromArgb(226, 232, 240)
$logBox.Font        = $FontMono
$logBox.BorderStyle = 'None'
$logBox.WordWrap    = $true
$pnlRun.Controls.Add($logBox)

$resultLabel = New-PSSLabel 'Share paths for the other PCs:' $FontBold
$resultLabel.Location = New-Object System.Drawing.Point(0, 402)
$resultLabel.Anchor   = 'Left,Bottom'
$resultLabel.Visible  = $false
$pnlRun.Controls.Add($resultLabel)

$resultBox = New-Object System.Windows.Forms.TextBox
$resultBox.Location    = New-Object System.Drawing.Point(0, 424)
$resultBox.Size        = New-Object System.Drawing.Size(660, 72)
$resultBox.Anchor      = 'Left,Right,Bottom'
$resultBox.Multiline   = $true
$resultBox.ReadOnly    = $true
$resultBox.Font        = $FontMono
$resultBox.BackColor   = $Theme.Card
$resultBox.ScrollBars  = 'Vertical'
$resultBox.Visible     = $false
$pnlRun.Controls.Add($resultBox)

$btnCopy = New-PSSButton 'Copy paths' 130
$btnCopy.Location = New-Object System.Drawing.Point(674, 424)
$btnCopy.Anchor   = 'Right,Bottom'
$btnCopy.Visible  = $false
$btnCopy.Add_Click({
    if ($resultBox.Text) {
        [System.Windows.Forms.Clipboard]::SetText($resultBox.Text)
        $btnCopy.Text = 'Copied'
    }
})
$pnlRun.Controls.Add($btnCopy)

$btnRunBack = New-PSSButton 'Back to start' 150
$btnRunBack.Location = New-Object System.Drawing.Point(0, 510)
$btnRunBack.Anchor   = 'Left,Bottom'
$btnRunBack.Add_Click({ Show-PSSPanel 'Home' })
$pnlRun.Controls.Add($btnRunBack)

$btnOpenLog = New-PSSButton 'Open log file' 150
$btnOpenLog.Location = New-Object System.Drawing.Point(160, 510)
$btnOpenLog.Anchor   = 'Left,Bottom'
$btnOpenLog.Add_Click({
    $lf = Get-PSSLogFile
    if ($lf -and (Test-Path -LiteralPath $lf)) { Start-Process notepad.exe $lf }
})
$pnlRun.Controls.Add($btnOpenLog)

function Add-PSSLogLine {
    param([string]$Message, [string]$Level)
    $color = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $prefix = '   '
    switch ($Level) {
        'OK'   { $color = [System.Drawing.Color]::FromArgb(134, 239, 172); $prefix = ' OK  ' }
        'WARN' { $color = [System.Drawing.Color]::FromArgb(253, 224, 71);  $prefix = ' !   ' }
        'FAIL' { $color = [System.Drawing.Color]::FromArgb(252, 165, 165); $prefix = ' X   ' }
        'STEP' { $color = [System.Drawing.Color]::FromArgb(147, 197, 253); $prefix = '' }
        default{ $prefix = '     ' }
    }
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $color
    if ($Level -eq 'STEP') {
        $logBox.AppendText("`r`n$Message`r`n")
    } else {
        $logBox.AppendText("$prefix$Message`r`n")
    }
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

Register-PSSLogCallback ${function:Add-PSSLogLine}

$script:PSSRunning = $false

function Start-PSSRun {
    param([string]$Title, [scriptblock]$Work)

    # The log pumps DoEvents so the window keeps painting, which also means a
    # second click would re-enter this function and wipe the running log.
    if ($script:PSSRunning) { return }
    $script:PSSRunning = $true

    $runTitle.Text       = $Title
    $logBox.Clear()
    $resultBox.Visible   = $false
    $resultLabel.Visible = $false
    $btnCopy.Visible     = $false
    $btnCopy.Text        = 'Copy paths'
    $btnRunBack.Enabled  = $false
    $btnOpenLog.Enabled  = $false

    Show-PSSPanel 'Run'
    [System.Windows.Forms.Application]::DoEvents()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        & $Work
    } catch {
        Write-PSSLog "Unexpected error: $($_.Exception.Message)" 'FAIL'
    } finally {
        $form.Cursor        = [System.Windows.Forms.Cursors]::Default
        $btnRunBack.Enabled = $true
        $btnOpenLog.Enabled = $true
        $script:PSSRunning  = $false
    }
}

# ==========================================================================
# HOME panel
# ==========================================================================
$pnlHome = New-PSSPanel 'Home'

$homeH = New-PSSLabel 'What would you like to do on this PC?' $FontH2
$homeH.Location = New-Object System.Drawing.Point(0, 4)
$pnlHome.Controls.Add($homeH)

function New-PSSChoiceCard {
    param([string]$Title, [string]$Body, [int]$Y, [scriptblock]$OnClick)
    $card = New-Object System.Windows.Forms.Panel
    $card.Location    = New-Object System.Drawing.Point(0, $Y)
    $card.Size        = New-Object System.Drawing.Size(870, 104)
    $card.Anchor      = 'Top,Left,Right'
    $card.BackColor   = $Theme.Card
    $card.BorderStyle = 'FixedSingle'
    $card.Cursor      = [System.Windows.Forms.Cursors]::Hand

    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title; $t.Font = $FontH2; $t.ForeColor = $Theme.Text
    $t.AutoSize = $true; $t.Location = New-Object System.Drawing.Point(20, 16)
    $card.Controls.Add($t)

    $b = New-Object System.Windows.Forms.Label
    $b.Text = $Body; $b.Font = $FontBase; $b.ForeColor = $Theme.Muted
    $b.AutoSize = $false
    $b.Size = New-Object System.Drawing.Size(820, 46)
    $b.Location = New-Object System.Drawing.Point(21, 44)
    $card.Controls.Add($b)

    $card.Add_Click($OnClick)
    $t.Add_Click($OnClick)
    $b.Add_Click($OnClick)
    return $card
}

$cardHost = New-PSSChoiceCard `
    'Set up this PC as the print server' `
    "Use this on the PC the printers are physically plugged into. It shares the printers you pick and applies the settings that stop them dropping off: no sleep, no USB power-down, firewall openings, spooler auto-recovery." `
    44 { Show-PSSHostPanel }
$pnlHome.Controls.Add($cardHost)

$cardClient = New-PSSChoiceCard `
    'Connect this PC to a shared printer' `
    "Use this on the other PCs in the office or house. It finds the printers being shared, sets the driver policy so nobody gets an admin prompt, and reconnects them automatically after a restart." `
    160 { Show-PSSClientPanel }
$pnlHome.Controls.Add($cardClient)

$cardMaint = New-PSSChoiceCard `
    'Check, repair or undo' `
    "Run a health check, clear a jammed queue, or roll back everything this tool changed." `
    276 { Show-PSSPanel 'Maint' }
$pnlHome.Controls.Add($cardMaint)

$homeFoot = New-PSSLabel '' $FontSmall $Theme.Muted
$homeFoot.Location = New-Object System.Drawing.Point(0, 396)
$homeFoot.Height   = 40
$homeFoot.Width    = 860
$homeFoot.Text     = "Running as administrator. Every change is written to a log and can be undone from the third option above."
$pnlHome.Controls.Add($homeFoot)

# ==========================================================================
# HOST panel
# ==========================================================================
$pnlHost = New-PSSPanel 'Host'

$hostH = New-PSSLabel 'Set up this PC as the print server' $FontH2
$hostH.Location = New-Object System.Drawing.Point(0, 0)
$pnlHost.Controls.Add($hostH)

$hostFindings = New-Object System.Windows.Forms.RichTextBox
$hostFindings.Location    = New-Object System.Drawing.Point(0, 28)
$hostFindings.Size        = New-Object System.Drawing.Size(870, 78)
$hostFindings.Anchor      = 'Top,Left,Right'
$hostFindings.ReadOnly    = $true
$hostFindings.BorderStyle = 'FixedSingle'
$hostFindings.BackColor   = $Theme.Card
$hostFindings.Font        = $FontSmall
$pnlHost.Controls.Add($hostFindings)

$hostGridLbl = New-PSSLabel 'Choose which printers to share. You can edit the share name.' $FontBold
$hostGridLbl.Location = New-Object System.Drawing.Point(0, 114)
$pnlHost.Controls.Add($hostGridLbl)

$hostGrid = New-Object System.Windows.Forms.DataGridView
$hostGrid.Location            = New-Object System.Drawing.Point(0, 138)
$hostGrid.Size                = New-Object System.Drawing.Size(870, 150)
$hostGrid.Anchor              = 'Top,Left,Right'
$hostGrid.BackgroundColor     = $Theme.Card
$hostGrid.BorderStyle         = 'FixedSingle'
$hostGrid.AllowUserToAddRows  = $false
$hostGrid.AllowUserToDeleteRows = $false
$hostGrid.AllowUserToResizeRows = $false
$hostGrid.RowHeadersVisible   = $false
$hostGrid.SelectionMode       = 'CellSelect'
$hostGrid.Font                = $FontBase
$hostGrid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$hostGrid.ColumnHeadersHeight = 30
$hostGrid.EnableHeadersVisualStyles = $false
$hostGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$hostGrid.ColumnHeadersDefaultCellStyle.Font = $FontBold

$colShare = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colShare.HeaderText = 'Share'
$colShare.Name       = 'Share'
$colShare.Width      = 55
[void]$hostGrid.Columns.Add($colShare)

$colPrinter = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPrinter.HeaderText = 'Printer'
$colPrinter.Name       = 'Printer'
$colPrinter.Width      = 250
$colPrinter.ReadOnly   = $true
[void]$hostGrid.Columns.Add($colPrinter)

# A printer already on the network does not really need sharing - showing how
# each one is attached stops people sharing queues that gain nothing by it.
$colAttach = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colAttach.HeaderText = 'Connection'
$colAttach.Name       = 'Attachment'
$colAttach.Width      = 90
$colAttach.ReadOnly   = $true
[void]$hostGrid.Columns.Add($colAttach)

$colShareName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colShareName.HeaderText = 'Share name (what other PCs will see)'
$colShareName.Name       = 'ShareName'
$colShareName.Width      = 260
[void]$hostGrid.Columns.Add($colShareName)

$colDriver = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDriver.HeaderText = 'Driver'
$colDriver.Name       = 'Driver'
$colDriver.Width      = 170
$colDriver.ReadOnly   = $true
[void]$hostGrid.Columns.Add($colDriver)

$pnlHost.Controls.Add($hostGrid)

$hostOptLbl = New-PSSLabel 'Stability settings' $FontBold
$hostOptLbl.Location = New-Object System.Drawing.Point(0, 298)
$pnlHost.Controls.Add($hostOptLbl)

# Two columns of 420px. The width must be passed in, not set afterwards, or the
# sub-label is sized for the default width and paints over the other column.
$optAlwaysOn = New-PSSCheck 'Keep this PC awake and reachable' 'No sleep, no hibernate, no USB power-down, no Fast Startup.' $true 420
$optAlwaysOn.Location = New-Object System.Drawing.Point(0, 320)
$pnlHost.Controls.Add($optAlwaysOn)

$optFirewall = New-PSSCheck 'Open the firewall for sharing' 'Private and domain networks only. Public networks stay closed.' $true 420
$optFirewall.Location = New-Object System.Drawing.Point(0, 366)
$pnlHost.Controls.Add($optFirewall)

$optServices = New-PSSCheck 'Start the spooler and discovery services automatically' 'Includes auto-restart if the spooler ever crashes.' $true 420
$optServices.Location = New-Object System.Drawing.Point(0, 412)
$pnlHost.Controls.Add($optServices)

$optNic = New-PSSCheck 'Stop Windows powering down the network adapter' 'Prevents the PC dropping off the network while idle.' $true 420
$optNic.Location = New-Object System.Drawing.Point(440, 320)
$pnlHost.Controls.Add($optNic)

$optSSR = New-PSSCheck 'Render print jobs on this PC' 'Recommended when the other PCs have mismatched driver versions.' $false 420
$optSSR.Location = New-Object System.Drawing.Point(440, 366)
$pnlHost.Controls.Add($optSSR)

$optEveryone = New-PSSCheck 'Let everyone on the network print' 'Grants Print permission to all users on the network.' $true 420
$optEveryone.Location = New-Object System.Drawing.Point(440, 412)
$pnlHost.Controls.Add($optEveryone)

$optHostWatch = New-PSSCheck 'Install the keep-alive helper (recommended)' 'A background check every 15 minutes that restarts the spooler, re-shares printers and clears jammed jobs.' $true 860
$optHostWatch.Location = New-Object System.Drawing.Point(0, 458)
$pnlHost.Controls.Add($optHostWatch)

$btnHostApply = New-PSSButton 'Apply settings' 170 38 -Primary
$btnHostApply.Location = New-Object System.Drawing.Point(0, 512)
$pnlHost.Controls.Add($btnHostApply)

$btnHostBack = New-PSSButton 'Back' 110 38
$btnHostBack.Location = New-Object System.Drawing.Point(182, 512)
$btnHostBack.Add_Click({ Show-PSSPanel 'Home' })
$pnlHost.Controls.Add($btnHostBack)

function Show-PSSHostPanel {
    $hostGrid.Rows.Clear()
    $hostFindings.Clear()

    foreach ($f in (Get-PSSHostReadiness)) {
        $hostFindings.SelectionStart  = $hostFindings.TextLength
        $hostFindings.SelectionLength = 0
        switch ($f.Level) {
            'OK'   { $hostFindings.SelectionColor = $Theme.Ok;    $hostFindings.AppendText("OK   ") }
            'WARN' { $hostFindings.SelectionColor = $Theme.Warn;  $hostFindings.AppendText("!    ") }
            'FAIL' { $hostFindings.SelectionColor = $Theme.Fail;  $hostFindings.AppendText("X    ") }
            'INFO' { $hostFindings.SelectionColor = $Theme.Muted; $hostFindings.AppendText("i    ") }
        }
        $hostFindings.SelectionColor = $Theme.Text
        $hostFindings.AppendText("$($f.Message)`r`n")
    }

    foreach ($p in (Get-PSSLocalPrinters)) {
        $i = $hostGrid.Rows.Add()
        # Pre-tick only the printers that actually need sharing. A network
        # printer is already reachable, so leave that choice to the user.
        $hostGrid.Rows[$i].Cells['Share'].Value      = ($p.Attachment -ne 'Network')
        $hostGrid.Rows[$i].Cells['Printer'].Value    = $p.Name
        $hostGrid.Rows[$i].Cells['ShareName'].Value  = $p.ShareName
        $hostGrid.Rows[$i].Cells['Driver'].Value     = $p.DriverName
        switch ($p.Attachment) {
            'Network' { $hostGrid.Rows[$i].Cells['Attachment'].Value = 'Network' }
            'Direct'  { $hostGrid.Rows[$i].Cells['Attachment'].Value = 'USB cable' }
            default   { $hostGrid.Rows[$i].Cells['Attachment'].Value = '' }
        }
    }

    Show-PSSPanel 'Host'
}

$btnHostApply.Add_Click({
    $hostGrid.EndEdit()
    $sel = @()
    foreach ($row in $hostGrid.Rows) {
        if ($row.Cells['Share'].Value -eq $true) {
            $sn = "$($row.Cells['ShareName'].Value)"
            if ([string]::IsNullOrWhiteSpace($sn)) { $sn = "$($row.Cells['Printer'].Value)" }
            $sel += @{ PrinterName = "$($row.Cells['Printer'].Value)"; ShareName = $sn }
        }
    }
    if ($sel.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Tick at least one printer to share.', 'Nothing selected', 'OK', 'Information') | Out-Null
        return
    }

    $opts = @{
        AlwaysOn            = $optAlwaysOn.CheckBox.Checked
        Firewall            = $optFirewall.CheckBox.Checked
        Services            = $optServices.CheckBox.Checked
        NicPower            = $optNic.CheckBox.Checked
        SpoolerTune         = $true
        ServerSideRendering = $optSSR.CheckBox.Checked
        GrantEveryone       = $optEveryone.CheckBox.Checked
        Watchdog            = $optHostWatch.CheckBox.Checked
    }

    $work = {
        $paths = Invoke-PSSHostSetup -Selections $sel -Options $opts
        if ($paths -and $paths.Count -gt 0) {
            $resultLabel.Text    = 'Share paths for the other PCs:'
            $resultBox.Text      = ($paths -join "`r`n")
            $resultBox.Visible   = $true
            $resultLabel.Visible = $true
            $btnCopy.Visible     = $true
            Write-PSSLog 'On each other PC, run this tool and choose "Connect this PC to a shared printer".' 'INFO'
        }
    }.GetNewClosure()

    Start-PSSRun -Title 'Configuring this PC as the print server' -Work $work
})

# ==========================================================================
# CLIENT panel
# ==========================================================================
$pnlClient = New-PSSPanel 'Client'

$cliH = New-PSSLabel 'Connect this PC to a shared printer' $FontH2
$cliH.Location = New-Object System.Drawing.Point(0, 0)
$pnlClient.Controls.Add($cliH)

$cliServerLbl = New-PSSLabel 'Name of the PC sharing the printers' $FontBold
$cliServerLbl.Location = New-Object System.Drawing.Point(0, 34)
$pnlClient.Controls.Add($cliServerLbl)

$cliServer = New-Object System.Windows.Forms.TextBox
$cliServer.Location = New-Object System.Drawing.Point(0, 58)
$cliServer.Size     = New-Object System.Drawing.Size(300, 28)
$cliServer.Font     = $FontBase
$pnlClient.Controls.Add($cliServer)

$cliServerHint = New-PSSLabel 'The computer name, or its IP address.' $FontSmall $Theme.Muted
$cliServerHint.Location = New-Object System.Drawing.Point(0, 88)
$pnlClient.Controls.Add($cliServerHint)

$btnDiscover = New-PSSButton 'Find printers' 150 28 -Primary
$btnDiscover.Location = New-Object System.Drawing.Point(312, 58)
$pnlClient.Controls.Add($btnDiscover)

$btnAddManual = New-PSSButton 'Add by path...' 150 28
$btnAddManual.Location = New-Object System.Drawing.Point(474, 58)
$pnlClient.Controls.Add($btnAddManual)

$cliGrid = New-Object System.Windows.Forms.DataGridView
$cliGrid.Location            = New-Object System.Drawing.Point(0, 114)
$cliGrid.Size                = New-Object System.Drawing.Size(870, 150)
$cliGrid.Anchor              = 'Top,Left,Right'
$cliGrid.BackgroundColor     = $Theme.Card
$cliGrid.BorderStyle         = 'FixedSingle'
$cliGrid.AllowUserToAddRows  = $false
$cliGrid.AllowUserToDeleteRows = $false
$cliGrid.RowHeadersVisible   = $false
$cliGrid.Font                = $FontBase
$cliGrid.ColumnHeadersHeight = 30
$cliGrid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$cliGrid.EnableHeadersVisualStyles = $false
$cliGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$cliGrid.ColumnHeadersDefaultCellStyle.Font = $FontBold

$cc1 = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$cc1.HeaderText = 'Add'; $cc1.Name = 'Add'; $cc1.Width = 50
[void]$cliGrid.Columns.Add($cc1)

$cc2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$cc2.HeaderText = 'Shared printer'; $cc2.Name = 'Share'; $cc2.Width = 220; $cc2.ReadOnly = $true
[void]$cliGrid.Columns.Add($cc2)

$cc3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$cc3.HeaderText = 'Driver'; $cc3.Name = 'Driver'; $cc3.Width = 250; $cc3.ReadOnly = $true
[void]$cliGrid.Columns.Add($cc3)

$cc4 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$cc4.HeaderText = 'Full path'; $cc4.Name = 'Path'; $cc4.Width = 320; $cc4.ReadOnly = $true
[void]$cliGrid.Columns.Add($cc4)

$pnlClient.Controls.Add($cliGrid)

$cliDefLbl = New-PSSLabel 'Make this one the default printer' $FontBold
$cliDefLbl.Location = New-Object System.Drawing.Point(0, 274)
$pnlClient.Controls.Add($cliDefLbl)

$cliDefault = New-Object System.Windows.Forms.ComboBox
$cliDefault.Location      = New-Object System.Drawing.Point(0, 296)
$cliDefault.Size          = New-Object System.Drawing.Size(400, 28)
$cliDefault.DropDownStyle = 'DropDownList'
$cliDefault.Font          = $FontBase
$pnlClient.Controls.Add($cliDefault)

$optLockDefault = New-PSSCheck 'Stop Windows changing the default printer' 'Windows normally switches it to whatever you printed to last.' $true 420
$optLockDefault.Location = New-Object System.Drawing.Point(0, 332)
$pnlClient.Controls.Add($optLockDefault)

$optCompat = New-PSSCheck 'Compatibility mode for older drivers' 'Tick only if connecting fails with a driver error.' $false 420
$optCompat.Location = New-Object System.Drawing.Point(440, 332)
$pnlClient.Controls.Add($optCompat)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000
$tip.InitialDelay = 400
$tip.SetToolTip($optCompat.CheckBox,
    "Relaxes Windows' driver-install protection so a standard user can receive" + [Environment]::NewLine +
    "the printer driver from the server. It applies only to the server named" + [Environment]::NewLine +
    "above - every other server stays fully protected." + [Environment]::NewLine + [Environment]::NewLine +
    "Leave this off unless connecting has already failed.")

$optCliWatch = New-PSSCheck 'Reconnect these printers at every sign-in (recommended)' 'Restores any connection that drops after a restart or a network outage.' $true 860
$optCliWatch.Location = New-Object System.Drawing.Point(0, 382)
$pnlClient.Controls.Add($optCliWatch)

$optCred = New-PSSCheck 'Save a sign-in for the print server' 'Only needed if the server asks for a username and password.' $false 420
$optCred.Location = New-Object System.Drawing.Point(0, 428)
$pnlClient.Controls.Add($optCred)

$cliUserLbl = New-PSSLabel 'User name' $FontSmall $Theme.Muted 180
$cliUserLbl.Location = New-Object System.Drawing.Point(440, 432)
$cliUserLbl.Height   = 16
$pnlClient.Controls.Add($cliUserLbl)

$cliUser = New-Object System.Windows.Forms.TextBox
$cliUser.Location = New-Object System.Drawing.Point(440, 450)
$cliUser.Size     = New-Object System.Drawing.Size(180, 26)
$cliUser.Enabled  = $false
$pnlClient.Controls.Add($cliUser)

$cliPassLbl = New-PSSLabel 'Password' $FontSmall $Theme.Muted 180
$cliPassLbl.Location = New-Object System.Drawing.Point(628, 432)
$cliPassLbl.Height   = 16
$pnlClient.Controls.Add($cliPassLbl)

$cliPass = New-Object System.Windows.Forms.TextBox
$cliPass.Location     = New-Object System.Drawing.Point(628, 450)
$cliPass.Size         = New-Object System.Drawing.Size(180, 26)
$cliPass.UseSystemPasswordChar = $true
$cliPass.Enabled      = $false
$pnlClient.Controls.Add($cliPass)

$optCred.CheckBox.Add_CheckedChanged({
    $cliUser.Enabled = $optCred.CheckBox.Checked
    $cliPass.Enabled = $optCred.CheckBox.Checked
})

$btnCliApply = New-PSSButton 'Connect printers' 170 38 -Primary
$btnCliApply.Location = New-Object System.Drawing.Point(0, 490)
$pnlClient.Controls.Add($btnCliApply)

$btnCliBack = New-PSSButton 'Back' 110 38
$btnCliBack.Location = New-Object System.Drawing.Point(182, 490)
$btnCliBack.Add_Click({ Show-PSSPanel 'Home' })
$pnlClient.Controls.Add($btnCliBack)

function Show-PSSClientPanel {
    $cliGrid.Rows.Clear()
    $cliDefault.Items.Clear()
    if ([string]::IsNullOrWhiteSpace($cliServer.Text)) {
        $cliServer.Text = ''
    }
    Show-PSSPanel 'Client'
    [void]$cliServer.Focus()
}

$btnDiscover.Add_Click({
    $srv = $cliServer.Text.Trim()
    if (-not $srv) {
        [System.Windows.Forms.MessageBox]::Show('Type the name of the PC that has the printers attached.', 'Which PC?', 'OK', 'Information') | Out-Null
        return
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # Anything the user typed in by hand survives a re-search.
    $manual = @()
    foreach ($row in $cliGrid.Rows) {
        if ("$($row.Cells['Driver'].Value)" -eq '(added manually)') {
            $manual += [pscustomobject]@{
                Checked = ($row.Cells['Add'].Value -eq $true)
                Share   = "$($row.Cells['Share'].Value)"
                Path    = "$($row.Cells['Path'].Value)"
            }
        }
    }

    $cliGrid.Rows.Clear()
    $cliDefault.Items.Clear()
    [void]$cliDefault.Items.Add('(leave the default alone)')
    $cliDefault.SelectedIndex = 0

    foreach ($m in $manual) {
        $i = $cliGrid.Rows.Add()
        $cliGrid.Rows[$i].Cells['Add'].Value    = $m.Checked
        $cliGrid.Rows[$i].Cells['Share'].Value  = $m.Share
        $cliGrid.Rows[$i].Cells['Driver'].Value = '(added manually)'
        $cliGrid.Rows[$i].Cells['Path'].Value   = $m.Path
        [void]$cliDefault.Items.Add($m.Path)
    }

    try {
        $shares = Get-PSSRemoteShares -ServerName $srv
        foreach ($s in $shares) {
            if ($manual | Where-Object { $_.Path -eq $s.ConnectionPath }) { continue }
            $i = $cliGrid.Rows.Add()
            $cliGrid.Rows[$i].Cells['Add'].Value    = $true
            $cliGrid.Rows[$i].Cells['Share'].Value  = $s.ShareName
            $cliGrid.Rows[$i].Cells['Driver'].Value = $s.DriverName
            $cliGrid.Rows[$i].Cells['Path'].Value   = $s.ConnectionPath
            [void]$cliDefault.Items.Add($s.ConnectionPath)
        }
        if ($shares.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No shared printers were found on '$srv'.`r`n`r`nCheck that:`r`n  - the server PC is switched on and awake`r`n  - you ran the print server setup on it`r`n  - both PCs are on the same network`r`n`r`nYou can still use ""Add by path..."" and type the full path, for example \\$srv\Laser1",
                'Nothing found', 'OK', 'Warning') | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not search '$srv'.`r`n`r`n$($_.Exception.Message)", 'Search failed', 'OK', 'Warning') | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$btnAddManual.Add_Click({
    $srv = $cliServer.Text.Trim().TrimStart('\')
    $seed = '\\SERVERPC\PrinterShare'
    if ($srv) { $seed = "\\$srv\" }
    $path = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Type the full path of the shared printer.`r`n`r`nFormat:  \\ComputerName\ShareName",
        'Add a printer by path', $seed)
    $path = "$path".Trim()
    if (-not $path) { return }
    if ($path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        [System.Windows.Forms.MessageBox]::Show(
            'That does not look like a share path. It should be \\ComputerName\ShareName.',
            'Check the path', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $cliServer.Text.Trim()) {
        $cliServer.Text = $path.TrimStart('\').Split('\')[0]
    }
    if ($cliDefault.Items.Count -eq 0) {
        [void]$cliDefault.Items.Add('(leave the default alone)')
        $cliDefault.SelectedIndex = 0
    }
    $i = $cliGrid.Rows.Add()
    $cliGrid.Rows[$i].Cells['Add'].Value    = $true
    $cliGrid.Rows[$i].Cells['Share'].Value  = $path.TrimStart('\').Split('\')[-1]
    $cliGrid.Rows[$i].Cells['Driver'].Value = '(added manually)'
    $cliGrid.Rows[$i].Cells['Path'].Value   = $path
    [void]$cliDefault.Items.Add($path)
})

$btnCliApply.Add_Click({
    $cliGrid.EndEdit()
    $srv = $cliServer.Text.Trim()
    if (-not $srv) {
        [System.Windows.Forms.MessageBox]::Show('Type the name of the PC that has the printers attached.', 'Which PC?', 'OK', 'Information') | Out-Null
        return
    }

    $conns = @()
    foreach ($row in $cliGrid.Rows) {
        if ($row.Cells['Add'].Value -eq $true) {
            $conns += "$($row.Cells['Path'].Value)"
        }
    }
    if ($conns.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Tick at least one printer to add.', 'Nothing selected', 'OK', 'Information') | Out-Null
        return
    }

    $def = ''
    if ($cliDefault.SelectedIndex -gt 0) { $def = "$($cliDefault.SelectedItem)" }

    $opts = @{
        CompatDrivers      = $optCompat.CheckBox.Checked
        LockDefault        = $optLockDefault.CheckBox.Checked
        Watchdog           = $optCliWatch.CheckBox.Checked
        DefaultPrinter     = $def
        CredentialUser     = $(if ($optCred.CheckBox.Checked) { $cliUser.Text } else { '' })
        CredentialPassword = $(if ($optCred.CheckBox.Checked) { $cliPass.Text } else { '' })
    }

    $work = {
        $done = Invoke-PSSClientSetup -ServerName $srv -Connections $conns -Options $opts
        if ($done -and $done.Count -gt 0) {
            $resultLabel.Text    = 'Connected printers:'
            $resultBox.Text      = ($done -join "`r`n")
            $resultBox.Visible   = $true
            $resultLabel.Visible = $true
            $btnCopy.Visible     = $true
        }
    }.GetNewClosure()

    Start-PSSRun -Title 'Connecting to the shared printers' -Work $work
})

# ==========================================================================
# MAINTENANCE panel
# ==========================================================================
$pnlMaint = New-PSSPanel 'Maint'

$mH = New-PSSLabel 'Check, repair or undo' $FontH2
$mH.Location = New-Object System.Drawing.Point(0, 0)
$pnlMaint.Controls.Add($mH)

function New-PSSActionRow {
    param([string]$Title, [string]$Body, [string]$ButtonText, [int]$Y, [scriptblock]$OnClick, [switch]$Danger)
    $card = New-Object System.Windows.Forms.Panel
    $card.Location    = New-Object System.Drawing.Point(0, $Y)
    $card.Size        = New-Object System.Drawing.Size(870, 74)
    $card.Anchor      = 'Top,Left,Right'
    $card.BackColor   = $Theme.Card
    $card.BorderStyle = 'FixedSingle'

    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title; $t.Font = $FontBold; $t.ForeColor = $Theme.Text
    $t.AutoSize = $true; $t.Location = New-Object System.Drawing.Point(18, 14)
    $card.Controls.Add($t)

    $b = New-Object System.Windows.Forms.Label
    $b.Text = $Body; $b.Font = $FontSmall; $b.ForeColor = $Theme.Muted
    $b.AutoSize = $false; $b.Size = New-Object System.Drawing.Size(620, 32)
    $b.Location = New-Object System.Drawing.Point(19, 36)
    $card.Controls.Add($b)

    $btn = New-PSSButton $ButtonText 160 32 -Danger:$Danger
    $btn.Location = New-Object System.Drawing.Point(680, 20)
    $btn.Anchor   = 'Top,Right'
    $btn.Add_Click($OnClick)
    $card.Controls.Add($btn)

    return $card
}

$pnlMaint.Controls.Add((New-PSSActionRow 'Health check' `
    'Reports the spooler, network profile, shared printers, sleep settings and stuck jobs. Changes nothing.' `
    'Run check' 36 { Start-PSSRun 'Health check' { Invoke-PSSHealthCheck | Out-Null } }))

$pnlMaint.Controls.Add((New-PSSActionRow 'Clear a jammed print queue' `
    'Cancels every queued job and empties the spool folder. The usual fix when nothing prints any more.' `
    'Clear queue' 122 {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'This cancels every job waiting to print on this PC. Continue?', 'Clear queue', 'YesNo', 'Warning')
        if ($r -eq 'Yes') {
            Start-PSSRun 'Clearing the print queue' { Clear-PSSStuckJobs -PurgeSpoolFolder | Out-Null }
        }
    }))

$pnlMaint.Controls.Add((New-PSSActionRow 'Keep-alive helper' `
    'The background check that restarts the spooler, re-shares printers and reconnects clients.' `
    'Remove helper' 208 {
        Start-PSSRun 'Removing the keep-alive helper' { Uninstall-PSSWatchdog | Out-Null }
    } -Danger))

$pnlMaint.Controls.Add((New-PSSActionRow 'Undo the last run' `
    'Puts back every registry value, service setting and printer share this tool changed most recently.' `
    'Undo last run' 294 {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'This reverses the most recent set of changes made by this tool. Continue?', 'Undo', 'YesNo', 'Warning')
        if ($r -eq 'Yes') {
            Start-PSSRun 'Undoing the last run' { Invoke-PSSUndo | Out-Null }
        }
    } -Danger))

$pnlMaint.Controls.Add((New-PSSActionRow 'Log files' `
    'Every action this tool has taken, plus the keep-alive helper log.' `
    'Open log folder' 380 {
        $d = Join-Path (Get-PSSRoot) 'logs'
        if (Test-Path -LiteralPath $d) { Start-Process explorer.exe $d }
    }))

$btnMaintBack = New-PSSButton 'Back' 110 38
$btnMaintBack.Location = New-Object System.Drawing.Point(0, 470)
$btnMaintBack.Add_Click({ Show-PSSPanel 'Home' })
$pnlMaint.Controls.Add($btnMaintBack)

# ==========================================================================
Show-PSSPanel 'Home'
Write-PSSLog "Printer Share Setup started on $env:COMPUTERNAME" 'INFO'
[void]$form.ShowDialog()
