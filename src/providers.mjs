import crypto from 'node:crypto';
import net from 'node:net';
import { execFile } from 'node:child_process';
import { Server } from 'proxy-chain';
import { ensureTor } from './tor.mjs';
import { isInternalHost } from './hosts.mjs';

const enc = encodeURIComponent;
const MAX_PAGES = 50;
const MAX_ENTRIES = 5000;
const HOST_RE = /^[A-Za-z0-9.-]{1,253}$/;
const CURL = '/usr/bin/curl';

export const randomSession = () => crypto.randomBytes(5).toString('hex');

function buildUrl(scheme, host, port, user, pass) {
  const auth = user ? `${enc(user)}:${enc(pass ?? '')}@` : '';
  return `${scheme}://${auth}${host}:${port}`;
}

function staticEntry(provider, host, port, user, pass) {
  const url = buildUrl('http', host, port, user, pass);
  return {
    kind: 'static',
    providerId: provider.id,
    providerName: provider.name,
    host,
    port: Number(port),
    label: `${host}:${port}`,
    key: `${provider.id}|${url}`, // internal only: it contains the password, never log or send it
    hasSession: false,
    urlFor: () => url,
  };
}

/**
 * A private Tor client. Each session id is a SOCKS login, and Tor gives every login its own circuit (exit IP).
 * "socks5h" makes the hostname travel to Tor, so it is resolved there and never by this Mac's resolver.
 */
function torEntry(p) {
  return {
    kind: 'gateway',
    providerId: p.id,
    providerName: p.name,
    host: '127.0.0.1',
    port: p.socksPort,
    label: `Tor 127.0.0.1:${p.socksPort}`,
    key: `${p.id}|tor`,
    hasSession: true,
    // No session (random mode) still gets a fresh login each time, so every connection takes a new circuit.
    urlFor: session => buildUrl('socks5h', '127.0.0.1', p.socksPort, `${session ? 's' : 'r'}-${session ?? randomSession()}`, 'x'),
  };
}

const MAX_BODY_BYTES = 5_000_000;

// A proxy address from an API answer is untrusted: it must be a real public host. A name needs a letter, so 999.1.1.1 is
// not a host name, and loopback or LAN addresses would make the helper dial local services (or itself) as "proxies".
const isUsableHost = (h, allowLocal) => typeof h === 'string' && h.length <= 253 && (allowLocal || !isInternalHost(h))
  && (net.isIPv4(h) || (HOST_RE.test(h) && /[a-z]/i.test(h)));

// allowLocal is true only while a local test API is in use, so test fixtures can run on 127.0.0.1
const validProxy = (x, allowLocal = false) => isUsableHost(x?.proxy_address, allowLocal)
  && Number.isInteger(x.port) && x.port >= 1 && x.port <= 65535
  && typeof x.username === 'string' && typeof x.password === 'string';

/** Reads a JSON body but gives up beyond a fixed size, so a hostile or broken server cannot exhaust memory. */
async function readJsonCapped(res) {
  const reader = res.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new Error('Webshare sent a response that is too large');
    }
    chunks.push(value);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return null; }
}

