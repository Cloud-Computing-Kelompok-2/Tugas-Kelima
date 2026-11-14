# Laporan Praktikum Cloud Computing - Pertemuan 5
## File Management & Content Delivery Network (CDN) Berbasis Docker
**Optimasi Pengiriman File Statis Menggunakan Arsitektur CDN Lokal**

---

* **Program Studi:** Sistem Informasi
* **Fakultas:** Sains dan Teknologi
* **Perguruan Tinggi:** Universitas Islam Negeri Sunan Ampel Surabaya
* **Mata Kuliah:** Praktikum Cloud Computing
* **Kelompok:** 2 (Dua)
* **Studi Kasus:** Portal Ujian Online CBT (*Computer-Based Testing*)
* **Anggota Tim:**
  1. **Shofie Fadliya Rahma** (NIM: 09020624065) — *Cloud Infrastructure & CDN Engineer*
  2. **Ananda Ayu Kartika Sari** (NIM: 09040624082) — *Backend & Storage Integration Engineer*
  3. **Falissa Advisherlailillah Puti Esa** (NIM: 09040624086) — *Performance & Stress Test Specialist*
  4. **Aprilia Nur Maulidya** (NIM: 09010624003) — *Technical Documentation & Quality Assurance*

---

## 1. Latar Belakang & Tujuan Praktikum

Pada arsitektur aplikasi web modern berskala besar (termasuk Portal Ujian Online CBT yang melayani ribuan mahasiswa serentak), pemisahan antara pemrosesan dinamis (*dynamic business logic*) dan pengiriman berkas statis (*static asset delivery*) merupakan prinsip fundamental komputasi awan.

Sebelum Pertemuan 5, berkas statis (seperti gambar logo, banner ujian, dokumen soal PDF/SVG) dilayani langsung oleh server aplikasi (App Server / Nginx Gateway lokal). Hal ini menimbulkan kelemahan struktural serius:
1. **Penurunan Throughput Backend:** Setiap *thread/event loop worker* pada backend yang sibuk membaca file biner dari *disk* I/O akan terblokir untuk memproses logika penting (seperti *autosave* jawaban ujian atau autentikasi).
2. **Beban I/O & Memory Bloat:** Melayani berkas statis lewat *application process* meningkatkan penggunaan RAM secara drastis (*buffer overhead*).
3. **Kegagalan Skalabilitas Vertikal/Horizontal:** Ketika ribuan siswa mengakses aset gambar soal secara serentak, koneksi ke App Server menjadi jenuh (*connection starvation*), memicu *timeout* pada endpoint API kritis.

### Tujuan Utama:
1. Mengisolasi pemrosesan logika bisnis aplikasi dengan memindahkan pengiriman file statis ke infrastruktur terpisah.
2. Menerapkan sistem *Object Storage* mandiri yang kompatibel dengan protokol S3 (menggunakan MinIO).
3. Menggelar *Edge/CDN Node* berbasis Nginx dengan kemampuan *disk caching* dan manajemen *header* HTTP Cache Control.
4. Mengintegrasikan aplikasi agar proses upload/download aset langsung menunjuk ke CDN/Storage mandiri tanpa membebani memori App Server (*zero-copy architecture*).
5. Melakukan stress test komparatif menggunakan k6 untuk memvalidasi peningkatan performa sebelum dan sesudah penerapan CDN.

---

## 2. Arsitektur Infrastruktur CDN Lokal

Berikut adalah rancangan topologi infrastruktur Docker yang diterapkan pada Pertemuan 5:

```
[ BROWSER / KLIEN UJIAN ]
     |
     +--- (1) Request Halaman & API ---> [ Nginx API Gateway :3000 ]
     |                                          |
     |                                          +---> [ auth-service :3000 ]
     |                                          +---> [ session-service :3000 ]
     |                                          +---> [ exam-service :3000 ]
     |                                                      |
     |                                                      +--- Generate Presigned URL (AWS Signature V4)
     |
     +--- (2) Upload Langsung Berkas ---> [ MinIO S3 Object Storage :9000 ] (Bucket: cbt-assets)
     |
     +--- (3) Akses Aset Statis (Cached) -> [ CDN Edge Node Nginx :8080 ]
                                                    |
                                    +---------------+---------------+
                                    |                               |
                              [ CACHE HIT ]                   [ CACHE MISS ]
                            (Langsung dari                   (Ambil dari MinIO :9000,
                             Disk Cache Nginx)                simpan ke Disk Cache CDN,
                             Latensi < 100 ms                 kirim ke Klien)
```

