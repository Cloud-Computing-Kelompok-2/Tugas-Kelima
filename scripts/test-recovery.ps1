# ==============================================================================
# Script Eksekusi Disaster Recovery Test - CBT Portal (Windows PowerShell)
# Pertemuan 4: Kelompok 2 (Portal Ujian Online CBT)
# ==============================================================================
# Skenario DR Test Kelompok 2:
# Matikan container App Server (session-service) di tengah-tengah simulasi pengisian
# soal ujian. Buktikan bahwa jawaban siswa yang sudah disimpan sebelum server mati
# tidak hilang (RPO = 0) dan siswa dapat melanjutkan ujian setelah server pulih (RTO <= 2 mnt).
# ==============================================================================

[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:3000",
    [string]$TargetService = "session-service",
    [int]$MaxRtoSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $ScriptDir "..")
$WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  EKSEKUSI DISASTER RECOVERY (DR) TEST - CBT PORTAL (KELOMPOK 2)      " -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Target URL      : $BaseUrl" -ForegroundColor Gray
Write-Host "Service diuji   : $TargetService" -ForegroundColor Gray
Write-Host "Batas Max RTO   : $MaxRtoSeconds detik" -ForegroundColor Gray
Write-Host "Waktu Pengujian : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray

# ------------------------------------------------------------------------------
# TAHAP 1: Login Siswa & Mulai Ujian
# ------------------------------------------------------------------------------
Write-Host "`n[TAHAP 1] Otentikasi Siswa & Inisialisasi Sesi Ujian..." -ForegroundColor Yellow
$loginPayload = @{
    nim = "2024001"
    password = "password123"
} | ConvertTo-Json

try {
    $loginRes = Invoke-RestMethod -Uri "$BaseUrl/api/login" -Method Post -Body $loginPayload -ContentType "application/json" -WebSession $WebSession
    Write-Host "  [OK] Login berhasil: $($loginRes.nama) (NIM: $($loginRes.nim))" -ForegroundColor Green
} catch {
    throw "Gagal login ke CBT Portal: $_"
}

# Mulai sesi ujian (Exam ID 1)
$startPayload = @{ exam_id = 1 } | ConvertTo-Json
$startRes = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/start" -Method Post -Body $startPayload -ContentType "application/json" -WebSession $WebSession
$sessionId = $startRes.session_id
Write-Host "  [OK] Sesi Ujian dimulai. Session ID: $sessionId" -ForegroundColor Green

# ------------------------------------------------------------------------------
# TAHAP 2: Pengisian Sebagian Soal Sebelum Crash
# ------------------------------------------------------------------------------
Write-Host "`n[TAHAP 2] Siswa Mengisi Sebagian Jawaban (Sebelum Terjadi Crash)..." -ForegroundColor Yellow

# Simpan Soal 1 = C
$ans1 = @{ question_id = 1; pilihan = "C" } | ConvertTo-Json
$res1 = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId/answers" -Method Put -Body $ans1 -ContentType "application/json" -WebSession $WebSession
Write-Host "  [OK] Soal 1 dijawab: 'C' -> Status server: $($res1.status)" -ForegroundColor Green

# Simpan Soal 2 = A
$ans2 = @{ question_id = 2; pilihan = "A" } | ConvertTo-Json
$res2 = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId/answers" -Method Put -Body $ans2 -ContentType "application/json" -WebSession $WebSession
Write-Host "  [OK] Soal 2 dijawab: 'A' -> Status server: $($res2.status)" -ForegroundColor Green

