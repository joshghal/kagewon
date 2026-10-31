import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { Server, RequestError } from 'proxy-chain';
import { saveConfig, normalizeProvider, normalizeSettings, maskProvider, MAX_PROVIDERS } from './config.mjs';
import { loadProvider, testProvider, fetchIp, randomSession } from './providers.mjs';
import { siteKey, isInternalHost, isValidConnectTarget, MACOS_BYPASS } from './hosts.mjs';
import { hasTor, pruneTor, stopTor, stopAllTor } from './tor.mjs';

const BAD_COOLDOWN_MS = 5 * 60_000;
const SITE_COOLDOWN_MS = 10 * 60_000; // how long a proxy is avoided for a site that refused it
const FAIL_WINDOW_MS = 2 * 60_000;
const BENCH_AFTER_SITES = 3; // a proxy is benched only when this many DIFFERENT sites fail on it
const GIVE_UP_AFTER_PROXIES = 3; // a site refused by this many different proxies counts as blocked
const HEALTH_MS = 60_000;
const MAX_LOG = 300;
const MAX_STICKY = 5000; // a hostile client could otherwise make the per-site records grow without limit
const HOST_COOLDOWN_MS = 2 * 60_000; // a proxy is avoided this long for ONE host name that has never worked
const ESTABLISHED_TTL_MS = 6 * 3600_000; // how long a host name counts as "known to work"
const BIND_RETRY_MS = 6000; // the app may still be releasing the port when the proxy starts
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function tcpAlive(host, port) {
  return new Promise(resolve => {
    const sock = net.connect({ host, port, timeout: 3000 });
    sock.once('connect', () => { sock.destroy(); resolve(true); });
    sock.once('timeout', () => { sock.destroy(); resolve(false); });
    sock.once('error', () => resolve(false));
  });
}

async function mapLimit(items, limit, fn) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) await fn(items[i++]);
  }));
}

export class Manager {
  constructor({ dir, config, env = {} }) {
    this.dir = dir;
    this.config = config;
    this.env = env; // only developer overrides such as WEBSHARE_API_BASE; nothing the user has to set
    this.loader = loadProvider; // replaceable in tests
    this.host = '127.0.0.1'; // never configurable: the proxy must not be reachable from the network
    this.listenPort = null; // the port actually in use while running

    this.state = 'stopped'; // stopped | starting | running
    this.stage = null; // while starting: loading | checking | listening, so the app can show progress
    this.lastError = null;
    this.runtime = new Map(); // providerId -> { entries, status, error, loadedAt, skipped }
    this.entryByKey = new Map();
    this.bad = new Map(); // entry key -> cooldown expiry (benched)
    this.probeFails = new Map(); // entry key -> consecutive failed TCP probes
    this.siteBad = new Map(); // `${site}|${key}` -> expiry: this proxy refused this site
    this.siteFails = new Map(); // site -> Map(key -> time): proxies that recently refused the site
    this.proxyFails = new Map(); // key -> Map(site -> time): sites that recently failed on the proxy
    this.blocked = new Map(); // site -> expiry: refused by many proxies, so we stop rotating for it
    this.lastFailLog = new Map(); // site -> time of the last log line about it
    this.conns = new Map(); // client connection id -> { site, assigned }: connections living under a sticky pin
    this.sticky = new Map(); // site -> { key, session, assigned, provider, label, confirmed }
    // Host names are the unit of failure. A web page can make the browser ask for host names that do not exist
    // (nx.yourbank.example), and the provider refuses those tunnels. Only a host name that has worked before is allowed
    // to affect the pinned IP of its site or the standing of a proxy; a name that never worked only gets its own detour.
    this.gen = 0; // counts starts and stops, so a start that was stopped meanwhile can tell
    this.established = new Map(); // host name -> time it last worked through a proxy
    this.hostBad = new Map(); // `${host}|${key}` -> expiry: this proxy failed for this host name, which has never worked
    this.hostFails = new Map(); // host -> Map(key -> time)
    this.hostBlocked = new Map(); // host -> expiry: refused by many proxies
    this.tags = new WeakMap();
    this.server = null;
    this.timers = [];
    this.logs = [];
    this.logSeq = 0;
  }

  // ---- logging -------------------------------------------------------------

  /**
   * The console (which the app saves to a log file) never gets the site name, because that would be a browsing
   * history on disk. The in-memory log shown in the Activity tab does get it, and is gone when the helper stops.
   */
  log(level, msg, site) {
    (level === 'warn' ? console.warn : console.log)(msg);
    this.logs.push({ n: ++this.logSeq, t: Date.now(), level, msg: site ? `${msg} [${site}]` : msg });
    if (this.logs.length > MAX_LOG) this.logs.shift();
  }

