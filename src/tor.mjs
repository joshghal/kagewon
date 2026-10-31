import { spawn, execFileSync, execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// Starts and stops a private Tor client for a "tor" provider. Nothing runs in the background
// unless the proxy is on: Tor is started with the proxy and stopped with it.

const FALLBACK_PATHS = ['/opt/homebrew/bin/tor', '/usr/local/bin/tor', '/usr/bin/tor'];
const BOOTSTRAP_TIMEOUT_MS = 100_000;
const instances = new Map(); // providerId -> { proc, key, ready, onExit }
const allProcs = new Set(); // every Tor process we started, so none can outlive us
const locks = new Map(); // providerId -> the start or restart that is currently in progress

const settingsKey = p => `${p.socksPort}|${(p.exitCountries ?? []).join(',')}`;

export function findTor() {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean).map(d => path.join(d, 'tor'));
  for (const file of [...dirs, ...FALLBACK_PATHS]) {
    try {
      if (!fs.statSync(file).isFile()) continue;
      fs.accessSync(file, fs.constants.X_OK);
      return file;
    } catch {}
  }
  return null;
}

const quote = s => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

function writeTorrc(p, dataDir) {
  if (/[\r\n]/.test(dataDir)) throw new Error('The folder path contains a line break');
  const lines = [
    `SocksPort 127.0.0.1:${p.socksPort} IsolateSOCKSAuth`, // a different login gets a different circuit (IP)
    `DataDirectory ${quote(dataDir)}`,
    'ClientOnly 1',
    'Log notice stdout',
    'SafeLogging 1',
    'AvoidDiskWrites 1',
  ];
  if (p.exitCountries?.length) {
    lines.push(`ExitNodes ${p.exitCountries.map(c => `{${c.toLowerCase()}}`).join(',')}`, 'StrictNodes 1');
  }
  const file = path.join(dataDir, 'torrc');
  fs.writeFileSync(file, lines.join('\n') + '\n');
  return file;
}

function spawnTor(p, dir, log, onExit) {
  const bin = findTor();
  if (!bin) throw new Error('Tor is not installed. In Terminal run: brew install tor (Homebrew is at brew.sh). See docs/tor.md.');
  const dataDir = path.join(dir, '.tor', p.id);
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  // Tor gets only what it needs: nothing from our environment, such as the control token.
  const env = { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '' };
  const proc = spawn(bin, ['-f', writeTorrc(p, dataDir), '--ignore-missing-torrc'], { stdio: ['ignore', 'pipe', 'pipe'], env });
  allProcs.add(proc);
  proc.once('exit', () => allProcs.delete(proc));
  const pidFile = path.join(dataDir, 'tor.pid');
  try { fs.writeFileSync(pidFile, String(proc.pid), { mode: 0o600 }); } catch {}

  const entry = { proc, key: settingsKey(p), ready: null, onExit };
  entry.ready = new Promise((resolve, reject) => {
    let last = '';
    let milestone = 0;
    let done = false;
    const finish = err => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      err ? reject(err) : resolve();
    };
    const timer = setTimeout(() => {
      finish(new Error(`Tor did not finish starting (${last || 'no output'}). Is the network blocking Tor?`));
      stopTor(p.id);
    }, BOOTSTRAP_TIMEOUT_MS);

    const onData = chunk => {
      for (const line of chunk.toString().split('\n')) {
        const l = line.trim();
        if (!l) continue;
        last = l.replace(/^.*?\[(notice|warn|err)\]\s*/, '');
        const m = l.match(/Bootstrapped (\d+)%/);
        if (m) {
          const pct = Number(m[1]);
          if (pct >= milestone + 25 || pct === 100) { milestone = pct; log('info', `Tor: bootstrapped ${pct}%`); }
          if (pct === 100) finish();
        } else if (/\[(warn|err)\]/.test(l)) {
          log('warn', `Tor: ${last}`);
        }
      }
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
    proc.once('error', err => finish(new Error(`Could not start Tor: ${err.message}`)));
    proc.once('exit', (code, signal) => {
      const unexpected = instances.get(p.id) === entry; // an intentional stop removes the entry first
      if (unexpected) instances.delete(p.id);
      try { fs.rmSync(pidFile, { force: true }); } catch {}
      if (!done) finish(new Error(last || `Tor exited (${signal ?? `code ${code}`})`));
      else if (unexpected) {
        log('warn', 'Tor stopped unexpectedly');
        entry.onExit?.(p.id); // so its entry leaves the pool instead of being served by whatever binds the port next
      }
    });
  });
  // The caller awaits `ready`; this stops an unhandled-rejection warning if nobody does.
  entry.ready.catch(() => {});
  return entry;
}