async function loadWebshare(p, env) {
  // The override exists for tests and only accepts a local address, so the API key can never be pointed at another host.
  const override = env.WEBSHARE_API_BASE ? new URL(env.WEBSHARE_API_BASE) : null;
  const base = override && ['127.0.0.1', 'localhost'].includes(override.hostname) ? override : new URL('https://proxy.webshare.io');
  const usingTestApi = base === override;
  const entries = [];

  /** The API key goes with every request, so a link or redirect may only ever lead back to the same host, over the same scheme. */
  const sameHost = (link, from) => {
    try {
      const u = new URL(link, from);
      if (u.hostname !== base.hostname) return null;
      u.protocol = base.protocol; // an http:// link from a server behind a proxy must not downgrade the connection
      u.port = base.port;
      return u.toString();
    } catch { return null; }
  };

  // Redirects are followed by hand, so no request is ever sent to a host other than the API's own.
  const get = async url => {
    let current = url;
    for (let hop = 0; hop < 4; hop++) {
      let res;
      try {
        res = await fetch(current, { headers: { Authorization: `Token ${p.apiKey}` }, signal: AbortSignal.timeout(20_000), redirect: 'manual' });
      } catch (err) {
        throw new Error(`Could not reach Webshare (${err.cause?.code ?? err.name})`);
      }
      if (res.status >= 300 && res.status < 400) {
        const location = res.headers.get('location');
        const target = location && sameHost(location, current);
        await res.body?.cancel();
        if (!target) throw new Error('Webshare redirected somewhere unexpected, so loading was stopped');
        current = target;
        continue;
      }
      return res;
    }
    throw new Error('Webshare redirected too many times');
  };

  let next = sameHost('/api/v2/proxy/list/?mode=direct&page=1&page_size=100', base);
  for (let page = 1; next; page++) {
    if (page > MAX_PAGES) throw new Error('Webshare returned too many pages');
    const res = await get(next);
    if (res.status === 401 || res.status === 403) throw new Error('Webshare rejected the API key');
    if (!res.ok) throw new Error(`Webshare API error ${res.status}`);
    const body = await readJsonCapped(res);
    if (!Array.isArray(body?.results)) throw new Error('Webshare sent an unexpected answer');
    for (const x of body.results) {
      if (!x?.valid || !validProxy(x, usingTestApi)) continue;
      if (p.countries?.length && !p.countries.includes(x.country_code)) continue;
      try {
        entries.push(staticEntry(p, x.proxy_address, x.port, x.username, x.password));
      } catch {
        continue; // one unusable login (for example a lone surrogate character) must not abort the whole list
      }
      if (entries.length >= MAX_ENTRIES) break;
    }
    if (entries.length >= MAX_ENTRIES || !body.next) break;
    next = sameHost(body.next, next);
    if (!next) throw new Error('Webshare sent an unexpected link, so loading was stopped');
  }
  if (!entries.length) throw new Error(p.countries?.length ? 'No proxies match the country filter' : 'Your Webshare account has no usable proxies');
  return entries;
}

export const __torEntryForTest = torEntry; // for tests only
export const __validProxyForTest = validProxy; // for tests only

/** ctx: { dir, log, onTorExit } for providers that need to run something locally (Tor). */
export async function loadProvider(p, env, ctx) {
  if (p.type === 'webshare') return loadWebshare(p, env);
  await ensureTor(p, ctx.dir, ctx.log, ctx.onTorExit);
  return [torEntry(p)];
}

function curlIp(proxyUrl) {
  const urls = ['https://api.ipify.org', 'https://icanhazip.com'];
  const attempt = i => new Promise((resolve, reject) => {
    // -q ignores ~/.curlrc and the empty environment ignores NO_PROXY and friends, so the check cannot skip the proxy
    execFile(CURL, ['-q', '-sSf', '-m', '20', '-x', proxyUrl, urls[i]], { env: {} }, (err, stdout, stderr) => {
      const ip = stdout.trim();
      if (!err && /^[0-9a-f:.]{3,45}$/i.test(ip)) return resolve(ip);
      if (i + 1 < urls.length) return attempt(i + 1).then(resolve, reject);
      reject(new Error((stderr || err?.message || 'No answer').replace(/^curl: \(\d+\)\s*/, '').trim()));
    });
  });
  return attempt(0);
}

/** The IP that the exit-IP check site sees when going through the given local proxy. */
export const fetchIp = localProxyUrl => curlIp(localProxyUrl);

/** Loads a provider, then fetches the exit IP through one of its proxies. */
export async function testProvider(p, env, ctx) {
  const t0 = Date.now();
  const entries = await loadProvider(p, env, ctx);
  const entry = entries[Math.floor(Math.random() * entries.length)];
  const upstream = entry.urlFor(entry.hasSession ? randomSession() : null);
  // A throwaway local proxy lets curl use any upstream type (HTTP or SOCKS) with credentials.
  const tmp = new Server({ host: '127.0.0.1', port: 0, prepareRequestFunction: () => ({ upstreamProxyUrl: upstream }) });
  await tmp.listen();
  try {
    const ip = await fetchIp(`http://127.0.0.1:${tmp.port}`);
    return { ok: true, count: entries.length, ip, ms: Date.now() - t0 };
  } finally {
    await tmp.close(true);
  }
}
