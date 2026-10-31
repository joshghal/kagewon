import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { Server, RequestError } from 'proxy-chain';
import { Manager } from '../src/manager.mjs';
import { DEFAULT_SETTINGS } from '../src/config.mjs';
import { disableOurs } from '../src/systemproxy.mjs';
import { findTor } from '../src/tor.mjs';
import { manager, tempDir } from './helpers.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const freePort = () => new Promise(resolve => {
  const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
});

/** A Manager whose only proxy is a reachable local port, with a fake provider loader. */
async function runnable(extra = {}) {
  const alive = net.createServer(sock => sock.destroy());
  await new Promise(r => alive.listen(0, '127.0.0.1', r));
  const entry = { key: 'k0', providerId: 'p1', providerName: 'P', label: 'proxy0', kind: 'static', hasSession: false, urlFor: () => 'http://x', host: '127.0.0.1', port: alive.address().port };
  const m = new Manager({
    dir: tempDir(),
    config: { ...DEFAULT_SETTINGS, port: await freePort(), providers: [{ id: 'p1', type: 'webshare', name: 'P', enabled: true, weight: 1, apiKey: 'k'.repeat(24), countries: [] }] },
  });
  m.log = () => {};
  m.loader = async () => [entry];
  Object.assign(m, extra);
  return { m, entry, close: () => new Promise(r => alive.close(r)) };
}

// ---- plain HTTP requests: the target is named twice, and both must agree ----------------------------------------------

const rawRequest = (port, text) => new Promise(resolve => {
  const sock = net.connect(port, '127.0.0.1', () => sock.write(text));
  let data = '';
  sock.on('data', d => { data += d; if (/\r\n\r\n/.test(data)) { sock.destroy(); } });
  sock.on('close', () => resolve(data.split('\r\n')[0]));
  sock.on('error', () => resolve(data.split('\r\n')[0] || 'ERROR'));
  setTimeout(() => sock.destroy(), 3000);
});

test('plain HTTP requests with an ambiguous or mismatching target are refused before any provider sees them', async () => {
  const asked = [];
  const upstream = new Server({
    host: '127.0.0.1', port: 0,
    prepareRequestFunction: ({ hostname }) => { asked.push(hostname); throw new RequestError('stop', 502); },
  });
  await upstream.listen();
  const { m, entry, close } = await runnable();
  m.loader = async () => [{ ...entry, urlFor: () => `http://u:p@127.0.0.1:${upstream.port}` }];
  try {
    await m.start();
    const port = m.listenPort;
    const bad = [
      'GET http://example.com?@127.0.0.1/ HTTP/1.1\r\nHost: example.com\r\n\r\n',
      'GET http://example.com@127.0.0.1/ HTTP/1.1\r\nHost: example.com\r\n\r\n',
      'GET http://example.com%2e/ HTTP/1.1\r\nHost: example.com\r\n\r\n',
      'GET http://example.com/ HTTP/1.1\r\nHost: 127.0.0.1:8889\r\n\r\n',
      'GET http://example.com/ HTTP/1.1\r\nHost: other.example\r\n\r\n',
    ];
    for (const text of bad) assert.match(await rawRequest(port, text), / 400 /, text.split('\r\n')[0]);
    assert.deepEqual(asked, [], 'none of them reached the provider');

    // number-like hosts: the library would read 010.0.0.1 as 8.0.0.1 (octal) before the filter sees it
    for (const host of ['010.0.0.1', '0177.0.0.1', '0x7f.1', '0x08.0x08.0x08.0x08', '134744072', '127.1', '[::1]', '[2002:7f00:1::]', 'fritz.box', 'nas']) {
      assert.match(await rawRequest(port, `GET http://${host}/ HTTP/1.1\r\nHost: ${host}\r\n\r\n`), / 403 /, host);
    }
    assert.deepEqual(asked, [], 'none of them reached the provider');

    await rawRequest(port, 'GET http://example.com/ok HTTP/1.1\r\nHost: example.com\r\n\r\n');
    await rawRequest(port, 'GET http://Example.COM:80/ok HTTP/1.1\r\nHost: example.com\r\n\r\n');
    assert.ok(asked.includes('example.com'), 'a normal request is forwarded');
  } finally {
    await m.stop();
    await upstream.close(true);
    await close();
  }
});

