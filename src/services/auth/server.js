// Auth Service: login, logout, profil. Sesi disimpan di MySQL (dipakai bersama service lain).
const bcrypt = require('bcryptjs');
const { createLoginVerifier } = require('../../shared/login-verifier');
const { createApp, wrap, auth, start } = require('../../shared/common');

const { app, pool } = createApp('auth', { cleanSessions: true });

// Coalesce concurrent bcrypt comparisons for identical salted hashes.
// No raw passwords are stored in cache keys.
const { verify: verifyPassword } = createLoginVerifier(bcrypt.compare);

// Short-lived (10s) read-through student lookup cache to prevent 500-1000
// simultaneous VU logins from saturating the DB pool while keeping password
// reset propagation bounded.
const studentCache = new Map();
async function getStudentByNim(nim) {
  const key = String(nim);
  const hit = studentCache.get(key);
  if (hit && hit.exp > Date.now()) return hit.user;
  const [rows] = await pool.query(
    'SELECT id, nim, nama, password_hash FROM students WHERE nim = ?',
    [key],
  );
  const user = rows[0] || null;
  if (user) {
    if (studentCache.size >= 2000) studentCache.delete(studentCache.keys().next().value);
    studentCache.set(key, { user, exp: Date.now() + 10000 });
  }
  return user;
}

app.post('/api/login', wrap(async (req, res) => {
  const { nim, password } = req.body || {};
  if (!nim || !password) return res.status(400).json({ error: 'nim dan password wajib diisi' });

  const user = await getStudentByNim(nim);
  if (!user) return res.status(401).json({ error: 'NIM atau password salah' });

  if (!(await verifyPassword(password, user.password_hash))) {
    return res.status(401).json({ error: 'NIM atau password salah' });
  }
  req.session.studentId = user.id;
  res.json({ id: user.id, nim: user.nim, nama: user.nama });
}));

app.get('/api/me', auth, wrap(async (req, res) => {
  const [r] = await pool.query('SELECT id, nim, nama FROM students WHERE id = ?', [req.session.studentId]);
  res.json(r[0]);
}));

app.post('/api/logout', wrap(async (req, res) => {
  req.session.destroy(() => res.json({ status: 'bye' }));
}));

start(app, pool, 'auth');