  logSince(since) {
    return { lines: this.logs.filter(l => l.n > since), next: this.logSeq };
  }

  // ---- pool ----------------------------------------------------------------

  get verbose() { return this.config.verbose; }
  get refreshMs() { return this.config.refreshMinutes * 60_000; }
  get stickyMs() { return this.config.stickySeconds * 1000; }

  ctx() {
    return {
      dir: this.dir,
      log: (level, msg) => this.log(level, msg),
      stickySeconds: () => this.config.stickySeconds,
      onTorExit: id => this.torExited(id),
    };
  }

  rt(id) {
    if (!this.runtime.has(id)) this.runtime.set(id, { entries: [], status: 'idle', error: null, loadedAt: null, skipped: 0 });
    return this.runtime.get(id);
  }

  isBenched(e) {
    return (this.bad.get(e.key) ?? 0) > Date.now();
  }

  /** A Tor entry whose Tor is not running: its port is free, and whatever binds it next would receive the traffic. */
  torGone(e) {
    return Boolean(e.viaTor) && !hasTor(e.providerId);
  }

  /** Should a NEW connection avoid this proxy? One missed health probe is enough. */
  isBad(e) {
    return this.probeFails.has(e.key) || this.isBenched(e) || this.torGone(e);
  }

  /** Should an EXISTING sticky pin be dropped? A single missed probe is common, so it takes two in a row. */
  isDead(e) {
    return (this.probeFails.get(e.key) ?? 0) >= 2 || this.isBenched(e) || this.torGone(e);
  }

  /** Loads one provider. A failure keeps the previous list and schedules the next attempt later and later (1, 2, 4, 8, 15 min). */
  async loadOne(p) {
    const rt = this.rt(p.id);
    try {
      const entries = await this.loader(p, this.env, this.ctx());
      Object.assign(rt, { entries, status: 'ok', error: null, loadedAt: Date.now(), skipped: entries.skipped ?? 0, failures: 0, retryAt: 0 });
    } catch (err) {
      const keepOldList = p.type !== 'tor' && rt.entries.length > 0;
      rt.status = 'error';
      rt.error = err.message;
      rt.failures = (rt.failures ?? 0) + 1;
      rt.retryAt = Date.now() + Math.min(15 * 60_000, 60_000 * 2 ** (rt.failures - 1));
      this.log('warn', `${p.name}: ${err.message}${keepOldList ? ' (keeping the previous list)' : ''}`);
      if (p.type === 'tor') {
        // The old Tor was stopped on purpose or has died. Its entry points at a port that nothing owns now, and
        // whatever binds that port next would receive the logins and every destination, so it must leave the pool.
        rt.entries = [];
        this.rebuildIndex();
        this.dropStalePins('Tor is not running');
      }
    }
  }

  async loadAll() {
    const enabled = this.config.providers.filter(p => p.enabled);
    await Promise.all(enabled.map(p => this.loadOne(p)));
    for (const id of [...this.runtime.keys()]) if (!enabled.some(p => p.id === id)) this.runtime.delete(id);
    await pruneTor(new Set(enabled.filter(p => p.type === 'tor').map(p => p.id)));
    this.rebuildIndex();
    this.dropStalePins('a provider was turned off or removed');
  }

  rebuildIndex() {
    this.entryByKey = new Map();
    for (const rt of this.runtime.values()) for (const e of rt.entries) this.entryByKey.set(e.key, e);
  }

  /** Forgets the pins that point at a proxy that is no longer in the pool, and closes the connections that used them. */
  dropStalePins(why) {
    const gone = new Set();
    for (const [site, s] of this.sticky) if (!this.entryByKey.has(s.key)) { this.sticky.delete(site); gone.add(site); }
    if (gone.size) this.cutConnections(c => gone.has(c.site), why);
  }

  /** A provider that is turned off, deleted or changed leaves the pool at once, not when the other providers finish loading. */
  dropFromPool(id) {
    if (!this.runtime.delete(id)) return;
    this.rebuildIndex();
    this.dropStalePins('a provider was turned off, removed or changed');
  }

  /** Tor died: take it out of the pool, so nothing that later binds its port can receive traffic meant for Tor. */
  torExited(id) {
    const rt = this.runtime.get(id);
    if (!rt) return;
    rt.entries = [];
    rt.status = 'error';
    rt.error = 'Tor stopped unexpectedly. Trying to start it again.';
    this.rebuildIndex();
    this.dropStalePins('Tor stopped');
  }

