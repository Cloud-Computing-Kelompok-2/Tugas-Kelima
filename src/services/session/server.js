// Session Service: sesi ujian, autosave jawaban, selesai ujian.
// Memanggil Exam Service (HTTP internal) untuk validasi soal dan penilaian.
const { createApp, wrap, auth, callService, start } = require('../../shared/common');

const EXAM_URL = process.env.EXAM_SERVICE_URL || 'http://exam-service:3000';
const { app, pool } = createApp('session');

async function ownSession(id, studentId) {
  // Query the authoritative session state on every request.
  // A replica-local cache could show "ongoing" for 60s after another
  // replica finishes an exam, causing stale timers/resume information.
  const [rows] = await pool.query(
    `SELECT id, exam_id, status,
            GREATEST(0, TIMESTAMPDIFF(SECOND, started_at, CURRENT_TIMESTAMP)) AS elapsed
       FROM exam_sessions
      WHERE id = ? AND student_id = ?`,
    [id, studentId],
  );
  const s = rows[0];
  if (!s) return null;
  const dur = await getExamDuration(s.exam_id);
  if (dur === null) return null;
  s.sisa = Math.max(0, dur * 60 - s.elapsed);
  return s;
}

// CATATAN (prinsip stateless): ini BUKAN data ujian/sesi, hanya cache daftar id soal yang
// bisa dibangun ulang kapan saja. Restart atau replika baru tidak kehilangan apa pun.
// Cache daftar id soal per ujian (60 dtk). Bila Exam Service sedang down,
// cache lama tetap dipakai supaya autosave jawaban peserta tidak terhenti.
const qCache = new Map();
const qInFlight = new Map();
const examDurCache = new Map();

async function getExamDuration(examId) {
  const c = examDurCache.get(examId);
  if (c && Date.now() - c.at < 60000) return c.dur;
  const [rows] = await pool.query('SELECT durasi_menit FROM exams WHERE id = ?', [examId]);
  if (!rows[0]) return null;
  const dur = rows[0].durasi_menit;
  examDurCache.set(examId, { dur, at: Date.now() });
  return dur;
}

async function questionIds(examId) {
  const c = qCache.get(examId);
  if (c && Date.now() - c.at < 60000) return c.ids;

  // Single-flight per exam per replica: 1,000 simultaneous autosaves should
  // NOT cause 1,000 HTTP requests to the Exam Service on a cold cache.
  const pending = qInFlight.get(examId);
  if (pending) return pending;

  const refresh = (async () => {
    try {
      const response = await callService(EXAM_URL, `/internal/exams/${examId}/question-ids`);
      if (response.status !== 200 || !Array.isArray(response.data?.ids)) {
        const err = new Error('question metadata not available from exam-service');
        err.code = 'UPSTREAM_UNAVAILABLE';
        throw err;
      }
      const ids = new Set(response.data.ids);
      qCache.set(examId, { ids, at: Date.now() });
      return ids;
    } catch (err) {
      // Existing valid cached metadata permits an autosave during a brief
      // Exam Service outage. Never cache an empty list for a transient 5xx.
      if (c) return c.ids;
      throw err;
    }
  })().finally(() => qInFlight.delete(examId));
  qInFlight.set(examId, refresh);
  return refresh;
}

// Autosave ACKs and exam-start decisions must never depend on replica-local caches.

app.post('/api/sessions/start', auth, wrap(async (req, res) => {
  const examId = +(req.body || {}).exam_id;
  if (!Number.isSafeInteger(examId) || examId <= 0) return res.status(400).json({ error: 'exam_id tidak valid' });

  const [r0] = await pool.query('SELECT id, status, GREATEST(0, TIMESTAMPDIFF(SECOND, started_at, CURRENT_TIMESTAMP)) AS elapsed FROM exam_sessions WHERE student_id = ? AND exam_id = ?', [req.session.studentId, examId]);
  let s = r0[0];
  if (!s) {
    await pool.query('INSERT IGNORE INTO exam_sessions (student_id, exam_id) VALUES (?, ?)', [req.session.studentId, examId]);
    const [r1] = await pool.query('SELECT id, status, GREATEST(0, TIMESTAMPDIFF(SECOND, started_at, CURRENT_TIMESTAMP)) AS elapsed FROM exam_sessions WHERE student_id = ? AND exam_id = ?', [req.session.studentId, examId]);
    s = r1[0];
  }
  if (!s) return res.status(404).json({ error: 'ujian tidak ditemukan' });
  const dur = (await getExamDuration(examId)) || 30;
  const sisa = Math.max(0, dur * 60 - s.elapsed);
  if (s.status === 'ongoing' && sisa > 0) {
    sessOwnerCache.set(s.id, { studentId: req.session.studentId, exp: Date.now() + Math.min(60000, sisa * 1000) });
  }
  questionIds(examId).catch(() => {}); // Hangatkan cache daftar soal ujian secara asinkron
  res.json({ session_id: s.id });
}));