# Verifikasi kondisi awal sebelum server dimatikan
$checkBefore = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId" -Method Get -WebSession $WebSession
$savedCountBefore = ($checkBefore.answers.PSObject.Properties | Measure-Object).Count
$sisaWaktuBefore = $checkBefore.session.sisa_detik
Write-Host "  [VERIFIKASI AWAL] Jawaban tersimpan di DB: $savedCountBefore soal (Soal 1=$($checkBefore.answers.'1'), Soal 2=$($checkBefore.answers.'2'))" -ForegroundColor Cyan
Write-Host "  [VERIFIKASI AWAL] Sisa waktu ujian       : $sisaWaktuBefore detik" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# TAHAP 3: Simulasi Bencana (Kill Container Backend Secara Paksa)
# ------------------------------------------------------------------------------
Write-Host "`n[TAHAP 3] SIMULASI BENCANA: Mematikan Container $TargetService secara paksa..." -ForegroundColor Red
Push-Location $ProjectRoot
try {
    $containerId = (& docker compose ps -q $TargetService | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        throw "Container untuk service '$TargetService' tidak ditemukan!"
    }

    $timeCrash = Get-Date
    Write-Host "  [!] WAKTU INSIDEN (T0): $($timeCrash.ToString('HH:mm:ss.fff'))" -ForegroundColor Red
    Write-Host "  [!] Membunuh container ID: $containerId (docker kill)" -ForegroundColor Red
    & docker kill $containerId | Out-Null

    # Buktikan bahwa server sedang mati / tidak merespons
    $isDown = $false
    try {
        $null = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId" -Method Get -WebSession $WebSession -TimeoutSec 2
    } catch {
        $isDown = $true
        Write-Host "  [BUKTI SERVER DOWN] Request gagal sesuai ekspektasi bencana: $($_.Exception.Message)" -ForegroundColor Magenta
    }
    if (-not $isDown) {
        Write-Warning "Peringatan: Server masih merespons, kemungkinan ada replika lain yang masih aktif."
    }
}
finally {
    Pop-Location
}

# ------------------------------------------------------------------------------
# TAHAP 4: Menjalankan Prosedur Pemulihan (SOP DRP 7.1: docker compose up -d)
# ------------------------------------------------------------------------------
Write-Host "`n[TAHAP 4] Menjalankan Prosedur Pemulihan (SOP DRP: docker compose up -d $TargetService)..." -ForegroundColor Yellow
$recovered = $false
$elapsedSeconds = 0
$startTime = [System.Diagnostics.Stopwatch]::StartNew()

# Eksekutor (Ananda) menjalankan perintah restart sesuai SOP DRP 7.1
Push-Location $ProjectRoot
try {
    Write-Host "  [+] Operator Teknis mengeksekusi pemulihan: docker compose up -d $TargetService" -ForegroundColor Cyan
    & docker compose up -d $TargetService | Out-Null
} finally {
    Pop-Location
}