test('local and private addresses that were refused show up in the Activity log, but never in the console log', async () => {
  const { m, close } = await runnable();
  const real = new Manager({ dir: tempDir(), config: m.config });
  const consoleLines = [];
  const original = [console.log, console.warn];
  console.log = console.warn = (...a) => consoleLines.push(a.join(' '));
  try {
    real.loader = m.loader;
    await real.start();
    const port = real.listenPort;
    const code = await new Promise((resolve, reject) => {
      const req = http.request({ method: 'CONNECT', host: '127.0.0.1', port, path: '192.168.7.7:80' });
      req.on('connect', res => resolve(res.statusCode));
      req.on('error', reject);
      req.end();
    });
    assert.equal(code, 403);
    assert.ok(real.logs.some(l => /not sent through the proxy/.test(l.msg) && l.msg.includes('192.168.7.7')), 'the Activity log says it was refused');
    assert.equal(consoleLines.some(l => l.includes('192.168.7.7')), false, 'the console log (saved to disk) does not name it');
  } finally {
    [console.log, console.warn] = original;
    await real.stop();
    await close();
  }
});

// ---- start and stop ---------------------------------------------------------------------------------------------------

test('stopping while the proxy is still starting leaves it stopped, not half running', async () => {
  const { m, entry, close } = await runnable();
  let release;
  const gate = new Promise(r => { release = r; });
  m.loader = async () => { await gate; return [entry]; };
  const started = m.start();
  const settled = started.then(() => 'started', err => err.message);
  await new Promise(r => setTimeout(r, 30));
  await m.stop();
  release();
  assert.match(await settled, /stopped while it was starting/);
  assert.equal(m.state, 'stopped');
  assert.equal(m.server, null);
  assert.equal(m.timers.length, 0);
  assert.equal(m.listenPort, null);
  assert.equal(m.status().stage, null);
  await close();
});

test('the proxy port may be held by someone letting go (the app with the kill switch); the start waits for it', async () => {
  const { m, close } = await runnable();
  const holder = net.createServer(s => s.destroy());
  await new Promise(r => holder.listen(m.config.port, '127.0.0.1', r));
  setTimeout(() => holder.close(), 700);
  const t0 = Date.now();
  try {
    await m.start();
    assert.equal(m.state, 'running');
    assert.ok(Date.now() - t0 >= 600, 'it waited for the port instead of failing at once');
  } finally {
    await m.stop();
    await close();
  }
});

test('a start in which no proxy can be reached fails instead of switching a dead proxy on', async () => {
  const m = manager(0);
  m.config.port = await freePort();
  m.config.providers[0].enabled = true;
  m.loader = async () => [{ key: 'k0', providerId: 'p1', providerName: 'P', label: 'proxy0', kind: 'static', hasSession: false, urlFor: () => 'http://x', host: '127.0.0.1', port: 1 }];
  await assert.rejects(m.start(), /proxies could be reached/);
  assert.equal(m.state, 'stopped');
  assert.equal(m.server, null);
});

// ---- Tor must be OUR Tor ----------------------------------------------------------------------------------------------

const torEntry = (id = 'tor-gone') => ({ key: `${id}|tor`, providerId: id, providerName: 'Tor', label: 'Tor', kind: 'gateway', viaTor: true, hasSession: true, newSession: () => 's', urlFor: () => 'socks5h://x', host: '127.0.0.1', port: 9999 });