### Komponen Infrastruktur:
1. **MinIO Object Storage (`cbt-minio`):**
   * *Image:* `insectai/minio:latest`
   * *Port Host:* 9000 (API S3 REST) & 9001 (Web Console Admin)
   * *Fungsi:* Menyimpan objek biner (gambar banner, logo, berkas lampiran soal ujian) secara terpusat dan terisolasi dari *container* backend.
   * *Bucket:* `cbt-assets` dengan kebijakan akses *download publik* (anonymous read).
2. **MinIO Client Initialization (`cbt-mc-init`):**
   * *Container* satu kali jalan (*one-shot service*) yang otomatis menginisialisasi alias MinIO, membuat bucket `cbt-assets`, mengatur *anonymous download policy*, dan mengunggah sampel aset awal (`banner.svg` dan `logo.svg`).
3. **CDN Edge Node (`cbt-cdn-edge`):**
   * *Image:* `cbt-cdn-edge:1.0` (Nginx 1.27 Alpine)
   * *Port Host:* 8080
   * *Fungsi:* Bertindak sebagai *Reverse Proxy Cache* di depan MinIO.
   * *Fitur Cache:*
     * Direktori cache: `/var/cache/nginx/cdn`
     * Ukuran zona kunci memori: 10MB (`cdn_zone:10m`)
     * Maksimal kapasitas cache disk: 512MB
     * Masa retensi cache: 7 hari (`inactive=7d`)
     * Header response: `X-Cache-Status` (`HIT`/`MISS`), `X-CDN-Node: edge-01`, dan `Cache-Control: public, max-age=604800, immutable`.
4. **API Gateway Nginx (`cbt-portal-gateway-1`):**
   * *Port Host:* 3000
   * *Fungsi:* Meneruskan path `/static/*` langsung ke `cdn-edge`, serta memvalidasi endpoint `/api/assets/*` ke `exam-service`.

---

## 3. Implementasi Tugas Terstruktur

### 3.1. Tugas 1: Isolasi File Statis dari App Server
Aplikasi dirombak sehingga seluruh *binary assets* (gambar/dokumen ujian) tidak lagi disimpan di folder lokal `public/` atau dibaca via `fs.readFile` di Express.js.
* Gateway Nginx utama (`gateway.conf`) dikonfigurasi untuk mendelegasikan rute `/static/` ke upstream CDN:
  ```nginx
  upstream cdn_backend {
    zone cdn_backend 32k;
    server cdn-edge:80 resolve;
    keepalive 32;
  }

  location /static/ {
    rewrite ^/static/(.*) /cdn/cbt-assets/$1 break;
    proxy_pass http://cdn_backend;
    proxy_set_header Host cdn-edge;
    add_header X-Served-By "cbt-cdn-edge" always;
  }
  ```
* App server (`exam-service`) murni mengembalikan metadata JSON berisi URL CDN absolut atau relatif ke aset tersebut.

### 3.2. Tugas 2: Deployment MinIO & Nginx CDN Edge Node Menggunakan Docker
Konfigurasi dideklarasikan secara deklaratif melalui [`docker-compose.cdn.yml`](../docker-compose.cdn.yml):
```yaml
services:
  minio:
    image: insectai/minio:latest
    container_name: cbt-minio
    restart: always
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: "${MINIO_ROOT_USER:-minioadmin}"
      MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD:-minioadmin123}"
    volumes:
      - miniodata:/data
    networks:
      - cbt-net
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    healthcheck:
      test: ["CMD", "/usr/bin/wget", "-qO-", "http://127.0.0.1:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 10

  cdn-edge:
    build:
      context: ./cdn
      dockerfile: Dockerfile
    image: cbt-cdn-edge:1.0
    container_name: cbt-cdn-edge
    restart: always
    ports:
      - "127.0.0.1:8080:80"
    networks:
      - cbt-net
    depends_on:
      minio:
        condition: service_healthy
```

Konfigurasi caching Nginx CDN Edge ([`cdn/nginx-cdn.conf`](../cdn/nginx-cdn.conf)):
```nginx
proxy_cache_path /var/cache/nginx/cdn
  levels=1:2
  keys_zone=cdn_zone:10m
  max_size=512m
  inactive=7d
  use_temp_path=off;

server {
  listen 80;
  location /cdn/ {
    rewrite ^/cdn/(.*) /$1 break;
    proxy_pass http://minio:9000;
    proxy_cache cdn_zone;
    proxy_cache_key $uri;
    proxy_cache_valid 200 206 7d;
    proxy_cache_valid 404 1m;
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
    proxy_cache_lock on;

    add_header X-Cache-Status $upstream_cache_status always;
    add_header X-CDN-Node "edge-01" always;
    add_header Cache-Control "public, max-age=604800, immutable" always;
  }
}
```