// Tor's first few streams after startup often switch circuits, which would break a "sticky" session.
// Three throwaway requests with their own login get that instability out of the way. Best effort only.
async function warmUp(port) {
  const once = () => new Promise(resolve => {
    execFile('/usr/bin/curl', ['-q', '-s', '-m', '10', '--socks5-hostname', `warm:x@127.0.0.1:${port}`, 'https://check.torproject.org/api/ip'], { env: {} }, () => resolve());
  });
  for (let i = 0; i < 3; i++) await once();
}

/**
 * Makes sure Tor is running with the provider's settings. Resolves when it has finished bootstrapping.
 * Calls for the same provider run one after another: two overlapping calls used to start two Tor processes
 * and track only one of them.
 */
export function ensureTor(p, dir, log, onExit) {
  const run = (locks.get(p.id) ?? Promise.resolve()).catch(() => {}).then(() => ensureTorNow(p, dir, log, onExit));
  locks.set(p.id, run);
  run.then(() => {}, () => {}).then(() => { if (locks.get(p.id) === run) locks.delete(p.id); });
  return run;
}

async function ensureTorNow(p, dir, log, onExit) {
  let entry = instances.get(p.id);
  let fresh = false;
  if (entry && entry.key !== settingsKey(p)) { await stopTor(p.id); entry = null; }
  if (!entry) {
    fresh = true;
    entry = spawnTor(p, dir, log, onExit);
    instances.set(p.id, entry);
    log('info', `Starting Tor on 127.0.0.1:${p.socksPort}...`);
  }
  try {
    await entry.ready;
  } catch (err) {
    await stopTor(p.id);
    throw err;
  }
  if (fresh) await warmUp(p.socksPort);
}

export const hasTor = id => instances.has(id);

export function stopTor(id) {
  const entry = instances.get(id);
  if (!entry) return Promise.resolve();
  instances.delete(id);
  return new Promise(resolve => {
    const kill = setTimeout(() => entry.proc.kill('SIGKILL'), 3000);
    entry.proc.once('exit', () => { clearTimeout(kill); resolve(); });
    if (!entry.proc.kill('SIGTERM')) { clearTimeout(kill); resolve(); }
  });
}

export const stopAllTor = () => Promise.all([...instances.keys()].map(stopTor));

/** Stops Tor for providers that are no longer enabled. */
export const pruneTor = keepIds => Promise.all([...instances.keys()].filter(id => !keepIds.has(id)).map(stopTor));

/** Synchronous last-resort cleanup when the process exits. */
export function killAllTorNow() {
  for (const proc of allProcs) proc.kill('SIGKILL');
}

/**
 * Stops Tor processes left over by a helper that was force-killed. Each one is found by the pid file we wrote,
 * and only killed if that pid is still a tor started from our own torrc (pids get reused).
 */
const sleepSync = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const isAlive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };

/**
 * Stops a Tor that a crashed helper left behind. It waits until that process is really gone (and forces it after a grace
 * period), because a new Tor that starts while the old one still holds the data folder and the port fails to start.
 * This runs before the control interface handles any request, so nothing can start Tor in the meantime.
 */
export function cleanupStaleTor(dir, graceMs = 3000) {
  const root = path.join(dir, '.tor');
  let names;
  try { names = fs.readdirSync(root); } catch { return; }
  for (const name of names) {
    const pidFile = path.join(root, name, 'tor.pid');
    let pid;
    try { pid = Number(fs.readFileSync(pidFile, 'utf8')); } catch { continue; }
    try {
      const cmd = execFileSync('/bin/ps', ['-o', 'command=', '-p', String(pid)], { encoding: 'utf8', timeout: 3000, env: {} });
      if (Number.isInteger(pid) && pid > 1 && /(^|\/)tor\s/.test(cmd) && cmd.includes(path.join(root, name, 'torrc'))) {
        process.kill(pid, 'SIGTERM');
        for (let waited = 0; waited < graceMs && isAlive(pid); waited += 50) sleepSync(50);
        if (isAlive(pid)) {
          process.kill(pid, 'SIGKILL');
          for (let waited = 0; waited < 1000 && isAlive(pid); waited += 50) sleepSync(50);
        }
      }
    } catch {}
    try { fs.rmSync(pidFile, { force: true }); } catch {}
  }
}
