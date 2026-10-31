import http from 'node:http';
import crypto from 'node:crypto';

const MAX_BODY = 1_000_000;

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('Request too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!size) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(Object.assign(new Error('Invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

/**
 * Local control API used by the menu bar app. It only listens on 127.0.0.1, checks the Host header
 * (DNS rebinding) and requires a secret token header, so a web page cannot talk to it.
 */
export function startControl({ manager, host, port, token }) {
  const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  const tokenOk = given => {
    const a = Buffer.from(String(given ?? ''));
    const b = Buffer.from(token);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  };

  const server = http.createServer(async (req, res) => {
    const send = (code, obj) => {
      res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify(obj));
    };
    try {
      if (!allowedHosts.has(String(req.headers.host ?? '').toLowerCase())) return send(403, { error: 'Forbidden' });
      if (!tokenOk(req.headers['x-control-token'])) return send(401, { error: 'Unauthorized' });

      const { pathname, searchParams } = new URL(req.url, 'http://localhost');
      const body = req.method === 'POST' || req.method === 'PUT' ? await readJson(req) : {};
      const route = `${req.method} ${pathname}`;
      const providerId = pathname.match(/^\/api\/providers\/([\w-]+)$/)?.[1];

      // Validation problems become 400; anything unexpected stays a 500.
      const bad = fn => fn().catch(err => { throw Object.assign(err, { status: err.status ?? 400 }); });

      switch (true) {
        case route === 'GET /api/status': return send(200, manager.status());
        case route === 'GET /api/log': return send(200, manager.logSince(Number(searchParams.get('since')) || 0));
        case route === 'POST /api/proxy/start': await manager.start(); return send(200, { ok: true });
        case route === 'POST /api/proxy/stop': await manager.stop(); return send(200, { ok: true });
        case route === 'POST /api/ip': return send(200, { ip: await manager.exitIp() });
        case route === 'PUT /api/settings': return send(200, await bad(async () => { manager.setSettings(body); return { ok: true }; }));
        case route === 'POST /api/providers': return send(200, await bad(() => manager.addProvider(body)));
        case route === 'POST /api/providers/test': return send(200, await bad(() => manager.test(body)));
        case req.method === 'PUT' && Boolean(providerId): return send(200, await bad(() => manager.updateProvider(providerId, body)));
        case req.method === 'DELETE' && Boolean(providerId): await bad(() => manager.deleteProvider(providerId)); return send(200, { ok: true });
        default: return send(404, { error: 'Not found' });
      }
    } catch (err) {
      send(err.status ?? 500, { error: err.message });
    }
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve(server));
  });
}
