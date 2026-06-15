# schedule_tasks_cfb.ps1
# -----------------------------------------------------------------------------
# Registers Windows Scheduled Tasks for the mcFootball CFB pipeline.
# Run once as Administrator:
#   Right-click PowerShell -> "Run as Administrator"
#   cd "G:\My Drive\Scripting Projects\cfb_project"
#   .\schedule_tasks_cfb.ps1
#
# Tasks registered:
#   CFB_Pipeline_Thu  — Thursday  6:00 PM  — full pipeline run (early lines)
#   CFB_Pipeline_Fri  — Friday   12:00 PM  — updated odds + injury check
#   CFB_Pipeline_Sat  — Saturday  8:00 AM  — final run before kickoffs
#   CFB_LineLogger_Hourly — Thu-Sat hourly (CREATED DISABLED — enable in Aug)
#
# To enable the hourly line logger for the live season:
#   Enable-ScheduledTask -TaskName "CFB_LineLogger_Hourly"
# -----------------------------------------------------------------------------

# -- Locate Rscript.exe -------------------------------------------------------

$RscriptCmd = Get-Command Rscript -ErrorAction SilentlyContinue
if ($RscriptCmd) {
    $Rscript = $RscriptCmd.Source
} else {
    $RegPath = "HKLM:\SOFTWARE\R-core\R"
    if (Test-Path $RegPath) {
        $RHome   = (Get-ItemProperty $RegPath).InstallPath
        $Rscript = Join-Path $RHome "bin\Rscript.exe"
    }
}

if (-not $Rscript -or -not (Test-Path $Rscript)) {
    Write-Error "Could not locate Rscript.exe. Install R or add it to PATH and retry."
    exit 1
}

Write-Host "Using Rscript: $Rscript" -ForegroundColor Cyan

# -- Project paths ------------------------------------------------------------

$ProjectDir     = "G:\My Drive\Scripting Projects\cfb_project"
$WrapperScript  = Join-Path $ProjectDir "run_with_log_cfb.ps1"

if (-not (Test-Path $ProjectDir)) {
    Write-Error "Project directory not found: $ProjectDir"
    exit 1
}

# -- Pipeline task definitions (Thu / Fri / Sat) ------------------------------

$PipelineTasks = @(
    @{
        Name      = "CFB_Pipeline_Thu"
        Day       = "Thursday"
        Time      = "18:00"
        Desc      = "mcFootball CFB pipeline — Thursday early line capture"
        TimeLimit = 60
    },
    @{
        Name      = "CFB_Pipeline_Fri"
        Day       = "Friday"
        Time      = "12:00"
        Desc      = "mcFootball CFB pipeline — Friday updated odds + injury check"
        TimeLimit = 60
    },
    @{
        Name      = "CFB_Pipeline_Sat"
        Day       = "Saturday"
        Time      = "08:00"
        Desc      = "mcFootball CFB pipeline — Saturday final run before kickoffs"
        TimeLimit = 60
    }
)

$Created = 0
$Updated = 0
$Failed  = 0

foreach ($t in $PipelineTasks) {
    $Arguments = "-NonInteractive -NoProfile -File `"$WrapperScript`" -TaskName `"$($t.Name)`" -TaskType `"pipeline`""

    $Action = New-ScheduledTaskAction `
        -Execute          "powershell.exe" `
        -Argument         $Arguments `
        -WorkingDirectory $ProjectDir

    $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $t.Day -At $t.Time

    $Settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $t.TimeLimit) `
        -MultipleInstances  IgnoreNew `
        -StartWhenAvailable

    $Params = @{
        TaskName    = $t.Name
        Action      = $Action
        Trigger     = $Trigger
        Settings    = $Settings
        Description = $t.Desc
        RunLevel    = "Highest"
    }

    try {
        $existing = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false | Out-Null
            $Updated++
        } else {
            $Created++
        }
        Register-ScheduledTask @Params | Out-Null
        $status = if ($existing) { "[UPDATED]" } else { "[CREATED]" }
        $color  = if ($existing) { "Yellow"   } else { "Green"    }
        Write-Host "  $status $($t.Name)  $($t.Day) @ $($t.Time)" -ForegroundColor $color
    } catch {
        Write-Host "  [FAILED]  $($t.Name): $_" -ForegroundColor Red
        $Failed++
    }
}

# -- Hourly line logger (Thu-Sat, CREATED DISABLED) ---------------------------
#
# Created in disabled state to preserve quota during the off-season.
# Enable manually in late August before Week 1:
#   Enable-ScheduledTask -TaskName "CFB_LineLogger_Hourly"
#
# Runs every hour 9 AM – 8 PM on Thu/Fri/Sat only.
# R-side: LINE_MOVEMENT_LOGGER_CFB.R handles its own log-retention (21 days).

$HourlyName = "CFB_LineLogger_Hourly"
$HourlyArg  = "-NonInteractive -NoProfile -File `"$WrapperScript`" -TaskName `"$HourlyName`" -TaskType `"line_logger`""

$HourlyXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>mcFootball CFB line logger — hourly Thu-Sat 9AM-8PM; DISABLED off-season; enable late August</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <Duration>PT11H</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2026-08-27T09:00:00</StartBoundary>
      <Enabled>false</Enabled>
      <ScheduleByWeek>
        <DaysOfWeek>
          <Thursday />
          <Friday />
          <Saturday />
        </DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT20M</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>false</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$HourlyArg</Arguments>
      <WorkingDirectory>$ProjectDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

try {
    $existingH = Get-ScheduledTask -TaskName $HourlyName -ErrorAction SilentlyContinue
    if ($existingH) {
        Unregister-ScheduledTask -TaskName $HourlyName -Confirm:$false | Out-Null
        $Updated++
    } else {
        $Created++
    }
    Register-ScheduledTask -TaskName $HourlyName -Xml $HourlyXml -Force | Out-Null
    $hstatus = if ($existingH) { "[UPDATED]" } else { "[CREATED]" }
    $hcolor  = if ($existingH) { "Yellow"   } else { "Green"    }
    Write-Host "  $hstatus $HourlyName  Thu-Sat @ hourly 09:00-20:00  [DISABLED — enable late August]" -ForegroundColor $hcolor
} catch {
    Write-Host "  [FAILED]  ${HourlyName}: $_" -ForegroundColor Red
    $Failed++
}

# -- Summary ------------------------------------------------------------------

Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Created : $Created" -ForegroundColor Green
Write-Host "  Updated : $Updated" -ForegroundColor Yellow
Write-Host "  Failed  : $Failed"  -ForegroundColor $(if ($Failed -gt 0) { "Red" } else { "DarkGray" })
Write-Host ""
Write-Host "To enable the hourly line logger for live season:" -ForegroundColor Cyan
Write-Host "  Enable-ScheduledTask -TaskName `"CFB_LineLogger_Hourly`"" -ForegroundColor Cyan
Write-Host ""

# -- Verification -------------------------------------------------------------

Get-ScheduledTask | Where-Object { $_.TaskName -like 'CFB_*' } | ForEach-Object {
    $Name = $_.TaskName
    $State = $_.State
    $Info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        TaskName = $Name
        State    = $State
        NextRun  = $Info.NextRunTime
    }
} | Sort-Object NextRun | Format-Table -AutoSize