  async checkHealth() {
    const failed = new Set();
    await mapLimit([...this.entryByKey.values()], 50, async e => {
      // "Alive" means the port accepts connections, and for Tor that our own Tor is the one listening on it.
      if (this.torGone(e) || !(await tcpAlive(e.host, e.port))) failed.add(e.key);
    });
    const next = new Map([...failed].map(k => [k, (this.probeFails.get(k) ?? 0) + 1]));
    const label = k => this.entryByKey.get(k)?.label ?? 'a proxy';
    const wentDown = [...next.keys()].filter(k => !this.probeFails.has(k));
    const cameBack = [...this.probeFails.keys()].filter(k => !next.has(k) && this.entryByKey.has(k));
    if (wentDown.length <= 5) wentDown.forEach(k => this.log('warn', `Proxy ${label(k)} is unreachable, skipping it`));
    else this.log('warn', `${wentDown.length} proxies became unreachable, skipping them`);
    if (cameBack.length <= 5) cameBack.forEach(k => this.log('info', `Proxy ${label(k)} is back`));
    else this.log('info', `${cameBack.length} proxies are back`);
    this.probeFails = next;
    this.prune();
  }

  /** Forgets old failure records so the maps do not grow forever. */
  prune() {
    const now = Date.now();
    for (const m of [this.bad, this.siteBad, this.blocked]) for (const [k, t] of m) if (t <= now) m.delete(k);
    for (const m of [this.siteFails, this.proxyFails]) {
      for (const [k, inner] of m) {
        for (const [k2, t] of inner) if (now - t > FAIL_WINDOW_MS) inner.delete(k2);
        if (!inner.size) m.delete(k);
      }
    }
    for (const [k, t] of this.lastFailLog) if (now - t > FAIL_WINDOW_MS) this.lastFailLog.delete(k);
    for (const [h, t] of this.established) if (now - t > ESTABLISHED_TTL_MS) this.established.delete(h);
    for (const m of [this.hostBad, this.hostBlocked]) for (const [k, t] of m) if (t <= now) m.delete(k);
    for (const [h, inner] of this.hostFails) {
      for (const [k, t] of inner) if (now - t > FAIL_WINDOW_MS) inner.delete(k);
      if (!inner.size) this.hostFails.delete(h);
    }
    // Expired sticky records are dead weight, and they are a browsing history that should not linger.
    const stickyMs = this.stickyMs;
    for (const [site, s] of this.sticky) if (now - s.assigned >= stickyMs) this.sticky.delete(site);
    this.capMaps();
  }

  capMaps() {
    for (const m of [this.siteBad, this.siteFails, this.proxyFails, this.blocked, this.lastFailLog, this.established,
      this.hostBad, this.hostFails, this.hostBlocked]) {
      while (m.size > MAX_STICKY) m.delete(m.keys().next().value);
    }
  }

  /**
   * Every minute: probe the proxies, and retry only the providers that have none (for example Tor that stopped),
   * each on its own backoff, so one broken provider never makes the working ones reload again and again.
   */
  healthTick() {
    const now = Date.now();
    const due = this.config.providers.filter(p => {
      const rt = this.runtime.get(p.id);
      return p.enabled && (rt?.entries.length ?? 0) === 0 && now >= (rt?.retryAt ?? 0);
    });
    const work = due.length
      ? Promise.all(due.map(p => this.loadOne(p))).then(() => { this.rebuildIndex(); return this.checkHealth(); })
      : this.checkHealth();
    work.catch(() => {});
  }

  async reload() {
    await this.loadAll();
    if (this.state === 'running') {
      await this.checkHealth();
      if (!this.entryByKey.size) this.log('warn', 'No usable proxies right now; traffic will fail until a provider works');
    }
  }

  runtimeErrors() {
    return this.config.providers
      .filter(p => p.enabled && this.runtime.get(p.id)?.error)
      .map(p => `${p.name}: ${this.runtime.get(p.id).error}`)
      .join('; ');
  }

  // ---- proxy server --------------------------------------------------------