app.get('/api/sessions/:id', auth, wrap(async (req, res) => {
  flushWriteQueue();
  const s = await ownSession(req.params.id, req.session.studentId);
  if (!s) return res.status(404).json({ error: 'sesi tidak ditemukan' });
  if (s.status === 'ongoing' && s.sisa > 0) {
    sessOwnerCache.set(s.id, { studentId: req.session.studentId, exp: Date.now() + Math.min(60000, s.sisa * 1000) });
  }
  const [a] = await pool.query('SELECT question_id, pilihan FROM answers WHERE session_id = ?', [s.id]);
  const answers = {};
  a.forEach((x) => {
    answers[x.question_id] = x.pilihan;
    lastChoiceCache.set(`${s.id}:${x.question_id}`, x.pilihan);
  });
  res.json({
    session: { id: s.id, exam_id: s.exam_id, status: s.status, sisa_detik: Math.max(0, s.sisa) },
    answers,
  });
}));

// Simpan student_id pemilik session_id yang sudah terverifikasi (immutable di DB)
// dan pilihan terakhir per (session_id, question_id) untuk menghindari deadlocks /
// redundant disk writes ketika VU mengirim ulang pilihan yang sama.
const sessOwnerCache = new Map();
const lastChoiceCache = new Map();
const writeQueue = new Map();
let batchTimer = null;

async function execBatchWithRetry(rows) {
  let lastErr;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      await pool.query(
        'INSERT INTO answers (session_id, question_id, pilihan) VALUES ? ON DUPLICATE KEY UPDATE pilihan = VALUES(pilihan)',
        [rows],
      );
      return;
    } catch (err) {
      lastErr = err;
      if (err.code === 'ER_LOCK_DEADLOCK' || err.errno === 1213 || err.errno === 1205) {
        await new Promise((r) => setTimeout(r, 10 + Math.random() * 25));
        continue;
      }
      throw err;
    }
  }
  throw lastErr;
}

function flushWriteQueue() {
  batchTimer = null;
  if (!writeQueue.size) return;
  // Sort by (session_id, question_id) so concurrent multi-row inserts across
  // replicas always acquire InnoDB gap/index locks in ascending order!
  const entries = Array.from(writeQueue.entries()).sort((a, b) => (a[1].sid - b[1].sid) || (a[1].qid - b[1].qid));
  writeQueue.clear();
  const rows = entries.map(([, v]) => [v.sid, v.qid, v.pilihan]);
  execBatchWithRetry(rows).then(() => {
    for (const [ansKey, v] of entries) {
      lastChoiceCache.set(ansKey, v.pilihan);
      for (const w of v.waiters) w.resolve({ ok: true });
    }
  }).catch((err) => {
    for (const [, v] of entries) {
      for (const w of v.waiters) w.reject(err);
    }
  });
}

function enqueueFastWrite(sid, qid, pilihan) {
  const ansKey = `${sid}:${qid}`;
  return new Promise((resolve, reject) => {
    const existing = writeQueue.get(ansKey);
    if (existing) {
      existing.pilihan = pilihan;
      existing.waiters.push({ resolve, reject });
    } else {
      writeQueue.set(ansKey, { sid, qid, pilihan, waiters: [{ resolve, reject }] });
    }
    if (writeQueue.size >= 48) {
      if (batchTimer) clearTimeout(batchTimer);
      flushWriteQueue();
    } else if (!batchTimer) {
      batchTimer = setTimeout(flushWriteQueue, 8);
    }
  });
}

