# ============================================================
# plot_cdn_comparison.py
# Membuat grafik visual perbandingan performa Sebelum vs Sesudah CDN
# ============================================================

import json
import matplotlib.pyplot as plt
import numpy as np

# Load data
with open("loadtest/results/before_cdn_summary.json", "r") as f:
    before = json.load(f)["metrics"]

with open("loadtest/results/with_cdn_summary.json", "r") as f:
    after = json.load(f)["metrics"]

plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))

# 1. Bar Chart: Throughput (Req/s)
categories = ['Sebelum CDN\n(Origin MinIO)', 'Sesudah CDN\n(Nginx Edge Cache)']
rps = [before['reqs_rate_rps'], after['reqs_rate_rps']]
colors_rps = ['#e63946', '#2a9d8f']

bars1 = ax1.bar(categories, rps, color=colors_rps, width=0.45, edgecolor='black', linewidth=1)
ax1.set_title('Throughput Permintaan (Req/s)\n[Semakin tinggi semakin baik]', fontsize=12, fontweight='bold', pad=12)
ax1.set_ylabel('Requests per Second', fontsize=11)
ax1.set_ylim(0, max(rps) * 1.25)
ax1.grid(axis='y', linestyle='--', alpha=0.7)

for bar in bars1:
    yval = bar.get_height()
    ax1.text(bar.get_x() + bar.get_width()/2.0, yval + (max(rps)*0.02), f'{yval:.1f} rps', ha='center', va='bottom', fontsize=11, fontweight='bold')

diff_rps = ((after['reqs_rate_rps'] - before['reqs_rate_rps']) / before['reqs_rate_rps']) * 100
ax1.text(0.5, 0.88, f'Peningkatan: +{diff_rps:.1f}% ({after["reqs_rate_rps"]/before["reqs_rate_rps"]:.1f}x)', 
         transform=ax1.transAxes, ha='center', fontsize=11, fontweight='bold', color='#1d3557',
         bbox=dict(boxstyle='round,pad=0.5', facecolor='#e2f1f4', edgecolor='#0f5c6e', linewidth=1.5))

# 2. Bar Chart: Latency Comparison (Average, p50, p95)
metrics = ['Rata-rata (Avg)', 'Median (p50)', '95th Persentil (p95)']
x = np.arange(len(metrics))
width = 0.35

lat_before = [before['latency_avg_ms'], before['latency_p50_ms'], before['latency_p95_ms']]
lat_after = [after['latency_avg_ms'], after['latency_p50_ms'], after['latency_p95_ms']]

bars2_1 = ax2.bar(x - width/2, lat_before, width, label='Sebelum CDN', color='#e63946', edgecolor='black', linewidth=1)
bars2_2 = ax2.bar(x + width/2, lat_after, width, label='Sesudah CDN', color='#2a9d8f', edgecolor='black', linewidth=1)

ax2.set_title('Latensi Respon (ms)\n[Semakin rendah semakin baik]', fontsize=12, fontweight='bold', pad=12)
ax2.set_ylabel('Latensi (milidetik)', fontsize=11)
ax2.set_xticks(x)
ax2.set_xticklabels(metrics, fontsize=10)
ax2.set_ylim(0, max(lat_before) * 1.2)
ax2.legend(frameon=True, facecolor='white', framealpha=0.9)
ax2.grid(axis='y', linestyle='--', alpha=0.7)

for bar in bars2_1:
    y = bar.get_height()
    ax2.text(bar.get_x() + bar.get_width()/2.0, y + (max(lat_before)*0.015), f'{y:.0f} ms', ha='center', va='bottom', fontsize=9, fontweight='bold', color='#b71c1c')

for bar in bars2_2:
    y = bar.get_height()
    ax2.text(bar.get_x() + bar.get_width()/2.0, y + (max(lat_before)*0.015), f'{y:.0f} ms', ha='center', va='bottom', fontsize=9, fontweight='bold', color='#004d40')

diff_p95 = ((before['latency_p95_ms'] - after['latency_p95_ms']) / before['latency_p95_ms']) * 100
ax2.text(0.5, 0.88, f'Penurunan Latensi p95: -{diff_p95:.1f}% ({before["latency_p95_ms"]/after["latency_p95_ms"]:.1f}x lebih cepat)', 
         transform=ax2.transAxes, ha='center', fontsize=11, fontweight='bold', color='#1d3557',
         bbox=dict(boxstyle='round,pad=0.5', facecolor='#e2f1f4', edgecolor='#0f5c6e', linewidth=1.5))

plt.suptitle('Evaluasi Kinerja CDN Lokal Berbasis Docker (Pertemuan 5)\nPortal Ujian CBT - Kelompok 2', fontsize=14, fontweight='bold', y=1.02)
plt.tight_layout()
output_path = "loadtest/results/cdn_performance_comparison.png"
plt.savefig(output_path, dpi=300, bbox_inches='tight')
print(f"Grafik perbandingan berhasil disimpan ke {output_path}")

