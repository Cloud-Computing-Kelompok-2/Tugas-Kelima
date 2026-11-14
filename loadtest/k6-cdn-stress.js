// ============================================================
// k6-cdn-stress.js  –  Stress Test Perbandingan CDN vs Origin
// Pertemuan 5: File Management & CDN berbasis Docker
// ============================================================
// Menguji dua skenario untuk dibandingkan:
//   Skenario A ("before_cdn" / "origin"):
//     Request langsung ke Origin Storage (MinIO port 9000 / Gateway tanpa CDN)
//   Skenario B ("with_cdn" / "cdn"):
//     Request ke CDN Edge Node (Nginx Cache port 8080 / Gateway /static/)
// ============================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const TARGET_URL = __ENV.TARGET_URL || 'http://localhost:8080/cdn/cbt-assets/images/banner.svg';
const SCENARIO_NAME = __ENV.SCENARIO_NAME || 'with_cdn'; // 'before_cdn' atau 'with_cdn'

// Duration & VU configuration
const VUS = +(__ENV.VUS || 100);
const DURATION = __ENV.DURATION || '30s';

// Custom metrics
const latency = new Trend('asset_latency_ms', true);
const cacheHit = new Rate('cdn_cache_hit_rate');
const successRate = new Rate('success_rate');
const bytesTransferred = new Counter('total_bytes_transferred');

export const options = {
  scenarios: {
    asset_stress: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    'asset_latency_ms': ['p(95)<300'],
    'success_rate': ['rate>0.99'],
  },
};

export default function () {
  const start = Date.now();
  const res = http.get(TARGET_URL, {
    tags: { scenario: SCENARIO_NAME },
    timeout: '10s',
  });
  const dur = Date.now() - start;
  latency.add(dur);

  const ok = check(res, {
    'status 200': (r) => r.status === 200,
  });
  successRate.add(ok);

  if (res.body) {
    bytesTransferred.add(res.body.length);
  }

  const cacheHeader = res.headers['X-Cache-Status'] || res.headers['x-cache-status'] || '';
  cacheHit.add(cacheHeader === 'HIT');

  // Small delay to simulate browser concurrent resource fetch
  sleep(0.05);
}

export function handleSummary(data) {
  const getMetric = (name, key, def = 0) => {
    return (data.metrics[name] && data.metrics[name].values && data.metrics[name].values[key] !== undefined)
      ? data.metrics[name].values[key]
      : def;
  };

  const reqsTotal = getMetric('http_reqs', 'count', 0);
  const reqsRate = getMetric('http_reqs', 'rate', 0);
  const latAvg = getMetric('asset_latency_ms', 'avg', 0);
  const latMed = getMetric('asset_latency_ms', 'med', 0);
  const latP90 = getMetric('asset_latency_ms', 'p(90)', 0);
  const latP95 = getMetric('asset_latency_ms', 'p(95)', 0);
  const latP99 = getMetric('asset_latency_ms', 'p(99)', 0);
  const latMax = getMetric('asset_latency_ms', 'max', 0);
  const succRate = getMetric('success_rate', 'rate', 0);
  const cacheHitR = getMetric('cdn_cache_hit_rate', 'rate', 0);
  const dataRecv = getMetric('data_received', 'count', 0);

  const out = {
    scenario: SCENARIO_NAME,
    target_url: TARGET_URL,
    vus: VUS,
    duration: DURATION,
    metrics: {
      reqs_total: reqsTotal,
      reqs_rate_rps: reqsRate,
      latency_avg_ms: latAvg,
      latency_p50_ms: latMed,
      latency_p90_ms: latP90,
      latency_p95_ms: latP95,
      latency_p99_ms: latP99,
      latency_max_ms: latMax,
      success_rate: succRate,
      cache_hit_rate: cacheHitR,
      bytes_received: dataRecv,
    },
  };

  const filename = `loadtest/results/${SCENARIO_NAME}_summary.json`;
  const resultObj = {};
  resultObj[filename] = JSON.stringify(out, null, 2);
  resultObj.stdout = `\n=========================================\n` +
    `HASIL STRESS TEST: ${SCENARIO_NAME.toUpperCase()}\n` +
    `Target: ${TARGET_URL}\n` +
    `Requests: ${reqsTotal} (${reqsRate.toFixed(1)} req/s)\n` +
    `Latency avg: ${latAvg.toFixed(2)} ms | p50: ${latMed.toFixed(2)} ms | p95: ${latP95.toFixed(2)} ms | p99: ${latP99.toFixed(2)} ms\n` +
    `Success Rate: ${(succRate * 100).toFixed(2)}%\n` +
    `Cache Hit Rate: ${(cacheHitR * 100).toFixed(2)}%\n` +
    `=========================================\n`;
  return resultObj;
}