  async start() {
    if (this.state === 'running') return;
    if (this.state === 'starting') throw new Error('The proxy is already starting');
    const gen = ++this.gen;
    this.state = 'starting';
    this.stage = 'loading';
    this.lastError = null;
    const t0 = Date.now();
    let tLoaded = t0;
    let tChecked = t0;
    let server = null;
    // stop() may run while we wait for a provider or for the port; then this start must not carry on.
    const current = () => { if (gen !== this.gen) throw new Error('The proxy was stopped while it was starting'); };
    try {
      if (!this.config.providers.some(p => p.enabled)) {
        throw new Error('No provider is enabled. Add one in the Providers tab.');
      }
      await this.loadAll();
      current();
      tLoaded = Date.now();
      if (!this.entryByKey.size) throw new Error(this.runtimeErrors() || 'No usable proxies');
      this.stage = 'checking';
      await this.checkHealth();
      current();
      tChecked = Date.now();
      if (![...this.entryByKey.values()].some(e => !this.isBad(e))) {
        throw new Error(`None of the ${this.entryByKey.size} proxies could be reached. Check your connection, then try again.`);
      }

      this.stage = 'listening';
      const port = this.config.port;
      const makeServer = () => {
        const s = new Server({
          host: this.host,
          port,
          prepareRequestFunction: ({ request, hostname, port: targetPort, isHttp, connectionId }) => {
            // proxy-chain sends the raw CONNECT target upstream but reads a parsed copy, so anything that could be read
            // two ways (user@host, escapes, odd characters) is refused outright.
            if (!isHttp && !isValidConnectTarget(request.url)) throw new RequestError('Malformed CONNECT target', 400);
            if (isHttp) this.checkAbsoluteTarget(request);
            if (String(hostname).length > 253) throw new RequestError('Host name too long', 400);
            // This Mac and its network are never sent to a provider: it would see the request, and could not reach it.
            if (isInternalHost(hostname)) {
              this.logOncePerMinute(String(hostname).toLowerCase().slice(0, 100), 'A local or private address was not sent through the proxy');
              throw new RequestError('Local and private addresses are not sent through the proxy', 403);
            }
            const host = String(hostname).toLowerCase();
            const site = siteKey(hostname);
            const { entry, session, assigned, detour } = this.pick(site, host);
            this.trackConnection(connectionId, site, assigned);
            const tag = { site, host, key: entry.key, session, port: Number(targetPort), detour };
            if (isHttp) this.tags.set(request, tag);
            return { upstreamProxyUrl: entry.urlFor(session), customTag: tag };
          },
        });
        s.on('connectionClosed', ({ connectionId }) => this.conns.delete(connectionId));
        s.on('tunnelConnectFailed', ({ customTag, response }) => customTag && this.onFailure(customTag, response?.statusCode));
        s.on('tunnelConnectResponded', ({ customTag }) => customTag && this.onSuccess(customTag));
        s.on('requestFailed', ({ request }) => {
          const tag = this.tags.get(request);
          if (tag) this.onFailure(tag, undefined);
        });
        return s;
      };
      // With the kill switch the app holds this port until we are about to bind it, so give it a moment to let go.
      const deadline = Date.now() + BIND_RETRY_MS;
      for (;;) {
        server = makeServer();
        try {
          await server.listen();
          break;
        } catch (err) {
          await server.close(true).catch(() => {});
          server = null;
          if (err.code !== 'EADDRINUSE' || Date.now() >= deadline) throw err;
          await sleep(150);
          current();
        }
      }
      current();
      this.server = server;
      this.listenPort = port;
    } catch (err) {
      const superseded = gen !== this.gen;
      if (server) await server.close(true).catch(() => {});
      if (!superseded) {
        this.server = null;
        this.state = 'stopped';
        this.stage = null;
        this.runtime.clear();
        this.entryByKey.clear();
      }
      // stop() has already cleaned up in the superseded case, except for anything it could not see yet (a Tor that came up late).
      if (!superseded || this.state === 'stopped') await stopAllTor(); // a failed start must not leave Tor running
      this.lastError = superseded ? this.lastError : err.code === 'EADDRINUSE' ? `Port ${this.config.port} is already in use` : err.message;
      throw new Error(superseded ? err.message : this.lastError);
    }
    this.timers = [
      setInterval(() => this.reload().catch(() => {}), this.refreshMs),
      setInterval(() => this.healthTick(), HEALTH_MS),
      setInterval(() => this.sweepConnections(), 5000),
    ];
    this.timers.forEach(t => t.unref());
    this.state = 'running';
    this.stage = null;
    const secs = ms => (ms / 1000).toFixed(1);
    this.log('info', `Proxy listening on ${this.host}:${this.listenPort} (rotation: ${this.config.rotation}), ready in ${secs(Date.now() - t0)} s: ` +
      `provider lists ${secs(tLoaded - t0)} s, health check ${secs(tChecked - tLoaded)} s`);
  }

