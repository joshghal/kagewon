import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { manager } from './helpers.mjs';
import { normalizeProvider } from '../src/config.mjs';

const freeClosedPort = () => new Promise(resolve => {
  const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
});

test('a failing provider is retried later and later, not every minute', async () => {
  const m = manager(0);
  m.runtime.clear();
  const port = await freeClosedPort(); // nothing listens here, so loading fails
  m.env = { WEBSHARE_API_BASE: `http://127.0.0.1:${port}` };
  const p = normalizeProvider({ type: 'webshare', apiKey: 'k'.repeat(24) });
  m.config.providers = [p];

  const gaps = [];
  for (let i = 0; i < 5; i++) {
    const before = Date.now();
    await m.loadOne(p);
    gaps.push(Math.round((m.runtime.get(p.id).retryAt - before) / 60_000));
  }
  assert.deepEqual(gaps, [1, 2, 4, 8, 15], 'minutes until the next attempt');
  assert.equal(m.runtime.get(p.id).status, 'error');
});

test('the health tick retries only the providers that are empty and due, and leaves working ones alone', () => {
  const m = manager(3);
  const working = m.config.providers[0];
  const broken = { id: 'p2', type: 'webshare', name: 'B', enabled: true, weight: 1 };
  m.config.providers.push(broken);
  m.runtime.set('p2', { entries: [], status: 'error', error: 'x', retryAt: Date.now() + 60_000 });

  const loaded = [];
  m.loadOne = async p => { loaded.push(p.id); };
  m.checkHealth = async () => {};
  m.healthTick();
  assert.deepEqual(loaded, [], 'not due yet, and the working provider is never reloaded');

  m.runtime.get('p2').retryAt = Date.now() - 1; // now it is due
  m.healthTick();
  assert.deepEqual(loaded, ['p2']);
  assert.ok(!loaded.includes(working.id));
});
