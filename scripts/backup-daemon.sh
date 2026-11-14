#!/bin/sh
# ==============================================================================
# In-Container Scheduled Backup Daemon (MySQL Dump)
# Pertemuan 4: Otomatisasi Backup dari DALAM Container
# ==============================================================================
set -e

BACKUP_DIR="/backups"
KEEP_DAYS="${KEEP_DAYS:-7}"
INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-900}" # 900 detik = 15 menit

mkdir -p "$BACKUP_DIR"
echo "[CRON-BACKUP] Layanan otomatisasi backup dalam container aktif."
echo "[CRON-BACKUP] Menjalankan backup setiap $INTERVAL_SECONDS detik ($(( INTERVAL_SECONDS / 60 )) menit)."

# Jalankan dump pertama setelah container mysql siap
sleep 10

while true; do
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  OUT_FILE="$BACKUP_DIR/cbt_portal_${TIMESTAMP}.sql"
  TMP_FILE="${OUT_FILE}.tmp"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRON-BACKUP] Memulai dump database '$MYSQL_DATABASE'..."

  if MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -h mysql -u root \
      --single-transaction --routines --triggers --no-tablespaces \
      "$MYSQL_DATABASE" > "$TMP_FILE"; then
    
    # Validasi footer mysqldump
    if tail -n 10 "$TMP_FILE" | grep -q "Dump completed"; then
      mv "$TMP_FILE" "$OUT_FILE"
      SIZE=$(ls -lh "$OUT_FILE" | awk '{print $5}')
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRON-BACKUP] Backup SUKSES: $OUT_FILE ($SIZE)"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRON-BACKUP] ERROR: Header/footer tidak lengkap. File dihapus."
      rm -f "$TMP_FILE"
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRON-BACKUP] ERROR: Perintah mysqldump gagal dieksekusi."
    rm -f "$TMP_FILE"
  fi

  # Bersihkan file backup lama > KEEP_DAYS
  find "$BACKUP_DIR" -name "cbt_portal_*.sql*" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true

  echo "[CRON-BACKUP] Menunggu $INTERVAL_SECONDS detik hingga jadwal backup berikutnya..."
  sleep "$INTERVAL_SECONDS"
done

