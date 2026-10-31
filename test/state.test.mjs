import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { Manager } from '../src/manager.mjs';
import { manager, tempDir } from './helpers.mjs';
import { normalizeProvider, MAX_PROVIDERS } from '../src/config.mjs';

test('expired per-site records are removed, and the table cannot grow without limit', () => {
  const m = manager();
  m.config.stickySeconds = 60;
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

test('while starting, the status says which step the helper is on, and the log records how long it took', async () => {
  const m = manager(0);
  m.config.port = 0; // any free port
  m.config.providers[0].enabled = true;
  const alive = net.createServer(sock => sock.destroy());
  await new Promise(r => alive.listen(0, '127.0.0.1', r));
  const entry = { key: 'k0', providerId: 'p1', providerName: 'P', label: 'proxy0', kind: 'static', hasSession: false, urlFor: () => 'http://x', host: '127.0.0.1', port: alive.address().port };
  let release;
  const gate = new Promise(r => { release = r; });
  m.loader = async () => { await gate; return [entry]; };
  const lines = [];
  m.log = (level, msg) => lines.push(msg);

  assert.equal(m.status().stage, null);
  const started = m.start();
  await new Promise(r => setTimeout(r, 30));
  assert.equal(m.status().state, 'starting');
  assert.equal(m.status().stage, 'loading', 'waiting for the provider lists');
  release();
  await started;
  assert.equal(m.status().state, 'running');
  assert.equal(m.status().stage, null, 'no step is reported once it is running');
  assert.ok(Array.isArray(m.status().bypass) && m.status().bypass.includes('localhost'), 'the helper tells the app which bypass list to use');
  assert.ok(lines.some(l => /Proxy listening .* ready in \d+\.\d s: provider lists \d+\.\d s, health check \d+\.\d s/.test(l)), lines.join(' | '));
  await m.stop();
  await new Promise(r => alive.close(r));
});

test('a failed start clears the step', async () => {
  const m = manager(0);
  m.config.providers[0].enabled = true;
  m.loader = async () => { throw new Error('The provider is down'); };
  await assert.rejects(m.start(), /./);
  assert.equal(m.status().stage, null);
  assert.equal(m.status().state, 'stopped');
});