### 3.3. Tugas 3: Integrasi Upload & Download Langsung ke CDN/Storage
Menggunakan pola arsitektur **Presigned PUT URL (Zero-Copy)**:
1. **Endpoint Pembuatan Presigned URL:**
   * Ditambahkan pada `exam-service` di file [`src/services/exam/assets.js`](../src/services/exam/assets.js).
   * Klien meminta URL upload: `POST /api/assets/upload-url` dengan menyertakan nama file dan MIME type.
   * Backend menandatangani permintaan menggunakan algoritma HMAC-SHA256 (AWS Signature Version 4) tanpa memerlukan kredensial S3 diekspos ke klien.
   * Backend mengembalikan `uploadUrl` (menunjuk ke MinIO) dan `cdnUrl` (menunjuk ke CDN Edge).
2. **Proses Upload:**
   * Klien mengunggah *payload* biner langsung ke MinIO menggunakan HTTP `PUT`. Berkas tidak melewati Express backend, sehingga konsumsi memori App Server tetap 0 MB untuk lalu lintas file.
3. **Proses Download:**
   * Antarmuka frontend ([`public/index.html`](../public/index.html)) mengambil data aset via `/api/assets/list` dan merender gambar melalui URL CDN: `http://localhost:8080/cdn/cbt-assets/images/banner.svg` atau `http://localhost:3000/static/images/banner.svg`.

---

## 4. Eksekusi Stress Test & Perbandingan Performa

Untuk membuktikan efektivitas arsitektur CDN secara kuantitatif, dilakukan stress test dengan beban tinggi menggunakan Grafana k6 ([`loadtest/k6-cdn-stress.js`](../loadtest/k6-cdn-stress.js)).

### 4.1. Metodologi Pengujian
* **Beban Virtual Users (VU):** 100 VU konkuren simultan.
* **Durasi Uji:** 30 detik *continuous hammering*.
* **Parameter Uji:**
  * **Skenario 1 (Sebelum CDN / Direct Origin):** Permintaan diarahkan langsung ke storage backend MinIO tanpa lapisan caching (`http://localhost:9000/cbt-assets/images/banner.svg`).
  * **Skenario 2 (Sesudah CDN / Nginx Edge Cache):** Permintaan diarahkan ke CDN Edge Node dengan *disk cache* aktif (`http://localhost:8080/cdn/cbt-assets/images/banner.svg`).

### 4.2. Hasil Pengujian Kuantitatif (Tabel Komparasi)

Berdasarkan data metrik resmi k6 yang tercatat pada [`loadtest/results/before_cdn_summary.json`](../loadtest/results/before_cdn_summary.json) dan [`loadtest/results/with_cdn_summary.json`](../loadtest/results/with_cdn_summary.json):

| Parameter Metrik | Sebelum CDN (Direct Origin) | Sesudah CDN (Nginx Edge Cache) | Evaluasi / Delta Performa |
|---|---|---|---|
| **Total Permintaan Terlayani (Requests)** | 2.613 request | **15.004 request** | **Meningkat +474,2% (5,7x lipat)** |
| **Throughput Rata-rata (Req/s)** | 86,0 req/s | **496,9 req/s** | **Meningkat +410,9 req/s (5,7x lebih tinggi)** |
| **Latensi Rata-rata (*Average Latency*)** | 941,01 ms | **144,39 ms** | **6,5x lebih cepat (-84,7% waktu tunggu)** |
| **Latensi Median ($p_{50}$)** | 383,00 ms | **80,00 ms** | **4,8x lebih cepat (-79,1%)** |
| **Latensi Persentil 90 ($p_{90}$)** | 2.262,40 ms | **294,00 ms** | **7,7x lebih cepat (-87,0%)** |
| **Latensi Persentil 95 ($p_{95}$)** | 3.782,80 ms | **407,00 ms** | **9,3x lebih cepat (-89,2%)** |
| **Latensi Maksimum (*Peak Latency*)** | 11.227,00 ms (11,2 detik) | **3.855,00 ms** | **Puncak lonjakan terpangkas 65,7%** |
| **Tingkat Keberhasilan (*Success Rate*)** | 98,97% *(Terjadi Timeouts)* | **100,00% *(Zero Errors)*** | **Resiliensi sempurna pada CDN** |
| **Rasio Cache Hit (*Cache Hit Ratio*)** | 0,00% (Semua hit ke disk MinIO) | **100,00% (Hit di Edge Cache)** | **100% beban terisolasi dari Origin** |
| **Total Data Terkirim (*Data Transferred*)** | 2,16 MB | **15,51 MB** | **Kapasitas transfer naik 7,2x** |

