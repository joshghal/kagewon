import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { loadProvider, __torEntryForTest, __validProxyForTest } from '../src/providers.mjs';
import { normalizeProvider } from '../src/config.mjs';

const KEY = 'abcdefghij0123456789WXYZ';
const ctx = { dir: '.', log() {} };

/** A fake Webshare API. `pages` maps a request number to the JSON it answers. */
async function fakeApi(handler) {
  const server = http.createServer((req, res) => {
    const out = handler(req, server.address().port);
    res.writeHead(out.status ?? 200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(out.body ?? {}));
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  return { server, base: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(r => server.close(r)) };
}
const proxy = (over = {}) => ({ valid: true, proxy_address: '1.2.3.4', port: 8080, username: 'u', password: 'p', country_code: 'US', ...over });
const webshare = () => normalizeProvider({ type: 'webshare', apiKey: KEY });

test('Webshare: pages are followed on the same host, and malformed proxies are skipped', async () => {
  const api = await fakeApi((req, port) => req.url.includes('page=1')
    ? { body: { next: `http://127.0.0.1:${port}/api/v2/proxy/list/?mode=direct&page=2&page_size=100`, results: [proxy(), proxy({ proxy_address: 'bad host!' }), proxy({ port: 70000 })] } }
    : { body: { next: null, results: [proxy({ proxy_address: '5.6.7.8' }), proxy({ valid: false }), proxy({ username: 5 })] } });
  try {
    const entries = await loadProvider(webshare(), { WEBSHARE_API_BASE: api.base }, ctx);
    assert.deepEqual(entries.map(e => e.label), ['1.2.3.4:8080', '5.6.7.8:8080']);
  } finally { await api.close(); }
});

test('Webshare: a link to another host is refused, so the API key is never sent there', async () => {
  const seenByAttacker = [];
  const attacker = await fakeApi(req => { seenByAttacker.push(req.headers.authorization); return { body: { next: null, results: [proxy()] } }; });
  // "localhost" is a different host name than the "127.0.0.1" the API is reached by
  const api = await fakeApi(() => ({ body: { next: attacker.base.replace('127.0.0.1', 'localhost') + '/steal', results: [proxy()] } }));
  try {
    await assert.rejects(loadProvider(webshare(), { WEBSHARE_API_BASE: api.base }, ctx), /unexpected link/);
    assert.deepEqual(seenByAttacker, [], 'nothing reached the other host');
  } finally { await api.close(); await attacker.close(); }
});

test('Webshare: a next link with another port or scheme is pulled back to the original server', async () => {
  const seenByOther = [];
  const other = await fakeApi(req => { seenByOther.push(req.headers.authorization); return { body: {} }; });
  let calls = 0;
  const api = await fakeApi(() => ++calls === 1
    ? { body: { next: `https://127.0.0.1:${other.server.address().port}/api/v2/proxy/list/?page=2`, results: [proxy()] } }
    : { body: { next: null, results: [proxy({ proxy_address: '9.9.9.9' })] } });
  try {
    const entries = await loadProvider(webshare(), { WEBSHARE_API_BASE: api.base }, ctx);
    assert.deepEqual(entries.map(e => e.label), ['1.2.3.4:8080', '9.9.9.9:8080']);
    assert.deepEqual(seenByOther, [], 'the other port never saw the key');
  } finally { await api.close(); await other.close(); }
});

test('Webshare: an endless chain of pages stops', async () => {
  const api = await fakeApi((req, port) => ({ body: { next: `http://127.0.0.1:${port}/api/v2/proxy/list/?mode=direct&page=2`, results: [proxy()] } }));
  try {
    await assert.rejects(loadProvider(webshare(), { WEBSHARE_API_BASE: api.base }, ctx), /too many pages/);
  } finally { await api.close(); }
});

test('Webshare: errors are readable and never contain the API key', async () => {
  const rejected = await fakeApi(() => ({ status: 401, body: {} }));
  try {
    await assert.rejects(loadProvider(webshare(), { WEBSHARE_API_BASE: rejected.base }, ctx), err => /rejected the API key/.test(err.message) && !err.message.includes(KEY));
  } finally { await rejected.close(); }
  const down = await fakeApi(() => ({ body: {} }));
  const base = down.base;
  await down.close(); // nothing listens on this port any more
  await assert.rejects(loadProvider(webshare(), { WEBSHARE_API_BASE: base }, ctx), err => /Could not reach Webshare/.test(err.message) && !err.message.includes(KEY));
});

test('Tor logins carry the hostname to Tor (socks5h), and every random connection gets its own login', () => {
  const entry = __torEntryForTest(normalizeProvider({ type: 'tor', socksPort: 9461 }));
  assert.equal(entry.urlFor('abc123'), 'socks5h://s-abc123:x@127.0.0.1:9461');
  assert.notEqual(entry.urlFor(null), entry.urlFor(null));
  assert.equal(entry.kind, 'gateway');
});

test('a proxy address must be a real public host: loopback, LAN and malformed values are refused', () => {
  const ok = host => __validProxyForTest({ proxy_address: host, port: 8080, username: 'u', password: 'p' });
  for (const h of ['127.0.0.1', 'localhost', '10.0.0.5', '192.168.1.1', '100.64.0.1', 'fritz.box', '999.1.1.1', '1.2.3.4.5', '', 'bad host', '[::1]']) {
    assert.equal(ok(h), false, h);
  }
  for (const h of ['1.2.3.4', 'proxy.example.com', '45.67.89.10']) assert.equal(ok(h), true, h);
});

test('one proxy with an unusable login does not abort the whole list', async () => {
  const api = await fakeApi(() => ({ body: { next: null, results: [proxy({ username: '\ud800' }), proxy({ proxy_address: '5.6.7.8' })] } }));
  try {
    const entries = await loadProvider(webshare(), { WEBSHARE_API_BASE: api.base }, ctx);
    assert.deepEqual(entries.map(e => e.label), ['5.6.7.8:8080']);
  } finally { await api.close(); }
});

test('an oversized answer is rejected instead of being read into memory', async () => {
  const server = http.createServer((req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(' '.repeat(6_000_000)); });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  try {
    await assert.rejects(loadProvider(webshare(), { WEBSHARE_API_BASE: `http://127.0.0.1:${server.address().port}` }, ctx), /too large/);
  } finally { await new Promise(r => server.close(r)); }
});

test('a redirect to another host is refused, and one to the same host is followed', async () => {
  const hits = [];
  const other = await fakeApi(req => { hits.push(req.headers.authorization); return { body: {} }; });
  let first = true;
  const api = http.createServer((req, res) => {
    if (req.url.startsWith('/api/v2/proxy/list/') && first) {
      first = false;
      res.writeHead(302, { location: other.base.replace('127.0.0.1', 'localhost') + '/stolen' });
      return res.end();
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ next: null, results: [proxy()] }));
  });
  await new Promise(r => api.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${api.address().port}`;
  try {
    await assert.rejects(loadProvider(webshare(), { WEBSHARE_API_BASE: base }, ctx), /redirected somewhere unexpected/);
    assert.deepEqual(hits, [], 'the key never reached the other host');
  } finally { await new Promise(r => api.close(r)); await other.close(); }

  const sameHostApi = http.createServer((req, res) => {
    if (req.url === '/api/v2/proxy/list/?mode=direct&page=1&page_size=100') { res.writeHead(301, { location: '/moved' }); return res.end(); }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ next: null, results: [proxy()] }));
  });
  await new Promise(r => sameHostApi.listen(0, '127.0.0.1', r));
  try {
    const entries = await loadProvider(webshare(), { WEBSHARE_API_BASE: `http://127.0.0.1:${sameHostApi.address().port}` }, ctx);
    assert.equal(entries.length, 1);
  } finally { await new Promise(r => sameHostApi.close(r)); }
});