test('a Tor entry whose Tor is not running is never used, even as a last resort', () => {
  const m = manager(0);
  const e = torEntry();
  m.runtime.set('tor-gone', { entries: [e], status: 'ok', error: null });
  m.rebuildIndex();
  assert.equal(m.isBad(e), true);
  assert.equal(m.isDead(e), true);
  assert.throws(() => m.pick('a.com'), err => err instanceof RequestError && err.statusCode === 503);

  // with a healthy proxy next to it, the dead Tor is never chosen
  const good = manager(3);
  good.runtime.get('p1').entries.push(e);
  good.rebuildIndex();
  for (let i = 0; i < 300; i++) { good.sticky.clear(); assert.notEqual(good.pick('a.com').entry.key, e.key); }
});

test('turning a provider off or deleting it takes it out of the pool at once, with its pins', async () => {
  const m = manager(5);
  m.config.providers[0].apiKey = 'k'.repeat(24);
  m.config.providers[0].countries = [];
  m.persist = () => {};
  m.pick('a.com'); m.pick('b.com');
  assert.equal(m.sticky.size, 2);
  await m.updateProvider('p1', { enabled: false });
  assert.equal(m.entryByKey.size, 0);
  assert.equal(m.sticky.size, 0);
  assert.equal(m.runtime.has('p1'), false);

  const n = manager(5);
  n.persist = () => {};
  n.pick('a.com');
  await n.deleteProvider('p1');
  assert.equal(n.entryByKey.size, 0);
  assert.equal(n.sticky.size, 0);
});

test('findTor only returns an absolute path', () => {
  const found = findTor();
  assert.ok(found === null || path.isAbsolute(found));
});

// ---- the watchdog puts the settings back from the recovery record -----------------------------------------------------

function fakeMac(services = ['Wi-Fi', 'Ethernet']) {
  const dir = tempDir();
  const state = path.join(dir, 'ns');
  fs.mkdirSync(state);
  fs.writeFileSync(path.join(state, 'services'), services.join('\n') + '\n');
  const bin = path.join(dir, 'networksetup');
  fs.writeFileSync(bin, `#!/bin/bash\nFAKE_NS=${JSON.stringify(state)} exec ${JSON.stringify(path.join(here, 'fixtures', 'fake-networksetup'))} "$@"\n`, { mode: 0o755 });
  const put = (name, svc, value) => fs.writeFileSync(path.join(state, `${name}.${svc}`), value + '\n');
  const val = (name, svc) => { try { return fs.readFileSync(path.join(state, `${name}.${svc}`), 'utf8').trim(); } catch { return ''; } };
  const record = r => fs.writeFileSync(path.join(dir, '.system-proxy.json'), JSON.stringify(r));
  const hasRecord = () => fs.existsSync(path.join(dir, '.system-proxy.json'));
  const ours = (svc, port = 59999) => { for (const k of ['webproxy', 'securewebproxy']) { put(`${k}.en`, svc, 'Yes'); put(`${k}.server`, svc, '127.0.0.1'); put(`${k}.port`, svc, String(port)); } };
  return { dir, state, bin, put, val, record, hasRecord, ours };
}

const SAVED = { pacURL: 'http://pac.example/proxy.pac', pacEnabled: true, discovery: true, addedBypass: ['added.test', '10.0.0.0/8'] };

test('after a force-quit the watchdog restores the PAC file, discovery and the bypass list from the record', async () => {
  const mac = fakeMac();
  mac.ours('Wi-Fi'); mac.ours('Ethernet');
  mac.put('bypass', 'Wi-Fi', 'keep.me\nadded.test\n10.0.0.0/8');
  mac.record({ port: 59999, services: { 'Wi-Fi': SAVED, Ethernet: { pacEnabled: false, discovery: false, addedBypass: [] } } });
  assert.equal(await disableOurs(8888, mac.dir, { bin: mac.bin }), true);
  assert.equal(mac.val('webproxy.en', 'Wi-Fi'), 'No');
  assert.equal(mac.val('securewebproxy.en', 'Ethernet'), 'No');
  assert.equal(mac.val('pac.url', 'Wi-Fi'), 'http://pac.example/proxy.pac');
  assert.equal(mac.val('pac.en', 'Wi-Fi'), 'Yes');
  assert.equal(mac.val('disc', 'Wi-Fi'), 'On');
  assert.equal(fs.readFileSync(path.join(mac.state, 'bypass.Wi-Fi'), 'utf8').trim(), 'keep.me', 'only what Kagewon added was removed');
  assert.equal(mac.hasRecord(), false);
});