  /**
   * A plain HTTP request names its target twice (the request line and the Host header) and a provider may read the line
   * differently from us. Only an unambiguous absolute target whose Host header agrees with it is forwarded.
   */
  checkAbsoluteTarget(request) {
    const m = /^http:\/\/([^/]*)(\/.*)?$/i.exec(String(request.url));
    if (!m || m[1] === '' || /[?#@\\%\s]/.test(m[1])) throw new RequestError('Malformed request target', 400);
    const bare = h => String(h).toLowerCase().replace(/:\d*$/, '');
    const given = request.headers?.host;
    if (given !== undefined && bare(given) !== bare(m[1])) throw new RequestError('The Host header does not match the request target', 400);
    // proxy-chain reads the URL the way a browser would before it calls us ("010.0.0.1" becomes 8.0.0.1), so the filter must
    // also judge the host exactly as the client wrote it. Otherwise a spelling that other programs read as 10.0.0.1 gets through.
    const written = bare(m[1]);
    if (isInternalHost(written)) {
      this.logOncePerMinute(written.slice(0, 100), 'A local or private address was not sent through the proxy');
      throw new RequestError('Local and private addresses are not sent through the proxy', 403);
    }
  }

  async stop() {
    this.gen++; // a start that is still waiting for something notices and gives up
    this.timers.forEach(clearInterval);
    this.timers = [];
    if (this.server) await this.server.close(true).catch(() => {});
    this.server = null;
    this.listenPort = null;
    this.state = 'stopped';
    this.stage = null;
    await stopAllTor();
    this.sticky.clear();
    for (const m of [this.bad, this.probeFails, this.siteBad, this.siteFails, this.proxyFails, this.blocked, this.lastFailLog, this.conns,
      this.established, this.hostBad, this.hostFails, this.hostBlocked]) m.clear();
    this.runtime.clear();
    this.entryByKey.clear();
    this.logs = []; // the in-memory log holds site names, so it ends with the session
    this.log('info', 'Proxy stopped');
  }

  pick(site, host = site) {
    const now = Date.now();
    const sticky = this.config.rotation === 'sticky';
    let detour = false;
    if (sticky) {
      const s = this.sticky.get(site);
      // Age is checked against the CURRENT sticky time, so changing the setting takes effect at once.
      const entry = s && now - s.assigned < this.stickyMs ? this.entryByKey.get(s.key) : null;
      if (entry && !this.isDead(entry)) {
        if (!this.hostAvoids(host, entry.key)) return { entry, session: s.session, assigned: s.assigned, detour: false };
        detour = true; // this very host name failed on the pinned proxy: use another one for it, and leave the pin alone
      }
    }

    // Choose a provider by its traffic share, then a random healthy proxy inside it. A proxy that
    // refused this very site is avoided, unless the site is blocked everywhere (then rotating is pointless).
    const siteBlocked = (this.blocked.get(site) ?? 0) > now;
    const hostBlocked = (this.hostBlocked.get(host) ?? 0) > now;
    const usable = e => !this.isBad(e) && (siteBlocked || !this.siteBad.has(`${site}|${e.key}`)) && (hostBlocked || !this.hostAvoids(host, e.key));
    const buildGroups = ok => {
      const out = [];
      for (const p of this.config.providers) {
        const rt = this.runtime.get(p.id);
        if (!p.enabled || !rt) continue;
        const entries = rt.entries.filter(ok);
        if (entries.length) out.push({ weight: p.weight, entries });
      }
      return out;
    };
    let groups = buildGroups(usable);
    if (!groups.length) groups = buildGroups(e => !this.isBad(e));
    if (!groups.length) {
      // Last resort: any proxy, but never a Tor whose port nothing of ours owns.
      const all = [...this.entryByKey.values()].filter(e => !this.torGone(e));
      if (!all.length) throw new RequestError('No proxies available', 503);
      groups = [{ weight: 1, entries: all }];
    }
    let r = Math.random() * groups.reduce((n, g) => n + g.weight, 0);
    const group = groups.find(g => (r -= g.weight) < 0) ?? groups[0];
    const entry = group.entries[Math.floor(Math.random() * group.entries.length)];
    const session = sticky && entry.hasSession ? (entry.newSession?.() ?? randomSession()) : null;

    if (sticky && !detour) this.setPin(site, { key: entry.key, session, assigned: now, provider: entry.providerName, label: entry.label, confirmed: false });
    if (this.verbose) this.log('info', `-> ${entry.providerName} ${entry.label}`, site);
    return { entry, session, assigned: sticky && !detour ? now : null, detour };
  }

  /**
   * Stores a pin. A pin is "confirmed" once a tunnel through it has worked. When the table is full the oldest UNCONFIRMED pin
   * goes first, so a page that asks for thousands of made-up host names cannot push out the pins of real sessions.
   */
  setPin(site, pin) {
    if (!this.sticky.has(site) && this.sticky.size >= MAX_STICKY) {
      let victim = null;
      for (const [k, v] of this.sticky) if (!v.confirmed) { victim = k; break; }
      this.sticky.delete(victim ?? this.sticky.keys().next().value);
    }
    this.sticky.set(site, pin);
  }

  hostAvoids(host, key) {
    return (this.hostBad.get(`${host}|${key}`) ?? 0) > Date.now();
  }

  markEstablished(host) {
    this.established.delete(host);
    this.established.set(host, Date.now());
    this.capMaps();
  }

  isEstablished(host) {
    const t = this.established.get(host);
    return t !== undefined && Date.now() - t < ESTABLISHED_TTL_MS;
  }

  /** A tunnel through a proxy worked: the host name is real, and the pin that carried it is no longer just a guess. */
  onSuccess({ site, host = site, key, session, detour }) {
    this.markEstablished(host);
    this.hostBad.delete(`${host}|${key}`);
    const pin = this.sticky.get(site);
    if (pin && pin.key === key) { pin.confirmed = true; return; }
    // The pinned proxy failed for this host but another one worked. If the pin never carried anything, it was only a guess:
    // move the site to the proxy that works. A confirmed pin (a real session) is never moved by one host name.
    const entry = this.entryByKey.get(key);
    if (detour && entry && this.config.rotation === 'sticky' && (!pin || !pin.confirmed)) {
      this.setPin(site, { key, session, assigned: Date.now(), provider: entry.providerName, label: entry.label, confirmed: true });
    }
  }

  trackConnection(connectionId, site, assigned) {
    if (assigned == null || connectionId == null) return; // random mode has no pin to expire
    this.conns.set(connectionId, { site, assigned });
  }

  cutConnections(shouldCut, why) {
    if (!this.server) return 0;
    let n = 0;
    for (const [id, c] of this.conns) {
      if (!shouldCut(c)) continue;
      this.conns.delete(id);
      try { this.server.closeConnection(id); n++; } catch {}
    }
    if (n && this.verbose) this.log('info', `Closed ${n} open connection${n === 1 ? '' : 's'} (${why}); the apps reconnect with a new IP`);
    return n;
  }

  /**
   * An open connection keeps using the proxy it started with, so a browser that keeps its connection alive
   * would never get a new IP. When a site's sticky time is over we close its connections: the client
   * reconnects, and the new connection takes a new proxy.
   */
  sweepConnections() {
    if (!this.config.rotateOpenConnections || this.config.rotation !== 'sticky') return 0;
    const stickyMs = this.stickyMs;
    const now = Date.now();
    return this.cutConnections(c => now - c.assigned >= stickyMs, 'the sticky time ended');
  }

  bench(entry, why) {
    this.bad.set(entry.key, Date.now() + BAD_COOLDOWN_MS);
    this.log('warn', `Proxy ${entry.label} ${why}, benched for ${BAD_COOLDOWN_MS / 60_000} min`);
  }

  logOncePerMinute(site, message) {
    const now = Date.now();
    if (now - (this.lastFailLog.get(site) ?? 0) < 60_000) return;
    this.lastFailLog.set(site, now);
    this.log('warn', message, site);
  }

  onUnknownHostFailure({ site, host, key, entry }, statusCode, now) {
    const what = statusCode ?? 'error';
    this.hostBad.set(`${host}|${key}`, now + HOST_COOLDOWN_MS);
    const refusedBy = this.hostFails.get(host) ?? new Map();
    refusedBy.set(key, now);
    this.hostFails.set(host, refusedBy);
    const n = [...refusedBy.values()].filter(t => now - t < FAIL_WINDOW_MS).length;
    if ((this.hostBlocked.get(host) ?? 0) <= now && n >= GIVE_UP_AFTER_PROXIES) {
      this.hostBlocked.set(host, now + SITE_COOLDOWN_MS);
      this.log('warn', `A host was refused by ${n} different proxies (${what}); it may not exist, or the provider blocks it. Not trying more proxies for it for ${SITE_COOLDOWN_MS / 60_000} min.`, host);
    } else {
      this.logOncePerMinute(host, `${entry.label} refused a host (${what}); trying another proxy next time`);
    }
    const pin = this.sticky.get(site);
    if (pin && pin.key === key && !pin.confirmed) this.sticky.delete(site);
    this.capMaps();
  }

  /**
   * A tunnel through a proxy failed. statusCode is what the proxy answered to our CONNECT, when it did.
   * Most failures are about ONE site (for example the provider blocks stripe.com), and must not take the
   * proxy away from every other site, because that changes the IP of sites that were working fine.
   */
  onFailure({ site, host = site, key, port }, statusCode) {
    // Only ordinary web ports count. Otherwise a web page could request https://example.com:9/ to make the provider refuse
    // the tunnel and so throw away the pinned IP of the visitor's real session with example.com.
    if (port !== undefined && port !== 80 && port !== 443) return;
    const entry = this.entryByKey.get(key);
    if (!entry) return;
    const now = Date.now();

    if (statusCode === 407 || statusCode === 401) {
      // The provider rejected our login. That is about the proxy, not the site.
      if (entry.kind === 'gateway') this.logOncePerMinute(site, `${entry.providerName} rejected the login (${statusCode}). Check the credentials.`);
      else this.bench(entry, `rejected the login (${statusCode})`);
      this.sticky.delete(site);
      return;
    }

    // The same goes for host names: a page can ask for nx.yourbank.example, the provider refuses it, and that must not count
    // against yourbank.example. Only a host name that has worked before can affect its site; one that never worked only gets
    // a short detour of its own, and a pin that never carried anything (just a guess) is forgotten.
    if (!this.isEstablished(host)) {
      this.onUnknownHostFailure({ site, host, key, entry }, statusCode, now);
      return;
    }

    const refusedBy = this.siteFails.get(site) ?? new Map();
    refusedBy.set(key, now);
    this.siteFails.set(site, refusedBy);
    this.siteBad.set(`${site}|${key}`, now + SITE_COOLDOWN_MS);

    const proxiesThatRefused = [...refusedBy.values()].filter(t => now - t < FAIL_WINDOW_MS).length;
    const alreadyBlocked = (this.blocked.get(site) ?? 0) > now;
    const what = statusCode ?? 'error';
    if (!alreadyBlocked && proxiesThatRefused >= GIVE_UP_AFTER_PROXIES) {
      this.blocked.set(site, now + SITE_COOLDOWN_MS);
      this.log('warn', `A site was refused by ${proxiesThatRefused} different proxies (${what}); the provider probably blocks it. Not trying more proxies for it for ${SITE_COOLDOWN_MS / 60_000} min.`, site);
    } else if (!alreadyBlocked) {
      this.logOncePerMinute(site, `${entry.label} refused a site (${what}); trying another proxy next time`);
      this.sticky.delete(site); // a gateway gets a new session, a static proxy list gets another proxy
    }

    // Bench a static proxy only when it fails for several DIFFERENT sites: then the proxy itself is the problem.
    if (entry.kind !== 'gateway') {
      const sites = this.proxyFails.get(key) ?? new Map();
      sites.set(site, now);
      this.proxyFails.set(key, sites);
      const distinct = [...sites].filter(([s, t]) => now - t < FAIL_WINDOW_MS && (this.blocked.get(s) ?? 0) <= now).length;
      if (distinct >= BENCH_AFTER_SITES) this.bench(entry, `failed for ${distinct} different sites`);
    }
  }

  // ---- settings and providers ---------------------------------------------

  persist() {
    saveConfig(this.dir, this.config);
  }

  /** Rotation, sticky time and logging apply at once. The port, network service and refresh time apply the next time the proxy starts. */
  setSettings(input) {
    const next = normalizeSettings(input);
    if (next.rotation !== undefined && next.rotation !== this.config.rotation) {
      this.sticky.clear();
      this.log('info', `Rotation set to ${next.rotation}`);
      this.cutConnections(() => true, 'the rotation mode changed'); // so the new mode applies right away
    }
    Object.assign(this.config, next);
    this.persist();
  }

  async afterProviderChange() {
    if (this.state === 'running') await this.reload().catch(err => this.log('warn', err.message));
  }

  async addProvider(input) {
    if (this.config.providers.length >= MAX_PROVIDERS) throw new Error(`There is a limit of ${MAX_PROVIDERS} providers`);
    const p = normalizeProvider(input);
    this.config.providers.push(p);
    this.persist();
    await this.afterProviderChange();
    return maskProvider(p);
  }

  async updateProvider(id, input) {
    const i = this.config.providers.findIndex(p => p.id === id);
    if (i < 0) throw new Error('Provider not found');
    const old = this.config.providers[i];
    const p = normalizeProvider({ ...input, type: old.type }, old);
    this.config.providers[i] = p;
    const torChanged = p.type === 'tor' && (old.socksPort !== p.socksPort || (old.exitCountries ?? []).join() !== (p.exitCountries ?? []).join());
    // A provider that is turned off, or a Tor that is about to be restarted, must stop receiving traffic right now.
    if (!p.enabled || torChanged) this.dropFromPool(p.id);
    this.persist();
    await this.afterProviderChange();
    return maskProvider(p);
  }

  async deleteProvider(id) {
    const i = this.config.providers.findIndex(p => p.id === id);
    if (i < 0) throw new Error('Provider not found');
    const [removed] = this.config.providers.splice(i, 1);
    this.dropFromPool(removed.id);
    this.persist();
    await this.afterProviderChange();
    if (removed.type === 'tor' && /^[a-z0-9-]{1,40}$/.test(removed.id)) {
      await stopTor(removed.id);
      fs.rmSync(path.join(this.dir, '.tor', removed.id), { recursive: true, force: true }); // its data folder is no longer needed
    }
  }

  /** Tests unsaved form values (or a saved provider when only an id is given). */
  async test(input) {
    const existing = input.id ? this.config.providers.find(p => p.id === input.id) : null;
    const p = normalizeProvider({ ...input, enabled: true }, existing);
    if (this.testing) return { ok: false, error: 'Another test is still running' };
    if (this.state === 'starting') return { ok: false, error: 'Wait for the proxy to finish starting, then test again' };
    if (p.type === 'tor') {
      const sameAsRunning = existing && this.state === 'running' && hasTor(existing.id)
        && existing.socksPort === p.socksPort && (existing.exitCountries ?? []).join() === (p.exitCountries ?? []).join();
      if (this.state === 'running' && !sameAsRunning) {
        // A changed or unsaved Tor needs its own Tor, and it must never replace the one that is carrying traffic.
        if (this.config.providers.some(q => q.type === 'tor' && q.enabled && q.socksPort === p.socksPort)) {
          return { ok: false, error: 'Turn the proxy off to test Tor settings that use the same port as the running one' };
        }
        p.id = 'test';
      } else if (!existing) {
        p.id = 'test'; // unsaved forms share one working folder instead of leaving a new one per test
      }
    }
    this.testing = true;
    const torWasRunning = hasTor(p.id);
    try {
      return await testProvider(p, this.env, this.ctx());
    } catch (err) {
      return { ok: false, error: err.message };
    } finally {
      this.testing = false;
      // A test must not leave Tor running in the background.
      // But not while a start is using it: only the proxy being fully stopped (or the private test instance) allows this.
      if (p.type === 'tor' && !torWasRunning && (this.state === 'stopped' || p.id === 'test')) await stopTor(p.id);
    }
  }

  async exitIp() {
    if (this.state !== 'running') throw new Error('The proxy is not running');
    return fetchIp(`http://127.0.0.1:${this.listenPort}`);
  }

  // ---- snapshot for the UI -------------------------------------------------

  status() {
    const now = Date.now();
    const providers = this.config.providers.map(p => {
      const rt = this.runtime.get(p.id);
      return {
        ...maskProvider(p),
        runtime: {
          status: !p.enabled ? 'disabled' : rt ? rt.status : 'idle',
          error: rt?.error ?? null,
          count: rt?.entries.length ?? 0,
          healthy: rt ? rt.entries.filter(e => !this.isBad(e)).length : 0,
          skipped: rt?.skipped ?? 0,
        },
      };
    });
    const stickyMs = this.stickyMs;
    const sites = [...this.sticky.entries()]
      .filter(([, s]) => now - s.assigned < stickyMs)
      .sort((a, b) => b[1].assigned - a[1].assigned)
      .slice(0, 30)
      .map(([site, s]) => ({ site, provider: s.provider, proxy: s.label, expiresIn: Math.round((s.assigned + stickyMs - now) / 1000) }));
    return {
      state: this.state,
      stage: this.state === 'starting' ? this.stage : null,
      rotation: this.config.rotation,
      stickySeconds: this.config.stickySeconds,
      stickyMinutes: Math.max(1, Math.ceil(this.config.stickySeconds / 60)), // for older apps that only know whole minutes
      port: this.config.port,
      listenPort: this.listenPort,
      refreshMinutes: this.config.refreshMinutes,
      verbose: this.config.verbose,
      rotateOpenConnections: this.config.rotateOpenConnections,
      killSwitch: this.config.killSwitch,
      lastError: this.lastError,
      bypass: MACOS_BYPASS,
      providers,
      sites,
    };
  }
}
