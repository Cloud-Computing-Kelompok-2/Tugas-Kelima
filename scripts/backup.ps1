# ==============================================================================
# Script Otomatisasi Backup Database MySQL - CBT Portal (Windows PowerShell)
# Pertemuan 4: Disaster Recovery Execution & Testing (Kelompok 2)
# ==============================================================================
# Skrip ini melakukan backup logis (mysqldump) dari container MySQL ke folder backups/ di host.
# Dapat dijalankan secara manual atau dijadwalkan via Windows Task Scheduler.
# ==============================================================================

[CmdletBinding()]
param(
    [int]$KeepDays = 7,
    [string]$OutputDir = ""
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "..")

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $ProjectRoot "backups"
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupFile = Join-Path $OutputDir "cbt_portal_$Timestamp.sql"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  CBT Portal - Database Automated Backup (PowerShell)    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "[1/3] Menjalankan mysqldump dari container mysql..." -ForegroundColor Yellow

# Eksekusi mysqldump langsung dari dalam container mysql
Push-Location $ProjectRoot
try {
    # Ambil kredensial dari environment container mysql tanpa hardcode password
    $dumpCommand = 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --routines --triggers --no-tablespaces "$MYSQL_DATABASE"'
    & docker compose exec -T mysql sh -c $dumpCommand | Out-File -FilePath $BackupFile -Encoding utf8
    
    if ($LASTEXITCODE -ne 0) {
        throw "mysqldump gagal dieksekusi di dalam container mysql (Exit code: $LASTEXITCODE)."
    }
}
finally {
    Pop-Location
}

Write-Host "[2/3] Memvalidasi integritas file backup..." -ForegroundColor Yellow
if (-not (Test-Path $BackupFile)) {
    throw "File backup tidak ditemukan: $BackupFile"
}

$fileSize = (Get-Item $BackupFile).Length
if ($fileSize -lt 1024) {
    Remove-Item $BackupFile -Force -ErrorAction SilentlyContinue
    throw "File backup berukuran terlalu kecil ($fileSize bytes). Backup dicurigai gagal atau korup."
}

# Verifikasi footer dump completed
$tailLines = Get-Content -Path $BackupFile -Tail 10
$isComplete = $tailLines | Where-Object { $_ -match "Dump completed" }
if (-not $isComplete) {
    Remove-Item $BackupFile -Force -ErrorAction SilentlyContinue
    throw "Header/footer mysqldump tidak lengkap ('Dump completed' tidak ditemukan). File dibatalkan."
}

Write-Host "      Integritas backup TERVERIFIKASI: Terdapat penanda 'Dump completed'." -ForegroundColor Green

Write-Host "[3/3] Membersihkan backup lama (> $KeepDays hari)..." -ForegroundColor Yellow
$cutoffDate = (Get-Date).AddDays(-$KeepDays)
$oldFiles = Get-ChildItem -Path $OutputDir -Filter "cbt_portal_*.sql*" | Where-Object { $_.LastWriteTime -lt $cutoffDate }
foreach ($old in $oldFiles) {
    Remove-Item $old.FullName -Force
    Write-Host "      Menghapus backup usang: $($old.Name)" -ForegroundColor DarkGray
}

$finalSizeKb = [math]::Round($fileSize / 1KB, 2)
Write-Host ""
Write-Host "SUCCESS: Backup berhasil dibuat!" -ForegroundColor Green
Write-Host "  File   : $BackupFile" -ForegroundColor Cyan
Write-Host "  Ukuran : $finalSizeKb KB" -ForegroundColor Cyan
Write-Host "  Waktu  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

