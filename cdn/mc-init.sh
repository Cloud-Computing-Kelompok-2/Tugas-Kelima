#!/bin/sh
# ============================================================
# Skrip inisialisasi MinIO: buat bucket & atur kebijakan publik
# Dijalankan sekali oleh service mc-init (Docker Compose)
# Pertemuan 5: File Management & CDN berbasis Docker
# ============================================================

set -e

MC=/usr/bin/mc
ALIAS=local
MINIO_URL=${MINIO_URL:-http://minio:9000}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}
BUCKET=${MINIO_BUCKET:-cbt-assets}

# Tunggu MinIO siap
echo "[mc-init] Menunggu MinIO siap di ${MINIO_URL}..."
until $MC alias set $ALIAS "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" 2>/dev/null; do
  sleep 2
done
echo "[mc-init] MinIO terhubung."

# Buat bucket jika belum ada
if $MC ls $ALIAS/$BUCKET >/dev/null 2>&1; then
  echo "[mc-init] Bucket '${BUCKET}' sudah ada."
else
  $MC mb $ALIAS/$BUCKET
  echo "[mc-init] Bucket '${BUCKET}' dibuat."
fi

# Atur kebijakan baca-publik (download tanpa autentikasi)
$MC anonymous set download $ALIAS/$BUCKET
echo "[mc-init] Kebijakan download publik diterapkan pada '${BUCKET}'."

# Upload file contoh (banner & logo soal) agar stress test ada URL nyata
cat > /tmp/sample-banner.svg << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="800" height="200">
  <rect width="800" height="200" fill="#0f5c6e"/>
  <text x="400" y="120" text-anchor="middle" font-family="sans-serif"
        font-size="48" fill="white" font-weight="bold">Portal Ujian CBT</text>
</svg>
SVG

cat > /tmp/sample-logo.svg << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
  <circle cx="32" cy="32" r="30" fill="#0f5c6e"/>
  <text x="32" y="40" text-anchor="middle" font-family="sans-serif"
        font-size="22" fill="white" font-weight="bold">CBT</text>
</svg>
SVG

$MC cp /tmp/sample-banner.svg $ALIAS/$BUCKET/images/banner.svg
$MC cp /tmp/sample-logo.svg   $ALIAS/$BUCKET/images/logo.svg
echo "[mc-init] File contoh di-upload ke '${BUCKET}/images/'."

echo "[mc-init] Selesai."

