import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Manager } from '../src/manager.mjs';
import { DEFAULT_SETTINGS } from '../src/config.mjs';

/** A Manager with a fake pool, for testing which proxy gets picked without any network. */
export function manager(entryCount = 20, kind = 'static') {
  const provider = { id: 'p1', type: 'webshare', name: 'P', enabled: true, weight: 1 };
  // a private folder, so a test can never touch the real config.json
  const dir = tempDir();
  const m = new Manager({ dir, config: { ...DEFAULT_SETTINGS, providers: [provider] } });
  const entries = Array.from({ length: entryCount }, (_, i) => ({
    key: `k${i}`, providerId: 'p1', providerName: 'P', label: `proxy${i}`, kind,
    hasSession: kind === 'gateway', newSession: () => 'sess', urlFor: () => 'http://x',
  }));
  m.runtime.set('p1', { entries, status: 'ok', error: null });
  m.entryByKey = new Map(entries.map(e => [e.key, e]));
  m.log = () => {}; // keep the test output quiet
  return m;
}

const made = [];
process.on('exit', () => { for (const d of made) try { fs.rmSync(d, { recursive: true, force: true }); } catch {} });
export const tempDir = () => { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'proxy-test-')); made.push(d); return d; };