### 4.3. Grafik Perbandingan Kinerja

Visualisasi perbandingan performa dihasilkan menggunakan script analitik [`loadtest/plot_cdn_comparison.py`](../loadtest/plot_cdn_comparison.py) dan tersimpan di [`loadtest/results/cdn_performance_comparison.png`](../loadtest/results/cdn_performance_comparison.png):

```
+----------------------------------------------------------------------------------------------------+
|               EVALUASI KINERJA CDN LOKAL BERBASIS DOCKER (PERTEMUAN 5)                             |
|                           Portal Ujian CBT - Kelompok 2                                            |
+-------------------------------------------------+--------------------------------------------------+
|           THROUGHPUT PERMINTAAN (REQ/S)         |               LATENSI RESPON (MS)                |
|           [Semakin tinggi semakin baik]         |           [Semakin rendah semakin baik]          |
|                                                 |                                                  |
| 500 |                  [ 496.9 rps ]            | 4000 | [ 3783 ms ]                               |
|     |                      |====|               |      |    |==|                                   |
| 400 |                      |====|               | 3000 |    |==|                                   |
|     |                      |====|               |      |    |==|                                   |
| 300 |                      |====|               | 2000 |    |==| [ 2262 ms ]                       |
|     |                      |====|               |      |    |==|    |==|                           |
| 200 |                      |====|               | 1000 |    |==|    |==| [ 941 ms ]                |
|     |   [ 86.0 rps ]       |====|               |      |    |==|    |==|    |==|   [ 407 ms ]      |
| 100 |       |==|           |====|               |    0 +----+--+----+--+----+--+------+--+--------+
|   0 +-------+--+-----------+----+---------------+      | Sebelum (Origin) | Sesudah (CDN Edge)   |
|     |  Sebelum (Origin) | Sesudah (CDN)         |      | Latensi p95 terpangkas drastis (-89.2%)|
+-------------------------------------------------+--------------------------------------------------+
```

### 4.4. Analisis Teknis Keberhasilan
1. **Penyerapan Beban di Lapisan Terluar (*Edge Offloading*):**
   Dengan *Cache Hit Rate* 100%, MinIO hanya menerima **1 permintaan pertama** (*Cache MISS*). Sebanyak 15.003 permintaan berikutnya dijawab langsung dari RAM dan cache disk Nginx.
2. **Eliminasi Latensi I/O & Protokol S3:**
   MinIO memerlukan autentikasi metadata, enkripsi header, dan pencarian file object S3 pada setiap request. Sebaliknya, Nginx menyajikan berkas dengan mekanisme kernel `sendfile` dan `tcp_nopush` yang langsung menyalurkan *byte stream* dari buffer disk ke soket TCP tanpa context switching CPU.
3. **Mencegah Kegagalan Koneksi (*Zero Timeout*):**
   Pada uji Sebelum CDN, koneksi ke MinIO mengalami *starvation* di level 100 VU sehingga menyebabkan latensi melambung hingga 11,2 detik dan beberapa request mengalami *timeout* (sukses hanya 98,97%). Pada CDN Edge Node, tingkat kesuksesan stabil sempurna di **100,00%**.

---

## 5. Verifikasi Header Cache HTTP & Bukti Validasi

Pengujian respon menggunakan cURL membuktikan operasional header CDN yang berjalan sesuai standar RFC 7234:

### Uji 1: Permintaan Pertama (Cold Cache - MISS)
```http
HTTP/1.1 200 OK
Server: nginx
Date: Tue, 10 Nov 2026 07:24:34 GMT
Content-Type: image/svg+xml
Content-Length: 272
ETag: "aee7e8afa42c62714f2e519adb89d189"
X-Cache-Status: MISS
X-CDN-Node: edge-01
Cache-Control: public, max-age=604800, immutable
Access-Control-Allow-Origin: *
```
* Status `X-Cache-Status: MISS` menunjukkan berkas belum tersedia di cache CDN dan diambil pertama kali dari MinIO.

