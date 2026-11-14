# ==============================================================================
# Script Pemulihan Database (Restore) - CBT Portal (Windows PowerShell)
# Pertemuan 4: Disaster Recovery Execution & Testing (Kelompok 2)
# ==============================================================================
# Skrip ini memulihkan database MySQL dari file backup (.sql).
# PERINGATAN: Seluruh isi database saat ini akan ditimpa oleh file backup!
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$BackupFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "..")
$BackupsDir = Join-Path $ProjectRoot "backups"

# Jika tidak menyertakan file, ambil file backup terbaru dari folder backups/
if ([string]::IsNullOrWhiteSpace($BackupFile)) {
    $latest = Get-ChildItem -Path $BackupsDir -Filter "cbt_portal_*.sql*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        throw "Tidak ditemukan file backup di $BackupsDir. Harap tentukan parameter -BackupFile <path>."
    }
    $BackupFile = $latest.FullName
    Write-Host "[INFO] Menggunakan file backup terbaru secara otomatis: $($latest.Name)" -ForegroundColor Cyan
}

if (-not (Test-Path $BackupFile)) {
    throw "File backup tidak ditemukan: $BackupFile"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  CBT Portal - Database Restore & Recovery (PowerShell)  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Target file: $BackupFile" -ForegroundColor Yellow

# [1] Validasi Integritas Backup SEBELUM Eksekusi Destruktif
Write-Host "[1/4] Memvalidasi integritas file backup sebelum restore..." -ForegroundColor Yellow
$tailLines = Get-Content -Path $BackupFile -Tail 15
$isComplete = $tailLines | Where-Object { $_ -match "Dump completed" }
if (-not $isComplete) {
    throw "VALIDASI GAGAL: Penanda 'Dump completed' tidak ditemukan pada footer file. Operasi dibatalkan demi keamanan data!"
}
Write-Host "      Integritas valid: Header/Footer dump lengkap dan siap dipulihkan." -ForegroundColor Green

# [2] Konfirmasi Keamanan
if (-not $Force) {
    Write-Host ""
    Write-Host "PERINGATAN: Database aktif akan di-DROP dan ditimpa dari file backup!" -ForegroundColor Red
    $confirm = Read-Host "Apakah Anda yakin ingin melanjutkan? (Ketik 'ya' untuk lanjut)"
    if ($confirm -ne 'ya') {
        Write-Host "Operasi pemulihan dibatalkan oleh pengguna." -ForegroundColor Yellow
        exit 0
    }
}

Push-Location $ProjectRoot
try {
    # [3] Drop dan Recreate Database
    Write-Host "[2/4] Resetting database aktif di container mysql..." -ForegroundColor Yellow
    "DROP DATABASE IF EXISTS cbt_portal; CREATE DATABASE cbt_portal CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | & docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
    if ($LASTEXITCODE -ne 0) {
        throw "Gagal melakukan DROP/CREATE database di container mysql."
    }

    # [4] Injeksi Data Backup ke MySQL
    Write-Host "[3/4] Mengimpor data dari file backup ke MySQL..." -ForegroundColor Yellow
    Get-Content -Path $BackupFile -Raw | & docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot cbt_portal'
    if ($LASTEXITCODE -ne 0) {
        throw "Gagal memulihkan data ke database."
    }

    # [5] Restart Backend Services
    Write-Host "[4/4] Me-restart backend microservices agar koneksi terhubung ulang..." -ForegroundColor Yellow
    & docker compose restart auth-service exam-service session-service
    if ($LASTEXITCODE -ne 0) {
        throw "Gagal melakukan restart backend microservices."
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "SUCCESS: Pemulihan database berhasil 100%!" -ForegroundColor Green
Write-Host "  Database telah kembali ke state backup: $BackupFile" -ForegroundColor Cyan
Write-Host "  Microservices (auth, exam, session) telah direstart dan siap melayani." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

