# run_with_log_cfb.ps1
# -----------------------------------------------------------------------------
# Wrapper for all CFB pipeline scheduled tasks.
# Runs Rscript and appends stdout + stderr to a date-stamped log file.
# Called by each Windows Scheduled Task instead of Rscript directly.
#
# Parameters:
#   -TaskName  : Unique name used in log filename (e.g. "CFB_Pipeline_Sat")
#   -TaskType  : "pipeline"    → runs run_daily_football.R
#                "line_logger" → runs scripts/LINE_MOVEMENT_LOGGER_CFB.R
#
# Usage (from Task Scheduler action):
#   Program  : powershell.exe
#   Arguments: -NonInteractive -NoProfile -File "...\run_with_log_cfb.ps1"
#              -TaskName "CFB_Pipeline_Sat" -TaskType "pipeline"
#
# Log location: G:\My Drive\Scripting Projects\cfb_project\log\
# Log filename: {TaskName}_{yyyy-MM-dd}.log  (appended if task runs twice)
# Retention   : 30 days
# -----------------------------------------------------------------------------

param(
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$TaskType
)

# -- Paths --------------------------------------------------------------------

$ProjectDir = "G:\My Drive\Scripting Projects\cfb_project"
$LogDir     = Join-Path $ProjectDir "log"
$LogFile    = Join-Path $LogDir "${TaskName}_$(Get-Date -Format 'yyyy-MM-dd').log"

# -- Locate Rscript.exe (self-healing) ----------------------------------------

$Rscript = "C:\Program Files\R\R-4.6.0\bin\Rscript.exe"

if (-not (Test-Path $Rscript)) {
    $Reg = "HKLM:\SOFTWARE\R-core\R"
    if (Test-Path $Reg) {
        $Rscript = Join-Path (Get-ItemProperty $Reg).InstallPath "bin\Rscript.exe"
    }
}
if (-not (Test-Path $Rscript)) {
    $Cmd = Get-Command Rscript -ErrorAction SilentlyContinue
    if ($Cmd) { $Rscript = $Cmd.Source }
}
if (-not $Rscript -or -not (Test-Path $Rscript)) {
    Add-Content -Path $LogFile -Value "[ERROR] Could not locate Rscript.exe" -Encoding UTF8
    exit 1
}

# -- Choose script to run -----------------------------------------------------

$Script = switch ($TaskType) {
    "pipeline"    { Join-Path $ProjectDir "run_daily_football.R" }
    "line_logger" { Join-Path $ProjectDir "scripts\LINE_MOVEMENT_LOGGER_CFB.R" }
    default {
        Add-Content -Path $LogFile -Value "[ERROR] Unknown TaskType: $TaskType" -Encoding UTF8
        exit 1
    }
}

# -- Ensure log directory exists ----------------------------------------------

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}

# -- Header -------------------------------------------------------------------

$Sep = "=" * 60
@"
$Sep
  $TaskName  |  $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Script: $Script
$Sep

"@ | Add-Content -Path $LogFile -Encoding UTF8

# -- Run ----------------------------------------------------------------------

& $Rscript --vanilla $Script *>> $LogFile

$ExitCode = $LASTEXITCODE

# -- Footer -------------------------------------------------------------------

@"

[done] $TaskName — $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")  exit=$ExitCode
"@ | Add-Content -Path $LogFile -Encoding UTF8

# -- Prune logs older than 30 days --------------------------------------------

Get-ChildItem -Path $LogDir -Filter "${TaskName}_*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force

exit $ExitCode