### Uji 2: Permintaan Kedua dan Seterusnya (Warm Cache - HIT)
```http
HTTP/1.1 200 OK
Server: nginx
Date: Tue, 10 Nov 2026 07:24:50 GMT
Content-Type: image/svg+xml
Content-Length: 272
ETag: "aee7e8afa42c62714f2e519adb89d189"
X-Cache-Status: HIT
X-CDN-Node: edge-01
Cache-Control: public, max-age=604800, immutable
Access-Control-Allow-Origin: *
```
* Header `X-Cache-Status: HIT` membuktikan respon dilayani langsung dari media cache Nginx tanpa menyentuh container MinIO.

---

## 6. Dokumentasi Penggunaan AI (Prompt Log)

Sesuai ketentuan praktikum cloud computing mengenai pelaporan penggunaan AI:

| No | Modul / Komponen | Prompt yang Digunakan | Alat AI | Hasil & Modifikasi yang Dilakukan |
|---|---|---|---|---|
| 1 | **Nginx CDN Edge Caching** | *"Buatkan konfigurasi Nginx reverse proxy untuk CDN lokal di depan MinIO dengan cache disk 512MB, masa retensi 7 hari, header X-Cache-Status, dan Cache-Control immutable."* | Claude Sonnet / Gemini | Dihasilkan berkas [`cdn/nginx-cdn.conf`](../cdn/nginx-cdn.conf). Dilakukan penyesuaian direktif `rewrite` path `/cdn/<bucket>/` dan penambahan *CORS header* untuk akses lintas port. |
| 2 | **Presigned PUT URL Node.js** | *"Bagaimana cara membuat presigned PUT URL untuk MinIO S3 menggunakan Node.js crypto murni (AWS Signature V4) tanpa menginstall library eksternal AWS SDK?"* | Claude Sonnet / Gemini | Dihasilkan fungsi `presignedPutUrl` di [`src/services/exam/assets.js`](../src/services/exam/assets.js) dengan tanda tangan HMAC-SHA256 yang aman dan kadaluarsa 300 detik. |
| 3 | **Docker Compose Override CDN** | *"Susun docker-compose override untuk menyertakan container MinIO dan CDN Node Nginx dengan healthcheck wget dan skrip inisialisasi bucket otomatis."* | Claude Sonnet / Gemini | Dihasilkan [`docker-compose.cdn.yml`](../docker-compose.cdn.yml) menggunakan image `insectai/minio:latest` yang menggabungkan server MinIO dan utilitas `mc` dalam satu lingkungan. |
| 4 | **k6 CDN Benchmark Script** | *"Buat script stress test k6 untuk membandingkan throughput dan latensi (avg, p50, p90, p95) antara endpoint origin S3 vs CDN Edge caching dengan export JSON."* | Claude Sonnet / Gemini | Dihasilkan skrip [`loadtest/k6-cdn-stress.js`](../loadtest/k6-cdn-stress.js) dan [`loadtest/plot_cdn_comparison.py`](../loadtest/plot_cdn_comparison.py) untuk visualisasi perbandingan grafik. |

---

## 7. Kesimpulan & Rekomendasi Arsitektur Produksi

1. **Kesimpulan Teknis:**
   * Pemisahan berkas statis dari server aplikasi ke sistem storage mandiri (MinIO) dan penempatan CDN Edge Node (Nginx Cache) berhasil meningkatkan ketahanan dan kapasitas Portal Ujian CBT secara dramatis:
     * **Throughput melonjak 5,7x lipat** (dari 86,0 req/s menjadi 496,9 req/s).
     * **Latensi p95 terpangkas 89,2%** (dari 3.782,8 ms menjadi 407,0 ms).
     * **Keandalan request mencapai 100% tanpa error/timeout.**
   * Node aplikasi (`exam-service`, `session-service`) kini sepenuhnya terbebas dari beban melayani aset statis, sehingga seluruh daya komputasi dan memori dialokasikan untuk pemrosesan jawaban ujian siswa.

2. **Pemetaan ke Lingkungan Produksi Cloud (AWS):**
   * Di lingkungan cloud produksi AWS, arsitektur lokal Docker ini secara langsung dipetakan ke:
     * **MinIO Docker Container** $\rightarrow$ **Amazon S3 (Simple Storage Service)** dengan *lifecycle policy* dan enkripsi AES-256.
     * **Nginx CDN Edge Container** $\rightarrow$ **Amazon CloudFront CDN** dengan *Edge Locations* terdistribusi global dan integrasi sertifikat SSL AWS Certificate Manager (ACM).
     * **Presigned URL Generator** $\rightarrow$ **AWS SDK IAM Presigned URL** dengan otorisasi berbasis peran (IAM Role).

---
*Laporan disusun dan diverifikasi oleh Kelompok 2 Praktikum Cloud Computing (2026).*