test('the PAC file is restored even when something else already switched the manual proxy off', async () => {
  const mac = fakeMac();
  mac.record({ port: 59999, services: { 'Wi-Fi': SAVED } });
  assert.equal(await disableOurs(8888, mac.dir, { bin: mac.bin }), true);
  assert.equal(mac.val('pac.en', 'Wi-Fi'), 'Yes');
  assert.equal(mac.val('disc', 'Wi-Fi'), 'On');
  assert.equal(mac.hasRecord(), false);
});

test('a PAC setting that someone else changed meanwhile is not overwritten', async () => {
  const mac = fakeMac();
  mac.ours('Wi-Fi');
  mac.put('pac.url', 'Wi-Fi', 'http://their.example/other.pac'); mac.put('pac.en', 'Wi-Fi', 'Yes');
  mac.record({ port: 59999, services: { 'Wi-Fi': SAVED } });
  await disableOurs(8888, mac.dir, { bin: mac.bin });
  assert.equal(mac.val('pac.url', 'Wi-Fi'), 'http://their.example/other.pac');
  assert.equal(mac.val('webproxy.en', 'Wi-Fi'), 'No', 'our own proxy is still switched off');
});

test('a proxy that is not ours stays on, and port 3000 does not match 30000 or 127.0.0.10', async () => {
  const mac = fakeMac();
  mac.ours('Wi-Fi', 30000);
  mac.put('webproxy.en', 'Ethernet', 'Yes'); mac.put('webproxy.server', 'Ethernet', '127.0.0.10'); mac.put('webproxy.port', 'Ethernet', '3000');
  assert.equal(await disableOurs(3000, mac.dir, { bin: mac.bin }), true);
  assert.equal(mac.val('webproxy.en', 'Wi-Fi'), 'Yes');
  assert.equal(mac.val('webproxy.en', 'Ethernet'), 'Yes');
});

test('if the settings cannot be read, nothing is claimed and the record is kept for a later try', async () => {
  const mac = fakeMac();
  mac.ours('Wi-Fi');
  mac.record({ port: 59999, services: { 'Wi-Fi': SAVED } });
  fs.writeFileSync(path.join(mac.state, 'fail.-listallnetworkservices'), '');
  assert.equal(await disableOurs(8888, mac.dir, { bin: mac.bin }), false);
  assert.equal(mac.hasRecord(), true);
  assert.equal(mac.val('webproxy.en', 'Wi-Fi'), 'Yes', 'nothing was changed on a guess');
});

test('a failed read of the bypass list never overwrites it', async () => {
  const mac = fakeMac();
  mac.put('bypass', 'Wi-Fi', 'keep.me\nadded.test');
  mac.record({ port: 59999, services: { 'Wi-Fi': { ...SAVED, pacURL: undefined } } });
  fs.writeFileSync(path.join(mac.state, 'fail.-getproxybypassdomains'), '');
  await disableOurs(8888, mac.dir, { bin: mac.bin });
  assert.equal(fs.readFileSync(path.join(mac.state, 'bypass.Wi-Fi'), 'utf8').trim(), 'keep.me\nadded.test');
});

test('DEBUG is removed before any library can print host names', () => {
  const out = execFileSync(process.execPath, ['-e', "import('./src/safe-env.mjs').then(() => console.log(String(process.env.DEBUG) + ' ' + String(process.env.NODE_DEBUG)))"], {
    cwd: path.join(here, '..'), env: { ...process.env, DEBUG: '*', NODE_DEBUG: 'http' }, encoding: 'utf8',
  });
  assert.equal(out.trim(), 'undefined undefined');
});
