# ============================================================
# run-cdn-stress.ps1  –  Jalankan stress test CDN Pertemuan 5
# ============================================================
# Perintah: .\scripts\run-cdn-stress.ps1
# Prasyarat: k6 sudah terinstall, stack CDN sudah berjalan
# ============================================================

Set-Location "$PSScriptRoot\.."

Write-Host "=== Pertemuan 5: CDN Stress Test ===" -ForegroundColor Cyan

# Pastikan direktori hasil ada
New-Item -ItemType Directory -Force -Path "loadtest\results" | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ---- Fase 1: Stress test TANPA CDN (gateway langsung melayani file statis) ----
Write-Host "`n[FASE 1] Stress test SEBELUM CDN (file statis dari app server)..." -ForegroundColor Yellow
Write-Host "         URL: http://localhost:3000/ (index.html + inline CSS/JS)"
Write-Host "         Catatan: Sebelum Pertemuan 5, file statis dilayani langsung oleh gateway Nginx."

k6 run `
  --out "json=loadtest/results/pre-cdn-raw-$timestamp.json.gz" `
  --summary-export "loadtest/results/pre-cdn-summary-$timestamp.json" `
  -e BASE_URL=http://localhost:3000 `
  -e CDN_URL=http://localhost:3000 `
  -e MODE=gateway `
  -e RAMP_SEC=20 `
  -e HOLD_SEC=60 `
  loadtest/k6-cdn-stress.js

Write-Host "`n[FASE 1] Selesai. Hasil: loadtest/results/pre-cdn-summary-$timestamp.json" -ForegroundColor Green

# Jeda singkat antara fase
Start-Sleep -Seconds 10

# ---- Fase 2: Stress test DENGAN CDN (CDN Edge Node) ----
Write-Host "`n[FASE 2] Stress test SETELAH CDN (CDN Edge Node + MinIO)..." -ForegroundColor Yellow
Write-Host "         URL CDN langsung: http://localhost:8080/cdn/cbt-assets/images/*"
Write-Host "         URL via Gateway : http://localhost:3000/static/images/*"

k6 run `
  --out "json=loadtest/results/cdn-raw-$timestamp.json.gz" `
  --summary-export "loadtest/results/cdn-summary-$timestamp.json" `
  -e BASE_URL=http://localhost:3000 `
  -e CDN_URL=http://localhost:8080 `
  -e MODE=both `
  -e RAMP_SEC=20 `
  -e HOLD_SEC=60 `
  loadtest/k6-cdn-stress.js

Write-Host "`n[FASE 2] Selesai. Hasil: loadtest/results/cdn-summary-$timestamp.json" -ForegroundColor Green

Write-Host "`n=== Semua fase selesai. Lihat hasil di loadtest/results/ ===" -ForegroundColor Green
Write-Host "    Bandingkan pre-cdn-summary-$timestamp.json vs cdn-summary-$timestamp.json"

