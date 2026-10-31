import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { Server, RequestError } from 'proxy-chain';
import { Manager } from '../src/manager.mjs';
import { DEFAULT_SETTINGS, normalizeProvider } from '../src/config.mjs';
import { tempDir } from './helpers.mjs';

const freePort = () => new Promise(resolve => {
  const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
});

const connect = (port, target) => new Promise((resolve, reject) => {
  const req = http.request({ method: 'CONNECT', host: '127.0.0.1', port, path: target });
  req.on('connect', (res, socket) => { socket.destroy(); resolve(res.statusCode); });
  req.on('error', reject);
  req.end();
});

test('local and private destinations are refused before reaching any provider; public ones are forwarded', async () => {
  const asked = [];
  const upstream = new Server({
    host: '127.0.0.1', port: 0,
    prepareRequestFunction: ({ hostname }) => { asked.push(hostname); throw new RequestError('stop', 502); },
  });
  await upstream.listen();
  const api = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ next: null, results: [{ valid: true, proxy_address: '127.0.0.1', port: upstream.port, username: 'u', password: 'p', country_code: 'US' }] }));
  });
  await new Promise(r => api.listen(0, '127.0.0.1', r));

  const port = await freePort();
  const m = new Manager({
    dir: tempDir(),
    config: { ...DEFAULT_SETTINGS, port, providers: [normalizeProvider({ type: 'webshare', apiKey: 'k'.repeat(24) })] },
    env: { WEBSHARE_API_BASE: `http://127.0.0.1:${api.address().port}` },
  });
  m.log = () => {};
  try {
    await m.start();
    for (const target of ['192.168.1.1:80', '10.0.0.7:443', '127.0.0.1:8889', 'localhost:22', 'printer:631', 'router.local:80',
      '127.1:80', '0x7f.1:80', '0177.0.0.1:80', '[::ffff:7f00:1]:80', '[::1]:80', 'localhost..:80']) {
      assert.equal(await connect(port, target), 403, target);
    }
    // spellings and shapes that could be read two ways, or that name a private network
    for (const target of ['localhost%2e:80', '127.0.0.1:80@evil.com:443', 'user:pw@127.0.0.1:80', 'fritz.box:80', 'printer.home:80', 'wiki.corp:80',
      'a'.repeat(300) + '.com:443']) {
      const code = await connect(port, target);
      assert.ok(code === 400 || code === 403, `${target.slice(0, 40)} was answered with ${code}`);
    }
    assert.deepEqual(asked, [], 'the provider never saw a local address');
    await connect(port, 'example.com:443');
    assert.deepEqual(asked, ['example.com'], 'a public site is forwarded');
  } finally {
    await m.stop();
    await upstream.close(true);
    await new Promise(r => api.close(r));
  }
});
