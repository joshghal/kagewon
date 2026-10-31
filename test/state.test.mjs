import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { Manager } from '../src/manager.mjs';
import { manager, tempDir } from './helpers.mjs';
import { normalizeProvider, MAX_PROVIDERS } from '../src/config.mjs';

test('expired per-site records are removed, and the table cannot grow without limit', () => {
  const m = manager();
  m.config.stickyMinutes = 1;
  m.pick('old.example.com');
  m.sticky.get('old.example.com').assigned -= 5 * 60_000;
  m.prune();
  assert.equal(m.sticky.has('old.example.com'), false);

  for (let i = 0; i < 5200; i++) m.pick(`site${i}.example.com`);
  assert.ok(m.sticky.size <= 5000, `held ${m.sticky.size} records`);
});

test('turning the proxy off also forgets the recent sites in the in-memory log', async () => {
  const m = manager();
  const realLog = Manager.prototype.log;
  const silent = console.log;
  console.log = () => {};
  try {
    realLog.call(m, 'warn', 'something happened', 'private-site.example');
    assert.ok(m.logs.some(l => l.msg.includes('private-site.example')));
    await m.stop();
  } finally { console.log = silent; }
  assert.equal(m.logs.some(l => l.msg.includes('private-site.example')), false);
});

test('a Tor that fails to load leaves nothing behind in the pool, but a failing Webshare keeps its old list', async () => {
  const m = manager(3);
  const tor = { id: 'tor-x', type: 'tor', name: 'Tor', enabled: true, weight: 1, socksPort: 9250, exitCountries: [] };
  const torEntry = { key: 'tor-x|tor', providerId: 'tor-x', providerName: 'Tor', label: 'Tor', kind: 'gateway', hasSession: true, urlFor: () => 'socks5h://x', host: '127.0.0.1', port: 9250 };
  m.config.providers.push(tor);
  m.runtime.set('tor-x', { entries: [torEntry], status: 'ok', error: null });
  m.rebuildIndex();
  m.sticky.set('site.example', { key: 'tor-x|tor', session: 's', assigned: Date.now(), provider: 'Tor', label: 'Tor' });
  m.loader = async () => { throw new Error('Tor could not start'); };

  await m.loadOne(tor);
  assert.deepEqual(m.runtime.get('tor-x').entries, []);
  assert.equal(m.entryByKey.has('tor-x|tor'), false, 'a dead port must not stay in the pool');
  assert.equal(m.sticky.has('site.example'), false, 'pins that pointed at it are dropped');

  const webshare = m.config.providers[0];
  await m.loadOne(webshare);
  assert.equal(m.runtime.get(webshare.id).entries.length, 3, 'a list from an API keeps working while the API is down');
});

test('there is a limit on the number of providers, and deleting a Tor provider removes its data folder', async () => {
  const m = manager(0);
  m.persist = () => {};
  m.config.providers = [];
  for (let i = 0; i < MAX_PROVIDERS; i++) await m.addProvider({ type: 'webshare', apiKey: 'k'.repeat(24) });
  await assert.rejects(m.addProvider({ type: 'webshare', apiKey: 'k'.repeat(24) }), /limit/);

  const dir = tempDir();
  const n = new Manager({ dir, config: { ...m.config, providers: [] } });
  n.persist = () => {};
  n.log = () => {};
  const added = await n.addProvider({ type: 'tor', socksPort: 9250 });
  const folder = path.join(dir, '.tor', added.id);
  fs.mkdirSync(folder, { recursive: true });
  await n.deleteProvider(added.id);
  assert.equal(fs.existsSync(folder), false);
});

test('a provider cannot be tested while the proxy is still starting', async () => {
  const m = manager();
  m.state = 'starting';
  const r = await m.test({ type: 'webshare', apiKey: 'k'.repeat(24) });
  assert.equal(r.ok, false);
  assert.match(r.error, /finish starting/);
});
