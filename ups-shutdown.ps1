<#
=====================================================================
 ups-shutdown.ps1  -  Shut down the PC after N minutes on UPS battery
=====================================================================

WHAT IT DOES
  When the PC switches from wall power to a UPS battery, a small
  countdown window appears (bottom-right of the screen). When the
  countdown reaches 0:00 the PC shuts down. The window has:
    - "+ 1 minute"      adds time (press as often as you like)
    - "Cancel shutdown" cancels the shutdown for this outage
    - The X button only MINIMIZES it (so it can't cancel by accident)
  If wall power returns, the window closes by itself.
  A Windows scheduled task starts this script automatically whenever
  Windows logs an AC/battery change (Kernel-Power event 105).

SETUP ON A NEW WINDOWS INSTALL OR ANOTHER COMPUTER
  1. Connect the UPS to the PC with its USB cable, and plug the PC
     into the UPS's battery-backed outlets. Windows must see the UPS
     as a battery: check with this PowerShell command, which should
     list your UPS (and note its Name, e.g. "LX1500GU"):
         Get-CimInstance Win32_Battery
     (If nothing is listed, the USB cable isn't connected or the UPS
     doesn't report to Windows, and this script can't work.)
  2. Copy this file to C:\bin\ups-shutdown.ps1 (any folder works, but
     don't move it after step 4 or re-run step 4 from the new place).
  3. Edit the CONFIG section below if needed. The main one is
     $ShutdownDelaySeconds. On a LAPTOP, which has its own internal
     battery, set $BatteryNameFilter to the UPS name from step 1 so
     the laptop's own battery doesn't trigger it.
  4. Register the scheduled task (no admin rights needed). Open
     PowerShell and run:
         powershell -ExecutionPolicy Bypass -File C:\bin\ups-shutdown.ps1 -Install
  5. Test the window without waiting for an outage (never shuts down
     in this mode):
         powershell -ExecutionPolicy Bypass -File C:\bin\ups-shutdown.ps1 -Test
     Real test: unplug the UPS from the wall and wait the full delay.

NOTES / LIMITS
  - The task runs as the logged-in user, so it only works while you
    are signed in (the countdown window needs your desktop).
  - If the PC boots while already on battery, nothing fires until the
    next AC/battery change.
  - To abort a shutdown that has already started (30 sec warning):
         shutdown /a
  - To remove everything:
         powershell -ExecutionPolicy Bypass -File C:\bin\ups-shutdown.ps1 -Uninstall

SWITCHES
  -Install    register the scheduled task, pointing at this file
  -Uninstall  delete the scheduled task
  -Test       show the window even on wall power; never shuts down
#>

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test
)

# =====================================================================
#  CONFIG - change these to adapt to other hardware or preferences
# =====================================================================

# How long to wait on battery before shutting down (seconds). 300 = 5 min.
$ShutdownDelaySeconds = 300

# How much the "+ 1 minute" button adds (seconds).
$ExtendSeconds = 60

# Warning Windows shows once the countdown ends, before powering off
# (seconds). Abort during this time with:  shutdown /a
$ShutdownGraceSeconds = 30

# Which battery counts as the UPS. Wildcard match on the battery Name
# from "Get-CimInstance Win32_Battery". '*' = any battery (fine for a
# desktop). On a laptop use the UPS name, e.g. 'LX1500GU'.
$BatteryNameFilter = '*'

# How often (seconds) to re-check whether wall power has returned.
$PowerCheckIntervalSeconds = 5

# Shutdown message shown by Windows.
$ShutdownMessage = 'On UPS battery - shutting down.'

# Countdown window: size, and gap from the bottom-right screen corner.
$WindowWidth  = 320
$WindowHeight = 190
$WindowMargin = 20

# Name of the Windows scheduled task created by -Install.
$TaskName = 'UPS Battery Shutdown'

# =====================================================================
#  END OF CONFIG
# =====================================================================

# Fixed Windows facts - the same on every PC, not meant to be changed:
#  - Event 105 from Kernel-Power is "Power source change" (AC <-> battery).
#  - Win32_Battery BatteryStatus 1 means "discharging" (running on battery).
$TriggerProvider      = 'Microsoft-Windows-Kernel-Power'
$TriggerEventId       = 105
$OnBatteryStatusValue = 1

# ---------------------------------------------------------------------
#  -Install / -Uninstall : manage the scheduled task
# ---------------------------------------------------------------------
if ($Uninstall) {
    schtasks /Delete /TN $TaskName /F
    exit $LASTEXITCODE
}

if ($Install) {
    $scriptPath = $PSCommandPath
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='$TriggerProvider'] and EventID=$TriggerEventId]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <StartWhenAvailable>false</StartWhenAvailable>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$scriptPath"</Arguments></Exec>
  </Actions>
