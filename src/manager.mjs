import net from 'node:net';
import { Server, RequestError } from 'proxy-chain';
import { saveConfig, normalizeProvider, normalizeSettings, maskProvider } from './config.mjs';
import { loadProvider, testProvider, fetchIp, randomSession } from './providers.mjs';
import { siteKey, isInternalHost } from './hosts.mjs';
import { hasTor, pruneTor, stopTor, stopAllTor } from './tor.mjs';

const BAD_COOLDOWN_MS = 5 * 60_000;
const SITE_COOLDOWN_MS = 10 * 60_000; // how long a proxy is avoided for a site that refused it
const FAIL_WINDOW_MS = 2 * 60_000;
const BENCH_AFTER_SITES = 3; // a proxy is benched only when this many DIFFERENT sites fail on it
const GIVE_UP_AFTER_PROXIES = 3; // a site refused by this many different proxies counts as blocked
const HEALTH_MS = 60_000;
const MAX_LOG = 300;

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
    this.host = '127.0.0.1'; // never configurable: the proxy must not be reachable from the network
    this.listenPort = null; // the port actually in use while running

    this.state = 'stopped'; // stopped | starting | running
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
    this.sticky = new Map(); // site -> { key, session, assigned, provider, label }
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

  ctx() {
    return {
      dir: this.dir,
      log: (level, msg) => this.log(level, msg),
      stickyMinutes: () => this.config.stickyMinutes,
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

  /** Should a NEW connection avoid this proxy? One missed health probe is enough. */
  isBad(e) {
    return this.probeFails.has(e.key) || this.isBenched(e);
  }

  /** Should an EXISTING sticky pin be dropped? A single missed probe is common, so it takes two in a row. */
  isDead(e) {
    return (this.probeFails.get(e.key) ?? 0) >= 2 || this.isBenched(e);
  }

  /** Loads one provider. A failure keeps the previous list and schedules the next attempt later and later (1, 2, 4, 8, 15 min). */
  async loadOne(p) {
    const rt = this.rt(p.id);
    try {
      const entries = await loadProvider(p, this.env, this.ctx());
      Object.assign(rt, { entries, status: 'ok', error: null, loadedAt: Date.now(), skipped: entries.skipped ?? 0, failures: 0, retryAt: 0 });
    } catch (err) {
      rt.status = 'error';
      rt.error = err.message;
      rt.failures = (rt.failures ?? 0) + 1;
      rt.retryAt = Date.now() + Math.min(15 * 60_000, 60_000 * 2 ** (rt.failures - 1));
      this.log('warn', `${p.name}: ${err.message}${rt.entries.length ? ' (keeping the previous list)' : ''}`);
    }
  }

  async loadAll() {
    const enabled = this.config.providers.filter(p => p.enabled);
    await Promise.all(enabled.map(p => this.loadOne(p)));
    for (const id of [...this.runtime.keys()]) if (!enabled.some(p => p.id === id)) this.runtime.delete(id);
    await pruneTor(new Set(enabled.filter(p => p.type === 'tor').map(p => p.id)));
    this.rebuildIndex();
  }

  rebuildIndex() {
    this.entryByKey = new Map();
    for (const rt of this.runtime.values()) for (const e of rt.entries) this.entryByKey.set(e.key, e);
  }

  /** Tor died: take it out of the pool, so nothing that later binds its port can receive traffic meant for Tor. */
  torExited(id) {
    const rt = this.runtime.get(id);
    if (!rt) return;
    rt.entries = [];
    rt.status = 'error';
    rt.error = 'Tor stopped unexpectedly. Trying to start it again.';
    this.rebuildIndex();
    for (const [site, s] of this.sticky) if (!this.entryByKey.has(s.key)) this.sticky.delete(site);
  }

  async checkHealth() {
    const failed = new Set();
    await mapLimit([...this.entryByKey.values()], 50, async e => {
      if (!(await tcpAlive(e.host, e.port))) failed.add(e.key);
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
    this.state = 'starting';
    this.lastError = null;
    try {
      if (!this.config.providers.some(p => p.enabled)) {
        throw new Error('No provider is enabled. Add one in the Providers tab.');
      }
      await this.loadAll();
      if (!this.entryByKey.size) throw new Error(this.runtimeErrors() || 'No usable proxies');
      await this.checkHealth();

      const port = this.config.port;
      this.server = new Server({
        host: this.host,
        port,
        prepareRequestFunction: ({ request, hostname, isHttp, connectionId }) => {
          // This Mac and its network are never sent to a provider: it would see the request, and could not reach it.
          if (isInternalHost(hostname)) throw new RequestError('Local and private addresses are not sent through the proxy', 403);
          const site = siteKey(hostname);
          const { entry, session, assigned } = this.pick(site);
          this.trackConnection(connectionId, site, assigned);
          const tag = { site, key: entry.key, session };
          if (isHttp) this.tags.set(request, tag);
          return { upstreamProxyUrl: entry.urlFor(session), customTag: tag };
        },
      });
      this.server.on('connectionClosed', ({ connectionId }) => this.conns.delete(connectionId));
      this.server.on('tunnelConnectFailed', ({ customTag, response }) => customTag && this.onFailure(customTag, response?.statusCode));
      this.server.on('requestFailed', ({ request }) => {
        const tag = this.tags.get(request);
        if (tag) this.onFailure(tag, undefined);
      });
      await this.server.listen();
      this.listenPort = port;
    } catch (err) {
      this.server = null;
      this.state = 'stopped';
      await stopAllTor(); // a failed start must not leave Tor running
      this.runtime.clear();
      this.entryByKey.clear();
      this.lastError = err.code === 'EADDRINUSE' ? `Port ${this.config.port} is already in use` : err.message;
      throw new Error(this.lastError);
    }
    this.timers = [
      setInterval(() => this.reload().catch(() => {}), this.refreshMs),
      setInterval(() => this.healthTick(), HEALTH_MS),
      setInterval(() => this.sweepConnections(), 5000),
    ];
    this.timers.forEach(t => t.unref());
    this.state = 'running';
    this.log('info', `Proxy listening on ${this.host}:${this.listenPort} (rotation: ${this.config.rotation})`);
  }

  async stop() {
    this.timers.forEach(clearInterval);
    this.timers = [];
    if (this.server) await this.server.close(true).catch(() => {});
    this.server = null;
    this.listenPort = null;
    this.state = 'stopped';
    await stopAllTor();
    this.sticky.clear();
    for (const m of [this.bad, this.probeFails, this.siteBad, this.siteFails, this.proxyFails, this.blocked, this.lastFailLog, this.conns]) m.clear();
    this.runtime.clear();
    this.entryByKey.clear();
    this.log('info', 'Proxy stopped');
  }

  pick(site) {
    const now = Date.now();
    const sticky = this.config.rotation === 'sticky';
    if (sticky) {
      const s = this.sticky.get(site);
      // Age is checked against the CURRENT sticky time, so changing the setting takes effect at once.
      const entry = s && now - s.assigned < this.config.stickyMinutes * 60_000 ? this.entryByKey.get(s.key) : null;
      if (entry && !this.isDead(entry)) return { entry, session: s.session, assigned: s.assigned };
    }

    // Choose a provider by its traffic share, then a random healthy proxy inside it. A proxy that
    // refused this very site is avoided, unless the site is blocked everywhere (then rotating is pointless).
    const siteBlocked = (this.blocked.get(site) ?? 0) > now;
    const usable = e => !this.isBad(e) && (siteBlocked || !this.siteBad.has(`${site}|${e.key}`));
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
      const all = [...this.entryByKey.values()];
      if (!all.length) throw new RequestError('No proxies available', 503);
      groups = [{ weight: 1, entries: all }];
    }
    let r = Math.random() * groups.reduce((n, g) => n + g.weight, 0);
    const group = groups.find(g => (r -= g.weight) < 0) ?? groups[0];
    const entry = group.entries[Math.floor(Math.random() * group.entries.length)];
    const session = sticky && entry.hasSession ? (entry.newSession?.() ?? randomSession()) : null;

    if (sticky) {
      this.sticky.set(site, { key: entry.key, session, assigned: now, provider: entry.providerName, label: entry.label });
    }
    if (this.verbose) this.log('info', `-> ${entry.providerName} ${entry.label}`, site);
    return { entry, session, assigned: sticky ? now : null };
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
    const stickyMs = this.config.stickyMinutes * 60_000;
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

  /**
   * A tunnel through a proxy failed. statusCode is what the proxy answered to our CONNECT, when it did.
   * Most failures are about ONE site (for example the provider blocks stripe.com), and must not take the
   * proxy away from every other site, because that changes the IP of sites that were working fine.
   */
  onFailure({ site, key }, statusCode) {
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
    const p = normalizeProvider(input);
    this.config.providers.push(p);
    this.persist();
    await this.afterProviderChange();
    return maskProvider(p);
  }

  async updateProvider(id, input) {
    const i = this.config.providers.findIndex(p => p.id === id);
    if (i < 0) throw new Error('Provider not found');
    const p = normalizeProvider({ ...input, type: this.config.providers[i].type }, this.config.providers[i]);
    this.config.providers[i] = p;
    this.persist();
    await this.afterProviderChange();
    return maskProvider(p);
  }

  async deleteProvider(id) {
    const i = this.config.providers.findIndex(p => p.id === id);
    if (i < 0) throw new Error('Provider not found');
    this.config.providers.splice(i, 1);
    this.persist();
    await this.afterProviderChange();
  }

  /** Tests unsaved form values (or a saved provider when only an id is given). */
  async test(input) {
    const existing = input.id ? this.config.providers.find(p => p.id === input.id) : null;
    const p = normalizeProvider({ ...input, enabled: true }, existing);
    if (this.testing) return { ok: false, error: 'Another test is still running' };
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
      if (p.type === 'tor' && !torWasRunning && (this.state !== 'running' || p.id === 'test')) await stopTor(p.id);
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
    const stickyMs = this.config.stickyMinutes * 60_000;
    const sites = [...this.sticky.entries()]
      .filter(([, s]) => now - s.assigned < stickyMs)
      .sort((a, b) => b[1].assigned - a[1].assigned)
      .slice(0, 30)
      .map(([site, s]) => ({ site, provider: s.provider, proxy: s.label, expiresIn: Math.round((s.assigned + stickyMs - now) / 1000) }));
    return {
      state: this.state,
      rotation: this.config.rotation,
      stickyMinutes: this.config.stickyMinutes,
      port: this.config.port,
      listenPort: this.listenPort,
      refreshMinutes: this.config.refreshMinutes,
      verbose: this.config.verbose,
      rotateOpenConnections: this.config.rotateOpenConnections,
      killSwitch: this.config.killSwitch,
      lastError: this.lastError,
      providers,
      sites,
    };
  }
}
