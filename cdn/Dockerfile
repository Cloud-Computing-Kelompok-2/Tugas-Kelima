# ============================================================
# Dockerfile untuk CDN Edge Node (Nginx + cache disk)
# Pertemuan 5: File Management & CDN berbasis Docker
# ============================================================
FROM nginx:1.27-alpine

# Buat direktori cache dan pastikan Nginx bisa menulis
RUN mkdir -p /var/cache/nginx/cdn \
 && chown -R nginx:nginx /var/cache/nginx

# Salin konfigurasi CDN
COPY nginx-cdn.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1/healthz || exit 1

