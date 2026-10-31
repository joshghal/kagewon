// Fake services for the demonstration: a Webshare-like API and twelve dummy proxies, all on 127.0.0.1.
// Nothing here talks to the internet. The dummy proxies answer plain HTTP requests only, and every address that
// appears in the interface is from 203.0.113.0/24 or 198.51.100.0/24, which are reserved for documentation.
import http from 'node:http';

const API_PORT = 29100;
const DIRECT_PORT = 18080; // what an IP echo service would say to you WITHOUT the proxy
const FIRST_PROXY_PORT = 29101;
const COUNT = 12;
const COUNTRIES = ['US', 'US', 'DE', 'GB', 'NL', 'CA', 'FR', 'US', 'DE', 'GB', 'SE', 'ES'];
const LIST_DELAY_MS = 1500; // slow enough for the "Loading proxy lists" step to be visible in a recording

for (let i = 0; i < COUNT; i++) {
  const exitIp = `203.0.113.${10 + i}`;
  const proxy = http.createServer((req, res) => {
    let host = '';
    try { host = new URL(req.url).hostname; } catch {}
    if (host === 'ip.example.com') { // the demonstration's stand-in for an IP echo service
      res.writeHead(200, { 'content-type': 'text/plain' });
      return res.end(`${exitIp}\n`);
    }
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(`${host} via ${exitIp}\n`);
  });
  proxy.on('connect', (req, socket) => socket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
  proxy.listen(FIRST_PROXY_PORT + i, '127.0.0.1');
}

http.createServer((req, res) => {
  const key = String(req.headers.authorization ?? '').replace(/^Token /, '');
  if (!key.startsWith('demo-')) { res.writeHead(401, { 'content-type': 'application/json' }); return res.end('{}'); }
  if (!req.url.startsWith('/api/v2/proxy/list/')) { res.writeHead(404); return res.end('{}'); }
  const results = Array.from({ length: COUNT }, (_, i) => ({
    valid: true, proxy_address: '127.0.0.1', port: FIRST_PROXY_PORT + i, username: 'demo', password: 'demo', country_code: COUNTRIES[i],
  }));
  setTimeout(() => {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ count: COUNT, next: null, previous: null, results }));
  }, LIST_DELAY_MS);
}).listen(API_PORT, '127.0.0.1', () => console.log(`demo services ready: API on ${API_PORT}, ${COUNT} proxies from ${FIRST_PROXY_PORT}`));

http.createServer((req, res) => { res.writeHead(200, { 'content-type': 'text/plain' }); res.end('198.51.100.23\n'); }).listen(DIRECT_PORT, '127.0.0.1');
