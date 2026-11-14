# Disaster Recovery Plan - Portal Ujian Online CBT

## Target
| Parameter | Target | Cara dipenuhi |
|---|---|---|
| RPO (jawaban terkonfirmasi) | Target 0 untuk crash proses yang telah ACK | Autosave commit ke MySQL (`innodb-flush-log-at-trx-commit=1`); tetap perlu uji pemulihan dan replika/offsite untuk bencana host |
| RPO (bencana data/host hilang) | maks. 15 menit | `mysqldump` berkala ke `backups/` |
| RTO backend | Target maks. 2 menit | `restart: always` + healthcheck + tes recovery; belum terbukti untuk semua jenis kegagalan |

## Skenario dan penanganan
| Skenario | Dampak | Pemulihan |
|---|---|---|
| Container service mati/crash | Request gagal sebentar; frontend menampilkan "Menyambungkan ulang..." dan menyimpan jawaban di antrean lokal | Otomatis (`restart: always`). Uji: `./scripts/test-recovery.sh` |
| Container MySQL dihapus | Layanan berhenti sementara | `docker compose up -d`; data tetap di volume `cbt_mysqldata` |
| Volume hilang / data rusak | Data hilang | `./scripts/restore.sh backups/<berkas>.sql.gz` lalu `docker compose restart auth-service exam-service session-service` |
| Host mati | Semua layanan berhenti | Pulihkan host, `docker compose up -d --build`, restore backup bila volume hilang |
| AWS: task mati | ECS menjalankan task pengganti, ALB hanya mengarah ke target sehat | Otomatis |
| AWS: data RDS | - | Backup otomatis RDS 7 hari (point-in-time) |

## Backup terjadwal (cron & in-container)
Tersedia 3 mekanisme otomatisasi backup sesuai kebutuhan lingkungan:

1. **In-Container Backup (Otomatis via Docker Compose):**
   Service `cbt-backup` telah terintegrasi di `docker-compose.yml`. Service ini berjalan di latar belakang dalam container Alpine/MySQL, melakukan dump otomatis setiap 15 menit ke `./backups/` host, dan membersihkan backup usang (> 7 hari). Tidak membutuhkan konfigurasi cron host.

2. **Windows Task Scheduler (PowerShell Native):**
   Jalankan pendaftaran tugas otomatis:
   ```powershell
   ./scripts/register-backup-task.ps1 -IntervalMinutes 15
   ```
   Atau jalankan backup manual kapan saja:
   ```powershell
   ./scripts/backup.ps1
   ```

3. **Linux / macOS Cron:**
   ```bash
   */15 * * * * cd /path/ke/cbt-portal && ./scripts/backup.sh >> backups/backup.log 2>&1
   ```
   Atau jalankan manual:
   ```bash
   ./scripts/backup.sh
   ```

## Pengujian Pemulihan (DR Test Pertemuan 4)
1. Jalankan stack: `docker compose up -d --build`, tunggu semua service siap (`healthy`).
2. **Eksekusi DR Test (Skenario Kelompok 2):**
   - Di Windows PowerShell:
     ```powershell
     ./scripts/test-recovery.ps1
     ```
   - Di Linux / Git Bash:
     ```bash
     ./scripts/test-recovery.sh session-service
     ```
   Skrip ini memverifikasi:
   - Login siswa & simpan jawaban (Soal 1 & 2).
   - Mematikan container `session-service` di tengah ujian.
   - Mengukur durasi pemulihan (RTO harus $\le 120$ detik).
   - Memvalidasi bahwa jawaban tidak hilang (RPO = 0).
   - Memvalidasi siswa dapat melanjutkan ujian hingga selesai.
3. **Uji Pemulihan Database (Restore):**
   - Di Windows PowerShell:
     ```powershell
     ./scripts/restore.ps1
     ```
   - Di Linux / Git Bash:
     ```bash
     ./scripts/restore.sh backups/<berkas>.sql.gz
     ```

**Penting:** Restore sekarang memverifikasi integritas gzip dan footer mysqldump **sebelum** menghapus database aktif. Lakukan backup offsite dan tes restore berkala. Lihat [full audit](AUDIT_FULL_2026-11-08.md) untuk risiko DRP yang belum selesai.
