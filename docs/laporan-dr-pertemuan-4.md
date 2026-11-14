# Laporan Insiden Disaster Recovery (DR) & Pengujian Otomatisasi Backup
**Praktikum Cloud Computing - Pertemuan 4: DR Execution & Testing**  
**Program Studi Sistem Informasi, Fakultas Sains dan Teknologi**  
**Universitas Islam Negeri Sunan Ampel Surabaya**  
**Tahun Ajaran 2026**

---

## 1. Identitas Kelompok & Studi Kasus

* **Kelompok:** 2 (Dua)
* **Studi Kasus:** Portal Ujian Online CBT (*Computer-Based Testing*)
* **Anggota Tim & Peran DR:**
  1. **Shofie Fadliya Rahma** (NIM: 09020624065) — *Koordinator DR (Incident Commander)*
  2. **Ananda Ayu Kartika Sari** (NIM: 09040624082) — *Eksekutor Recovery (Technical Operator)*
  3. **Falissa Advisherlailillah Puti Esa** (NIM: 09040624086) — *Validator Integritas Data (Data Auditor)*
  4. **Aprilia Nur Maulidya** (NIM: 09010624003) — *Dokumentator & Notulen Insiden*

---

## 2. Ringkasan Eksekutif & Target Metrik DRP

Pada Pertemuan 1, tim telah menyusun dokumen *Disaster Recovery Plan* (DRP) awal yang menetapkan batas toleransi henti layanan (*Recovery Time Objective* / RTO) dan batas toleransi kehilangan data (*Recovery Point Objective* / RPO).

Pada Pertemuan 4 ini, sistem diuji secara nyata terhadap skenario kegagalan backend server (*App Server Crash*) dan integritas pencadangan data (*Scheduled Database Backup & Restore*).

### Matriks Target DRP Awal:
| Parameter | Target DRP | Mekanisme Pencapaian | Kriteria Kelulusan |
|---|---|---|---|
| **RTO Backend App Server** | $\le 120$ detik (2 menit) | Kebijakan Docker `restart: always` + Gateway healthcheck | Layanan kembali merespons HTTP 200 $\le 120$ detik |
| **RPO Jawaban Ujian** | $0$ detik (*Zero Data Loss*) | Autosave langsung commit ke InnoDB (`innodb-flush-log-at-trx-commit=1`) + *LocalStorage client retry* | Jawaban berstatus tersimpan tidak boleh hilang sama sekali |
| **RPO Bencana Host** | $\le 15$ menit | Otomatisasi `mysqldump` berkala ke direktori `backups/` | Kehilangan data maksimal 15 menit jika seluruh volume rusak |
| **Kelanjutan Ujian** | Sukses (*Seamless Resume*) | Sesi ujian berlanjut tanpa restart timer dan siswa dapat submit | Timer akurat, jawaban tersimpan tetap utuh, nilai akhir terhitung |

---

## 3. Otomatisasi Backup Database (Tugas 1)

Untuk memenuhi penugasan pembuatan skrip otomatisasi pencadangan database secara berkala, tim menyediakan 3 jalur implementasi yang fleksibel:

### 3.1. Dari DALAM Container (*In-Container Daemon / Compose Service*)
Layanan `backup` (container `cbt-backup`) diintegrasikan langsung pada file [`docker-compose.yml`](../docker-compose.yml):
```yaml
backup:
  image: mysql:8
  container_name: cbt-backup
  restart: always
  env_file: .env
  environment:
    BACKUP_INTERVAL_SECONDS: "900"  # 15 menit
    KEEP_DAYS: "7"
  volumes:
    - ./backups:/backups
    - ./scripts/backup-daemon.sh:/usr/local/bin/backup-daemon.sh:ro
  entrypoint: ["sh", "/usr/local/bin/backup-daemon.sh"]
  networks:
    - cbt-net
  depends_on:
    mysql:
      condition: service_healthy
```
* **Kelebihan:** Mandiri di dalam jaringan Docker (*zero-dependency on host OS*), otomatis berjalan setiap 15 menit, dan langsung menyimpan dump ke folder `backups/` host via Docker Volume bind-mount.
* **Skrip:** [`scripts/backup-daemon.sh`](../scripts/backup-daemon.sh).

### 3.2. Dari LUAR Container (*Windows PowerShell & Task Scheduler*)
Untuk host berbasis Windows:
* **Skrip Backup:** [`scripts/backup.ps1`](../scripts/backup.ps1)
* **Pendaftaran Otomatis:** [`scripts/register-backup-task.ps1`](../scripts/register-backup-task.ps1) mendaftarkan tugas ke Windows Task Scheduler agar berjalan otomatis setiap 15 menit tanpa intervensi manual.
* **Perintah Uji Manual:**
  ```powershell
  ./scripts/backup.ps1
  ```

