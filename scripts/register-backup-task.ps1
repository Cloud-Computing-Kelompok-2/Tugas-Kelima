# ==============================================================================
# Script Pendaftaran Scheduled Task Backup Otomatis (Windows Task Scheduler)
# Pertemuan 4: Otomatisasi Backup Berkala (Setiap 15 Menit)
# ==============================================================================

[CmdletBinding()]
param(
    [string]$TaskName = "CBT_Portal_MySQL_Backup",
    [int]$IntervalMinutes = 15
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupScript = Join-Path $ScriptDir "backup.ps1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Pendaftaran Windows Scheduled Task Backup Berkala      " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Task Name : $TaskName" -ForegroundColor Yellow
Write-Host "Interval  : Setiap $IntervalMinutes Menit" -ForegroundColor Yellow
Write-Host "Script    : $BackupScript" -ForegroundColor Yellow

# Buat Action
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BackupScript`""

# Buat Trigger (Mulai sekarang, berulang setiap 15 menit tanpa henti)
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)

# Setting
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

# Register Task
try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Description "Otomatisasi backup berkala database MySQL CBT Portal setiap $IntervalMinutes menit (Pertemuan 4 Cloud Computing)" -Force | Out-Null
    Write-Host ""
    Write-Host "SUCCESS: Scheduled Task '$TaskName' berhasil didaftarkan!" -ForegroundColor Green
    Write-Host "Database akan di-backup otomatis setiap $IntervalMinutes menit ke folder cbt-portal/backups/." -ForegroundColor Green
} catch {
    Write-Warning "Pendaftaran task memerlukan hak administrator. Jika gagal, jalankan PowerShell as Administrator atau gunakan skrip bash/container cron."
    Write-Error $_
}