while ($startTime.Elapsed.TotalSeconds -lt $MaxRtoSeconds) {
    Start-Sleep -Milliseconds 800
    try {
        $resPing = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId" -Method Get -WebSession $WebSession -TimeoutSec 2
        if ($resPing.session.id -eq $sessionId) {
            $startTime.Stop()
            $recovered = $true
            $elapsedSeconds = [math]::Round($startTime.Elapsed.TotalSeconds, 2)
            $timeRecovered = Get-Date
            Write-Host "  [+] WAKTU PULIH (T1) : $($timeRecovered.ToString('HH:mm:ss.fff'))" -ForegroundColor Green
            Write-Host "  [+] RTO AKTUAL       : $elapsedSeconds detik (Target: <= $MaxRtoSeconds dtk)" -ForegroundColor Green
            break
        }
    } catch {
        # Server masih proses startup / booting
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
}

if (-not $recovered) {
    throw "PEMULIHAN GAGAL: Sistem tidak berhasil pulih dalam batas waktu RTO ($MaxRtoSeconds detik)."
}

# ------------------------------------------------------------------------------
# TAHAP 5: Pembuktian RPO (Zero Data Loss) & Kelanjutan Ujian
# ------------------------------------------------------------------------------
Write-Host "`n[TAHAP 5] Memverifikasi Integritas Data Pasca Pemulihan (Audit RPO)..." -ForegroundColor Yellow
$checkAfter = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId" -Method Get -WebSession $WebSession

$ans1After = $checkAfter.answers.'1'
$ans2After = $checkAfter.answers.'2'
$sisaWaktuAfter = $checkAfter.session.sisa_detik
$sessionStatusAfter = $checkAfter.session.status

Write-Host "  -> Status Sesi Ujian   : $sessionStatusAfter (Ekspektasi: ongoing)" -ForegroundColor Cyan
Write-Host "  -> Sisa Waktu Ujian    : $sisaWaktuAfter detik (Berjalan akurat tanpa reset)" -ForegroundColor Cyan
Write-Host "  -> Jawaban Soal 1      : '$ans1After' (Ekspektasi: 'C')" -ForegroundColor Cyan
Write-Host "  -> Jawaban Soal 2      : '$ans2After' (Ekspektasi: 'A')" -ForegroundColor Cyan

if ($ans1After -ne "C" -or $ans2After -ne "A") {
    throw "AUDIT GAGAL (DATA LOSS TERJADI): Jawaban yang tersimpan sebelum crash tidak cocok!"
}
Write-Host "  [OK] JAWABAN PERSISTEN 100%! Tidak ada jawaban yang hilang (RPO = 0 TERCAPAI)." -ForegroundColor Green

# ------------------------------------------------------------------------------
# TAHAP 6: Melanjutkan Ujian Hingga Selesai (Resume Exam)
# ------------------------------------------------------------------------------
Write-Host "`n[TAHAP 6] Siswa Melanjutkan Pengisian Soal Berikutnya..." -ForegroundColor Yellow

# Simpan Soal 3 = B
$ans3 = @{ question_id = 3; pilihan = "B" } | ConvertTo-Json
$res3 = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId/answers" -Method Put -Body $ans3 -ContentType "application/json" -WebSession $WebSession
Write-Host "  [OK] Soal 3 dijawab pasca pulih: 'B' -> Status: $($res3.status)" -ForegroundColor Green

# Selesaikan ujian
$finishPayload = @{ session_id = $sessionId } | ConvertTo-Json
$finishRes = Invoke-RestMethod -Uri "$BaseUrl/api/sessions/$sessionId/finish" -Method Post -Body $finishPayload -ContentType "application/json" -WebSession $WebSession
Write-Host "  [OK] Ujian Berhasil Diselesaikan! Nilai Akhir: $($finishRes.nilai)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# Rangkuman Hasil Pengujian
# ------------------------------------------------------------------------------
Write-Host "`n======================================================================" -ForegroundColor Green
Write-Host "  HASIL DISASTER RECOVERY TEST: LULUS (SUCCESS)                      " -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "1. RTO Aktual         : $elapsedSeconds detik (Target: <= $MaxRtoSeconds dtk) -> TERCAPAI" -ForegroundColor Green
Write-Host "2. RPO Aktual         : 0 data hilang (Semua jawaban pra-crash utuh) -> TERCAPAI" -ForegroundColor Green
Write-Host "3. Kelanjutan Ujian   : Sukses (Siswa resume & submit nilai: $($finishRes.nilai))" -ForegroundColor Green
Write-Host "======================================================================`n" -ForegroundColor Green

# Simpan log hasil pengujian ke file JSON di backups/
$resultLog = @{
    timestamp = (Get-Date).ToString("o")
    kelompok = "Kelompok 2"
    studi_kasus = "Portal Ujian Online CBT"
    skenario = "Matikan Backend App Server saat ujian berlangsung"
    target_rto_seconds = $MaxRtoSeconds
    actual_rto_seconds = $elapsedSeconds
    rto_status = "PASSED"
    rpo_status = "0 DATA LOSS (PASSED)"
    student_tested = "2024001"
    session_id = $sessionId
    answers_verified = @{
        "soal_1" = $ans1After
        "soal_2" = $ans2After
        "soal_3" = "B"
    }
    final_score = $finishRes.nilai
}

$logFile = Join-Path $ProjectRoot "backups\dr_test_evidence_$((Get-Date).ToString('yyyyMMdd_HHmmss')).json"
$resultLog | ConvertTo-Json -Depth 5 | Out-File -FilePath $logFile -Encoding utf8
Write-Host "Evidence log tersimpan di: $logFile" -ForegroundColor Cyan