### 3.3. Dari LUAR Container (*Linux / macOS Cron*)
Untuk host Linux / server produksi cloud:
* **Skrip Backup:** [`scripts/backup.sh`](../scripts/backup.sh)
* **Entri Crontab Host:**
  ```bash
  */15 * * * * cd /path/ke/cbt-portal && ./scripts/backup.sh >> backups/backup.log 2>&1
  ```

### 3.4. Validasi Integritas File Dump & Kebijakan Retensi
Setiap file hasil backup divalidasi dengan aturan:
1. File harus memiliki penanda resmi footer: `Dump completed`.
2. File berukuran lebih dari 1 KB (mencegah file kosong akibat koneksi database terputus).
3. Pembersihan otomatis file lama yang berumur $> 7$ hari (`KEEP_DAYS=7`).

---

## 4. Eksekusi Disaster Recovery Test (Tugas 2 - Skenario Kelompok 2)

### 4.1. Skenario Pengujian
> **Skenario Kelompok 2:** Matikan container App Server (`session-service`) di tengah-tengah simulasi pengisian soal ujian. Setelah server dihidupkan kembali, buktikan bahwa jawaban siswa yang sudah di-klik/disimpan sebelum server mati tidak hilang dan siswa dapat melanjutkan ujian.

Pengujian dijalankan secara otomatis dan terukur menggunakan skrip pengujian:
* **Windows PowerShell:** [`scripts/test-recovery.ps1`](../scripts/test-recovery.ps1)
* **Linux / Git Bash:** [`scripts/test-recovery.sh`](../scripts/test-recovery.sh)

---

### 4.2. Linimasa & Kronologi Insiden (Menit ke Menit)

```
[11:30:00] SISWA LOGIN & START EXAM
   │  • Siswa NIM 2024001 login ke sistem
   │  • Memulai ujian (Session ID #1, durasi 30 menit / 1800 detik)
   │
[11:30:45] PENGISIAN SOAL AWAL
   │  • Soal 1 dijawab: 'C' -> Status Server: saved ✓
   │  • Soal 2 dijawab: 'A' -> Status Server: saved ✓
   │  • Verifikasi DB: 2 jawaban tercatat di tabel `answers`
   │
[11:31:15.120] WAKTU BENCANA (T0) - CRASH PAKSA
   │  • Eksekutor mematikan container `session-service` (docker kill)
   │  • Request ke endpoint backend gagal (HTTP 502 / Connection Refused)
   │  • Frontend mendeteksi putusnya backend:
   │    Tampil banner: "Server tidak merespons. Menyambungkan ulang..."
   │  • Jawaban baru yang diklik siswa masuk ke antrean lokal (localStorage)
   │
[11:31:15 - 11:31:29] FASE RECOVERY OTOMATIS
   │  • Docker engine mendeteksi exit non-zero
   │  • Policy `restart: always` membangkitkan container `cbt-session` baru
   │  • Gateway Nginx terus memonitor healthcheck upstream
   │
[11:31:29.920] WAKTU PULIH (T1) - SERVER HEALTHY
   │  • Endpoint /api/sessions/1 kembali merespons HTTP 200
   │  • RTO AKTUAL TERCATAT: 14.80 DETIK (Target DRP: <= 120 detik)
   │
[11:31:35] AUDIT INTEGRITAS DATA & RESUME UJIAN
   │  • Soal 1: 'C' (UTUH 100%)
   │  • Soal 2: 'A' (UTUH 100%)
   │  • Sisa Waktu Ujian: 1735 detik (Tidak ter-reset ke 1800)
   │  • RPO AKTUAL: 0 DATA LOSS (100% PERSISTEN)
   │  • Siswa melanjutkan Soal 3 = 'B' dan menyelesaikan ujian
   │  • Nilai Akhir: 100 (Ujian selesai sempurna)
```

---

### 4.3. Bukti Sistem Saat Terjadi Bencana (Crash)

1. **Log Respon Gateway / Client Saat Server Mati:**
   ```
   [T0: 11:31:15] docker kill 4d82b7194f10 (session-service)
   GET http://localhost:3000/api/sessions/1 -> HTTP 502 Bad Gateway
   Exception: The remote server returned an error: (502) Bad Gateway.
   ```
2. **Kondisi Tampilan Frontend (Antrean Lokal Aktif):**
   * Banner Peringatan: `"Server tidak merespons. Menyambungkan ulang..."`
   * Badge Status: `"Menyambungkan..."` / `"Server sibuk. Jawaban tetap antre."`
   * Kunci LocalStorage: `localStorage.getItem("pending_1")` menyimpan antrean jawaban in-flight siswa, siap di-*flush* otomatis ketika server kembali online.

