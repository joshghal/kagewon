import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { Server } from 'proxy-chain';
import { ensureTor } from './tor.mjs';

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

const validProxy = x => typeof x?.proxy_address === 'string' && HOST_RE.test(x.proxy_address)
  && Number.isInteger(x.port) && x.port >= 1 && x.port <= 65535
  && typeof x.username === 'string' && typeof x.password === 'string';

async function loadWebshare(p, env) {
  // The override exists for tests and only accepts a local address, so the API key can never be pointed at another host.
  const override = env.WEBSHARE_API_BASE ? new URL(env.WEBSHARE_API_BASE) : null;
  const base = override && ['127.0.0.1', 'localhost'].includes(override.hostname) ? override : new URL('https://proxy.webshare.io');
  const entries = [];
  let next = new URL('/api/v2/proxy/list/?mode=direct&page=1&page_size=100', base).toString();

  /** The API key goes with every request, so a "next" link may only ever lead back to the same host, over the same scheme. */
  const sameHost = link => {
    try {
      const u = new URL(link, base);
      if (u.hostname !== base.hostname) return null;
      u.protocol = base.protocol; // an http:// link from a server behind a proxy must not downgrade the connection
      u.port = base.port;
      return u.toString();
    } catch { return null; }
  };

  for (let page = 1; next; page++) {
    if (page > MAX_PAGES) throw new Error('Webshare returned too many pages');
    let res;
    try {
      res = await fetch(next, { headers: { Authorization: `Token ${p.apiKey}` }, signal: AbortSignal.timeout(20_000) });
    } catch (err) {
      throw new Error(`Could not reach Webshare (${err.cause?.code ?? err.name})`);
    }
    // fetch drops the Authorization header when it follows a redirect to another origin; refuse such an answer anyway
    if (res.url && new URL(res.url).hostname !== base.hostname) throw new Error('Webshare redirected somewhere unexpected, so loading was stopped');
    if (res.status === 401 || res.status === 403) throw new Error('Webshare rejected the API key');
    if (!res.ok) throw new Error(`Webshare API error ${res.status}`);
    const body = await res.json().catch(() => null);
    if (!Array.isArray(body?.results)) throw new Error('Webshare sent an unexpected answer');
    for (const x of body.results) {
      if (!x?.valid || !validProxy(x)) continue;
      if (p.countries?.length && !p.countries.includes(x.country_code)) continue;
      entries.push(staticEntry(p, x.proxy_address, x.port, x.username, x.password));
      if (entries.length >= MAX_ENTRIES) break;
    }
    if (entries.length >= MAX_ENTRIES || !body.next) break;
    next = sameHost(body.next);
    if (!next) throw new Error('Webshare sent an unexpected link, so loading was stopped');
  }
  if (!entries.length) throw new Error(p.countries?.length ? 'No proxies match the country filter' : 'Your Webshare account has no usable proxies');
  return entries;
}

export const __torEntryForTest = torEntry; // for tests only

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
