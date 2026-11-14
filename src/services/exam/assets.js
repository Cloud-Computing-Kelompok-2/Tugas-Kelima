// ============================================================
// assets.js  –  Modul File/CDN untuk exam-service
// Pertemuan 5: File Management & CDN berbasis Docker
// ============================================================
// Endpoints:
//   POST   /api/assets/upload-url   → presigned PUT URL ke MinIO (upload browser langsung)
//   GET    /api/assets/list         → daftar aset dalam bucket
//   GET    /api/assets/cdn-url/:key → URL publik melalui CDN Edge Node
//
// Alur upload (zero-copy melalui app server):
//   1. Browser POST /api/assets/upload-url  { filename, contentType }
//      → exam-service kembalikan { uploadUrl, cdnUrl }
//   2. Browser PUT langsung ke uploadUrl (MinIO internal di Docker)
//      (di lingkungan nyata, MinIO diekspos lewat gateway atau CDN)
//   3. Browser baca aset melalui cdnUrl  →  CDN Edge Node → MinIO
// ============================================================

const { Router } = require('express');
const crypto = require('crypto');

// Env MinIO (diisi oleh docker-compose.cdn.yml)
const MINIO_ENDPOINT     = process.env.MINIO_ENDPOINT     || 'http://minio:9000';
const MINIO_BUCKET       = process.env.MINIO_BUCKET       || 'cbt-assets';
const MINIO_ROOT_USER    = process.env.MINIO_ROOT_USER    || 'minioadmin';
const MINIO_ROOT_PASSWORD = process.env.MINIO_ROOT_PASSWORD || 'minioadmin123';
const CDN_PUBLIC_URL     = process.env.CDN_PUBLIC_URL     || 'http://localhost:8080';

// ---- Minimal AWS Signature V4 untuk presigned PUT ----
// (Tanpa SDK eksternal; hanya crypto bawaan Node.js)

const REGION  = 'us-east-1';   // MinIO: nilai region tidak penting, harus konsisten
const SERVICE = 's3';

function hmac(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest();
}

function sign(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest('hex');
}

function getSigningKey(secretKey, dateStamp, region, service) {
  const kDate    = hmac('AWS4' + secretKey, dateStamp);
  const kRegion  = hmac(kDate, region);
  const kService = hmac(kRegion, service);
  return hmac(kService, 'aws4_request');
}

/**
 * Buat presigned PUT URL ke MinIO (berlaku EXPIRES detik).
 * Referensi: https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
 */
function presignedPutUrl(objectKey, contentType, expiresSeconds = 300) {
  const now      = new Date();
  const amzDate  = now.toISOString().replace(/[:\-]|\.\d{3}/g, '').slice(0, 15) + 'Z'; // 20240101T120000Z
  const dateStamp = amzDate.slice(0, 8);                                                 // 20240101

  const credentialScope = `${dateStamp}/${REGION}/${SERVICE}/aws4_request`;
  const credential      = `${MINIO_ROOT_USER}/${credentialScope}`;

  const encodedKey = objectKey.split('/').map(encodeURIComponent).join('/');
  const host        = new URL(MINIO_ENDPOINT).host;

  const queryParams = [
    ['X-Amz-Algorithm',  'AWS4-HMAC-SHA256'],
    ['X-Amz-Credential', credential],
    ['X-Amz-Date',       amzDate],
    ['X-Amz-Expires',    String(expiresSeconds)],
    ['X-Amz-SignedHeaders', 'content-type;host'],
  ].map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');

  const canonicalRequest = [
    'PUT',
    `/${MINIO_BUCKET}/${encodedKey}`,
    queryParams,
    `content-type:${contentType}\nhost:${host}\n`,
    'content-type;host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    crypto.createHash('sha256').update(canonicalRequest).digest('hex'),
  ].join('\n');

  const signingKey  = getSigningKey(MINIO_ROOT_PASSWORD, dateStamp, REGION, SERVICE);
  const signature   = sign(signingKey, stringToSign);

  const uploadUrl = `${MINIO_ENDPOINT}/${MINIO_BUCKET}/${encodedKey}?${queryParams}&X-Amz-Signature=${signature}`;
  return uploadUrl;
}

// Ekstensi yang diizinkan untuk upload
const ALLOWED_TYPES = new Map([
  ['image/jpeg',  'jpg'],
  ['image/png',   'png'],
  ['image/gif',   'gif'],
  ['image/webp',  'webp'],
  ['image/svg+xml', 'svg'],
  ['application/pdf', 'pdf'],
]);

/**
 * buildAssetRouter(authMiddleware) → Express Router
 * authMiddleware: middleware yang memastikan req.session.studentId ada.
 */
function buildAssetRouter(authMiddleware) {
  const router = Router();

  // POST /api/assets/upload-url
  // Body: { filename: "banner.png", contentType: "image/png" }
  // Response: { uploadUrl, cdnUrl, key }
  router.post('/upload-url', authMiddleware, (req, res) => {
    const { filename, contentType } = req.body || {};
    if (!filename || !contentType) {
      return res.status(400).json({ error: 'filename dan contentType wajib diisi' });
    }
    if (!ALLOWED_TYPES.has(contentType)) {
      return res.status(400).json({ error: 'tipe file tidak diizinkan', allowed: [...ALLOWED_TYPES.keys()] });
    }
    // Sanitasi nama file: hanya alfanumerik, titik, strip, underscore
    const safeName = filename.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 128);
    const uid       = crypto.randomUUID().split('-')[0];  // 8 hex chars
    const ext       = ALLOWED_TYPES.get(contentType);
    const objectKey = `images/${uid}-${safeName}`.replace(/\.[^/.]+$/, '') + `.${ext}`;

    const uploadUrl = presignedPutUrl(objectKey, contentType, 300); // 5 menit
    const cdnUrl    = `${CDN_PUBLIC_URL}/cdn/${MINIO_BUCKET}/${objectKey}`;

    res.json({ uploadUrl, cdnUrl, key: objectKey, bucket: MINIO_BUCKET });
  });

  // GET /api/assets/list
  // Kembalikan daftar aset contoh (file yang di-seed oleh mc-init)
  router.get('/list', authMiddleware, (req, res) => {
    const baseUrl = `${CDN_PUBLIC_URL}/cdn/${MINIO_BUCKET}`;
    res.json({
      cdn_base: baseUrl,
      assets: [
        { key: 'images/banner.svg', url: `${baseUrl}/images/banner.svg`, type: 'image/svg+xml' },
        { key: 'images/logo.svg',   url: `${baseUrl}/images/logo.svg`,   type: 'image/svg+xml' },
      ],
    });
  });

  // GET /api/assets/cdn-url/:key
  // Kembalikan URL CDN untuk key tertentu (key: path dalam bucket, diencoded)
  router.get('/cdn-url/:key(*)', authMiddleware, (req, res) => {
    const key    = req.params.key;
    const cdnUrl = `${CDN_PUBLIC_URL}/cdn/${MINIO_BUCKET}/${key}`;
    res.json({ cdnUrl, key, bucket: MINIO_BUCKET });
  });

  return router;
}

module.exports = { buildAssetRouter };