</Task>
"@
    $tmp = Join-Path $env:TEMP 'ups-shutdown-task.xml'
    $xml | Out-File $tmp -Encoding Unicode
    schtasks /Create /TN $TaskName /XML $tmp /F
    $rc = $LASTEXITCODE
    Remove-Item $tmp -ErrorAction SilentlyContinue
    exit $rc
}

# ---------------------------------------------------------------------
#  Normal run (started by the scheduled task)
# ---------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function OnBattery {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like $BatteryNameFilter }
    if (-not $b) { return $false }
    return (@($b | Where-Object { $_.BatteryStatus -eq $OnBatteryStatusValue }).Count -gt 0)
}

# Nothing to do if we're on wall power (the task fires on both directions).
if (-not $Test -and -not (OnBattery)) { exit 0 }

[System.Windows.Forms.Application]::EnableVisualStyles()
$script:deadline    = (Get-Date).AddSeconds($ShutdownDelaySeconds)
$script:lastCheck   = Get-Date
$script:shutdownNow = $false
$script:allowClose  = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'UPS - Running on battery'
$form.Size = New-Object System.Drawing.Size($WindowWidth, $WindowHeight)
$form.StartPosition = 'Manual'
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(
    ($wa.Right  - $WindowWidth  - $WindowMargin),
    ($wa.Bottom - $WindowHeight - $WindowMargin))
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ShowInTaskbar = $true
$form.TopMost = $false

$msg = New-Object System.Windows.Forms.Label
$msg.Text = 'Power is out. This PC will shut down in:'
$msg.AutoSize = $true
$msg.Location = New-Object System.Drawing.Point(15, 15)
$form.Controls.Add($msg)

$time = New-Object System.Windows.Forms.Label
$time.Font = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
$time.Text = ''
$time.AutoSize = $false
$time.TextAlign = 'MiddleCenter'
$time.Size = New-Object System.Drawing.Size(280, 55)
$time.Location = New-Object System.Drawing.Point(15, 40)
$form.Controls.Add($time)

$plus = New-Object System.Windows.Forms.Button
$plus.Text = '+ {0} minute' -f [math]::Round($ExtendSeconds / 60, 1)
$plus.Size = New-Object System.Drawing.Size(130, 32)
$plus.Location = New-Object System.Drawing.Point(15, 105)
$plus.Add_Click({ $script:deadline = $script:deadline.AddSeconds($ExtendSeconds) })
$form.Controls.Add($plus)

$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel shutdown'
$cancel.Size = New-Object System.Drawing.Size(130, 32)
$cancel.Location = New-Object System.Drawing.Point(165, 105)
$cancel.Add_Click({ $script:allowClose = $true; $form.Close() })
$form.Controls.Add($cancel)

# The X button minimizes instead of closing, so it can't cancel by accident.
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:allowClose -and $e.CloseReason -ne 'WindowsShutDown') {
        $e.Cancel = $true
        $form.WindowState = 'Minimized'
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $left = [int][math]::Ceiling(($script:deadline - (Get-Date)).TotalSeconds)
    if ($left -lt 0) { $left = 0 }
    $time.Text = '{0}:{1:00}' -f [math]::Floor($left / 60), ($left % 60)
    $form.Text = "UPS - shutdown in $($time.Text)"
    if ($left -le 0) {
        $timer.Stop()
        $script:shutdownNow = $true
        $script:allowClose  = $true
        $form.Close()
        return
    }
    # Periodically close if wall power has returned.
    if (((Get-Date) - $script:lastCheck).TotalSeconds -ge $PowerCheckIntervalSeconds) {
        $script:lastCheck = Get-Date
        if (-not $Test -and -not (OnBattery)) { $script:allowClose = $true; $form.Close() }
    }
})
$timer.Start()
[void][System.Windows.Forms.Application]::Run($form)
$timer.Dispose()

if ($script:shutdownNow -and -not $Test) {
    shutdown.exe /s /t $ShutdownGraceSeconds /c $ShutdownMessage
}
