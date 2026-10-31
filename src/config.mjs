import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const ROTATIONS = ['sticky', 'random'];
export const TYPES = ['webshare', 'tor'];
export const SECRET_FIELDS = ['apiKey'];

export const DEFAULT_SETTINGS = {
  rotation: 'sticky',
  stickyMinutes: 10,
  port: 8888,
  refreshMinutes: 15,
  verbose: false,
  rotateOpenConnections: true,
  killSwitch: false, // true: if the helper stops, leave the Mac's proxy on so nothing leaks (the internet stops until it is back)
};

const MASK = '••••';
const DEFAULT_NAMES = { webshare: 'Webshare', tor: 'Tor' };
const ID_RE = /^[a-z0-9-]{1,40}$/;
const KEEP_BROKEN_BACKUPS = 3;

const str = v => (typeof v === 'string' ? v.trim() : '');
const clampInt = (v, min, max, fallback) => {
  const n = Math.round(Number(v));
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
};
const countries = v =>
  (Array.isArray(v) ? v : str(v).split(','))
    .map(s => String(s).trim().toUpperCase())
    .filter(s => /^[A-Z]{2}$/.test(s));

export const configPath = dir => path.join(dir, 'config.json');

/** Writes through a private temporary file and renames it, so the real file is never half-written or world-readable. */
export function saveConfig(dir, cfg) {
  const file = configPath(dir);
  const tmp = `${file}.${process.pid}.tmp`;
  fs.rmSync(tmp, { force: true }); // a stale file from a crash could have looser permissions
  let fd;
  try {
    fd = fs.openSync(tmp, 'wx', 0o600);
    fs.writeSync(fd, JSON.stringify(cfg, null, 2) + '\n');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(tmp, file);
  } catch (err) {
    if (fd !== undefined) try { fs.closeSync(fd); } catch {}
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

/**
 * Validates settings. Only the keys that are present are checked and returned, so it works for partial updates.
 * Throws Error with a readable message.
 */
export function normalizeSettings(input) {
  const out = {};
  if (input.rotation !== undefined) {
    if (!ROTATIONS.includes(input.rotation)) throw new Error('Rotation must be "sticky" or "random"');
    out.rotation = input.rotation;
  }
  const intIn = (key, lo, hi, message) => {
    if (input[key] === undefined) return;
    const n = Number(input[key]);
    if (!Number.isInteger(n) || n < lo || n > hi) throw new Error(message);
    out[key] = n;
  };
  intIn('stickyMinutes', 1, 1440, 'Sticky time must be 1 to 1440 minutes');
  intIn('port', 1024, 65535, 'The proxy port must be between 1024 and 65535');
  intIn('refreshMinutes', 1, 1440, 'Refresh time must be 1 to 1440 minutes');
  for (const key of ['verbose', 'rotateOpenConnections', 'killSwitch']) {
    if (input[key] !== undefined) out[key] = input[key] === true;
  }
  return out;
}

/** Keeps the providers that are valid and drops the rest, so a hand-edited or damaged file cannot inject anything. */
function sanitizeStored(providers) {
  const seen = new Set();
  const out = [];
  for (const raw of providers) {
    try {
      const p = normalizeProvider(raw && typeof raw === 'object' ? raw : {});
      if (typeof raw.id === 'string' && ID_RE.test(raw.id) && raw.id !== 'test' && !seen.has(raw.id)) p.id = raw.id; // 'test' is reserved for unsaved tests
      seen.add(p.id);
      out.push(p);
    } catch (err) {
      console.warn(`Ignored an invalid provider in config.json (${err.message})`);
    }
  }
  return out;
}

function pruneBackups(dir) {
  const old = fs.readdirSync(dir).filter(n => n.startsWith('config.json.broken-')).sort();
  for (const name of old.slice(0, Math.max(0, old.length - KEEP_BROKEN_BACKUPS))) fs.rmSync(path.join(dir, name), { force: true });
}

/** Loads config.json, or creates a default one. There is no .env file: everything is set in the app. */
export function loadConfig(dir) {
  const file = configPath(dir);
  if (fs.existsSync(file)) {
    try {
      const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (cfg && Array.isArray(cfg.providers)) {
        const safe = {};
        for (const [k, v] of Object.entries(cfg)) {
          if (k in DEFAULT_SETTINGS) {
            try { Object.assign(safe, normalizeSettings({ [k]: v })); } catch {}
          }
        }
        const providers = sanitizeStored(cfg.providers);
        if (providers.length !== cfg.providers.length) {
          // Something was dropped, and the next save would erase it for good: keep a private copy of the file.
          const backup = `${file}.broken-${Date.now()}`;
          fs.copyFileSync(file, backup);
          fs.chmodSync(backup, 0o600);
          pruneBackups(dir);
          console.warn(`Some providers in config.json were invalid and were ignored; the original is kept as ${path.basename(backup)}`);
        }
        return { version: 1, ...DEFAULT_SETTINGS, ...safe, providers };
      }
    } catch {}
    const backup = `${file}.broken-${Date.now()}`;
    fs.renameSync(file, backup); // never overwrite a file we could not read
    pruneBackups(dir);
    console.warn(`config.json was unreadable; moved it to ${path.basename(backup)}`);
  }
  const cfg = { version: 1, ...DEFAULT_SETTINGS, providers: [] };
  saveConfig(dir, cfg);
  return cfg;
}

/** Validates user input and returns a clean provider object. Throws Error with a readable message. */
export function normalizeProvider(input, existing = null) {
  const type = input.type ?? existing?.type;
  if (!TYPES.includes(type)) throw new Error('Unknown provider type');
  if (existing && existing.type !== type) throw new Error('A provider cannot change its type');

  const merged = { ...existing, ...input };
  // An empty or masked secret on edit means "keep the stored one".
  for (const f of SECRET_FIELDS) {
    const v = input[f];
    if (existing && (v === undefined || v === '' || (typeof v === 'string' && v.startsWith(MASK)))) merged[f] = existing[f];
  }

  const out = {
    id: existing?.id ?? `${type}-${crypto.randomBytes(3).toString('hex')}`, // never taken from user input
    type,
    name: str(merged.name).slice(0, 60) || DEFAULT_NAMES[type],
    enabled: merged.enabled !== false,
    weight: clampInt(merged.weight, 1, 10, 1),
  };

  if (type === 'webshare') {
    out.apiKey = str(merged.apiKey);
    if (!out.apiKey) throw new Error('The API key is required');
    out.countries = countries(merged.countries);
  } else {
    out.socksPort = clampInt(merged.socksPort, 0, 65535, 9250);
    if (out.socksPort < 1024) throw new Error('Enter a local port between 1024 and 65535 (default 9250)');
    out.exitCountries = countries(merged.exitCountries);
  }
  return out;
}

// Only the end of a long key is shown. A short secret would give away too much of itself.
const mask = v => (v ? (v.length >= 20 ? MASK + v.slice(-4) : MASK) : '');

/** A copy that is safe to send to the UI: secrets are replaced by a short hint. */
export function maskProvider(p) {
  const out = { ...p };
  for (const f of SECRET_FIELDS) if (f in out) out[f] = mask(out[f]);
  return out;
}