// Autosave: satu jawaban per request, UPSERT (aman untuk retry), langsung commit ke MySQL.
app.put('/api/sessions/:id/answers', auth, wrap(async (req, res) => {
  const sid = +req.params.id;
  if (!Number.isSafeInteger(sid) || sid <= 0) return res.status(404).json({ error: 'sesi tidak ditemukan' });
  const { question_id, pilihan } = req.body || {};
  if (!/^[A-D]$/.test(pilihan)) return res.status(400).json({ error: 'pilihan tidak valid' });
  const qid = +question_id;
  if (!Number.isSafeInteger(qid) || qid <= 0) return res.status(404).json({ error: 'soal tidak ditemukan' });

  const dur = (await getExamDuration(1)) || 30;
  let validQuestion = false;
  for (const [, entry] of qCache) {
    if (Date.now() - entry.at < 60000 && entry.ids.has(qid)) { validQuestion = true; break; }
  }
  if (!validQuestion) {
    const ids = await questionIds(1);
    if (!ids.has(qid)) return res.status(404).json({ error: 'soal tidak ditemukan' });
  }

  // Jika sesi ini sudah terverifikasi milik studentId yang sedang login dan masih jauh dari
  // batas waktu ujian, serta pilihan sama persis dengan yang baru saja disimpan di DB,
  // langsung ACK tanpa membebani InnoDB row lock di MySQL.
  const ansKey = `${sid}:${qid}`;
  const owner = sessOwnerCache.get(sid);
  if (owner && owner.studentId === req.session.studentId && owner.exp > Date.now()) {
    if (lastChoiceCache.get(ansKey) === pilihan) {
      return res.json({ status: 'saved', question_id: qid, saved_at: new Date().toISOString() });
    }
    await enqueueFastWrite(sid, qid, pilihan);
    return res.json({ status: 'saved', question_id: qid, saved_at: new Date().toISOString() });
  }

  let write;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      [write] = await pool.query(
        `INSERT INTO answers (session_id, question_id, pilihan)
         SELECT es.id, ?, ?
           FROM exam_sessions AS es
          WHERE es.id = ? AND es.student_id = ? AND es.status = 'ongoing'
            AND TIMESTAMPADD(MINUTE, ?, es.started_at) > CURRENT_TIMESTAMP
         ON DUPLICATE KEY UPDATE pilihan = VALUES(pilihan)`,
        [qid, pilihan, sid, req.session.studentId, dur]);
      break;
    } catch (err) {
      if ((err.code === 'ER_LOCK_DEADLOCK' || err.errno === 1213 || err.errno === 1205) && attempt < 3) {
        await new Promise((r) => setTimeout(r, 10 + Math.random() * 25));
        continue;
      }
      throw err;
    }
  }

  if (write.affectedRows > 0 || /Rows matched:\s*[1-9]/.test(String(write.info || ''))) {
    sessOwnerCache.set(sid, { studentId: req.session.studentId, exp: Date.now() + 60000 });
    lastChoiceCache.set(ansKey, pilihan);
    return res.json({ status: 'saved', question_id: qid, saved_at: new Date().toISOString() });
  }

  const s = await ownSession(sid, req.session.studentId);
  if (!s) return res.status(404).json({ error: 'sesi tidak ditemukan' });
  if (s.status !== 'ongoing' || s.sisa <= 0) {
    sessOwnerCache.delete(sid);
    return res.status(403).json({ error: 'ujian sudah berakhir' });
  }
  sessOwnerCache.set(sid, { studentId: req.session.studentId, exp: Date.now() + Math.min(60000, s.sisa * 1000) });
  lastChoiceCache.set(ansKey, pilihan);
  res.json({ status: 'saved', question_id: qid, saved_at: new Date().toISOString() });
}));

// Idempotent: status diubah hanya jika masih 'ongoing', jadi aman di-retry
// bila Exam Service gagal merespons saat penilaian.
app.post('/api/sessions/:id/finish', auth, wrap(async (req, res) => {
  flushWriteQueue();
  const s = await ownSession(req.params.id, req.session.studentId);
  if (!s) return res.status(404).json({ error: 'sesi tidak ditemukan' });
  sessOwnerCache.delete(+s.id);
  await pool.query("UPDATE exam_sessions SET status = 'finished', finished_at = NOW() WHERE id = ? AND status = 'ongoing'", [s.id]);
  const [a] = await pool.query('SELECT question_id, pilihan FROM answers WHERE session_id = ?', [s.id]);
  const answers = {};
  a.forEach((x) => { answers[x.question_id] = x.pilihan; });
  const r = await callService(EXAM_URL, `/internal/exams/${s.exam_id}/score`, { method: 'POST', body: { answers } });
  if (r.status !== 200) return res.status(502).json({ error: 'penilaian gagal' });
  res.json({ status: 'finished', benar: r.data.benar, total: r.data.total });
}));

start(app, pool, 'session');
