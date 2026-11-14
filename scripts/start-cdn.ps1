# ============================================================
# start-cdn.ps1  –  Jalankan stack CDN Pertemuan 5
# ============================================================
# Perintah: .\scripts\start-cdn.ps1
# ============================================================

Set-Location "$PSScriptRoot\.."

Write-Host "=== Pertemuan 5: Membangun dan menjalankan stack CDN ===" -ForegroundColor Cyan

Write-Host "`n[1] Membangun image CDN Edge Node..." -ForegroundColor Yellow
docker compose -f docker-compose.yml -f docker-compose.cdn.yml build cdn-edge

Write-Host "`n[2] Menjalankan seluruh stack (termasuk MinIO & CDN Edge)..." -ForegroundColor Yellow
docker compose -f docker-compose.yml -f docker-compose.cdn.yml up -d --build

Write-Host "`n[3] Menunggu MinIO sehat..." -ForegroundColor Yellow
$retries = 0
do {
    Start-Sleep -Seconds 3
    $status = docker inspect --format "{{.State.Health.Status}}" cbt-minio 2>$null
    $retries++
    Write-Host "    MinIO status: $status (percobaan $retries)"
} while ($status -ne "healthy" -and $retries -lt 20)

Write-Host "`n[4] Status semua kontainer:" -ForegroundColor Yellow
docker compose -f docker-compose.yml -f docker-compose.cdn.yml ps

Write-Host "`n[5] URL Layanan:" -ForegroundColor Green
Write-Host "   App Gateway  : http://localhost:3000"
Write-Host "   CDN Edge     : http://localhost:8080"
Write-Host "   MinIO API    : http://localhost:9000"
Write-Host "   MinIO Console: http://localhost:9001  (minioadmin / minioadmin123)"
Write-Host ""
Write-Host "   Contoh aset via CDN:"
Write-Host "   Banner : http://localhost:8080/cdn/cbt-assets/images/banner.svg"
Write-Host "   Logo   : http://localhost:8080/cdn/cbt-assets/images/logo.svg"
Write-Host ""
Write-Host "   Contoh aset via Gateway:"
Write-Host "   Banner : http://localhost:3000/static/images/banner.svg"
Write-Host ""
Write-Host "=== Stack CDN siap! ===" -ForegroundColor Green