---

### 4.4. Bukti Hasil Pasca Pemulihan (Recovery Audit)

Data yang diambil dari respons server pasca pemulihan (`GET /api/sessions/1`):
```json
{
  "session": {
    "id": 1,
    "exam_id": 1,
    "status": "ongoing",
    "sisa_detik": 1735
  },
  "answers": {
    "1": "C",
    "2": "A"
  }
}
```

* **Validasi Jawaban:** Jawaban Soal 1 (`C`) dan Soal 2 (`A`) identik dengan pilihan sebelum server mati.
* **Validasi Sisa Waktu:** Sisa waktu berkurang secara konsisten (1735 detik), membuktikan bahwa status waktu dihitung berdasarkan `TIMESTAMPDIFF` dari `started_at` di database MySQL, bukan timer lokal browser yang mudah ter-reset.
* **Validasi Nilai Akhir:** Siswa melanjutkan pengisian Soal 3 (`B`) dan menekan tombol *Selesaikan Ujian*:
  ```json
  {
    "status": "finished",
    "benar": 3,
    "total": 3,
    "nilai": 100
  }
  ```

---

## 5. Pengujian Pemulihan Database / Restore (Tugas 3)

Pengujian pemulihan database (*Database Point-in-Time Restore*) diuji menggunakan skrip [`scripts/restore.ps1`](../scripts/restore.ps1) dan [`scripts/restore.sh`](../scripts/restore.sh):

1. **Titik Cadangan Awal:** Dibuat file cadangan `backups/cbt_portal_20261110_113000.sql` saat data masih lengkap.
2. **Simulasi Kerusakan Data:** Tabel `answers` dan `exam_sessions` dikosongkan secara sengaja (`TRUNCATE TABLE`).
3. **Prosedur Restore:**
   ```powershell
   ./scripts/restore.ps1 -BackupFile backups/cbt_portal_20261110_113000.sql -Force
   ```
4. **Validasi Pemulihan:**
   * Skrip memverifikasi penanda `Dump completed` sebelum menyentuh database aktif.
   * Skema database di-drop dan di-create ulang di container MySQL.
   * Seluruh tabel dan baris data terinjeksi kembali dengan sempurna.
   * Layanan backend (`auth`, `exam`, `session`) direstart otomatis untuk menyegarkan koneksi pool.
   * **Waktu Pemulihan Restore (RTO Restore):** 11.45 detik.

---

## 6. Tabel Evaluasi Metrik Target vs Realisasi

| Skenario Bencana | Target DRP (RTO) | Realisasi (RTO) | Target DRP (RPO) | Realisasi (RPO) | Status Evaluasi |
|---|---|---|---|---|---|
| **R1: Crash Backend App Server (DR Test)** | $\le 120$ detik | **14.80 detik** | $0$ detik | **0 data hilang** | **LULUS (100% Sukses)** |
| **R2: Crash Container MySQL (Volume Utuh)** | $\le 300$ detik | **18.20 detik** | $0$ detik | **0 data hilang** | **LULUS (100% Sukses)** |
| **R3/R5: Pemulihan dari Backup Dump (Restore)** | $\le 900$ detik | **11.45 detik** | $\le 15$ menit | **Terkoreksi ke titik backup** | **LULUS (100% Sukses)** |

---

## 7. Lessons Learned & Rekomendasi

1. **Arsitektur Stateless Backend Mempercepat RTO:**  
   Pemisahan *application logic* (Node.js) dari *persistent state* (MySQL) memungkinkan container backend mati dan hidup kembali seketika tanpa kehilangan sesi atau membutuhkan rekonsiliasi state memori yang rumit.
2. **Durabilitas Penuh dengan `innodb-flush-log-at-trx-commit=1`:**  
   Memaksa MySQL menulis setiap transaksi autosave ke disk fisik volume Docker secara sinkron menjamin RPO = 0 untuk semua jawaban yang telah dikonfirmasi server.
3. **Ketahanan Dua Arah (*Server + Client Queue*):**  
   Kombinasi commit database di server dan antrean *LocalStorage* di browser memberikan jaminan ganda: jika server mati saat siswa sedang mengklik jawaban, jawaban tersebut tidak hilang dan akan otomatis di-retry begitu koneksi pulih.
4. **Kesiapan Menuju Pertemuan 5:**  
   Pada Pertemuan 5, sistem akan dioptimalkan lebih lanjut dengan memisahkan file statis (HTML/CSS/JS/Aset Gambar) ke layanan CDN / Storage mandiri (seperti MinIO / Nginx Edge Cache) agar beban traffic frontend tidak mengganggu jalur transmisi autosave ujian.

