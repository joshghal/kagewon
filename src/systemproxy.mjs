import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// Used only by the helper's watchdog, to put the Mac's proxy settings back when the menu bar app has disappeared (a crash
// or a force-quit). It does what the app does when it turns the proxy off: the manual proxy goes off where it points at us,
// the automatic settings (PAC file, discovery) and the bypass entries are restored from the recovery record
// the app wrote before it changed anything (.system-proxy.json, see menubar/System.swift).
const NETWORKSETUP = '/usr/sbin/networksetup';
const RECORD = '.system-proxy.json';

const makeRun = bin => args => new Promise(resolve => {
  if (process.platform !== 'darwin') return resolve({ ok: false, out: '' });
  execFile(bin, args, { timeout: 5000, env: {} }, (err, out) => {
    const text = String(out ?? '');
    resolve({ ok: !err && !/Error/.test(text), out: text });
  });
});

/** The "Key: value" lines of a networksetup answer, split at the first colon (a PAC address contains colons). */
function fields(text) {
  const out = {};
  for (const line of text.split('\n')) {
    const i = line.indexOf(':');
    if (i < 0) continue;
    const key = line.slice(0, i).trim();
    if (!(key in out)) out[key] = line.slice(i + 1).trim();
  }
  return out;
}

async function listServices(run) {
  const r = await run(['-listallnetworkservices']);
  if (!r.ok) return null;
  return r.out.split('\n').slice(1).map(s => s.replace(/\r$/, '')).filter(s => s && !s.startsWith('*'));
}

/** True if the answer is switched on and names exactly 127.0.0.1 and this port (127.0.0.10 or port 30000 do not match). */
const answerPoints = (text, port) => {
  const f = fields(text);
  return f.Enabled === 'Yes' && f.Server === '127.0.0.1' && Number(f.Port) === port;
};

async function pointsAtUs(run, service, port) {
  for (const verb of ['-getwebproxy', '-getsecurewebproxy']) {
    const r = await run([verb, service]);
    if (r.ok && answerPoints(r.out, port)) return true;
  }
  return false;
}

function readRecord(dir) {
  try {
    const r = JSON.parse(fs.readFileSync(path.join(dir, RECORD), 'utf8'));
    if (r && Number.isInteger(r.port) && r.services && typeof r.services === 'object') return r;
  } catch {}
  return null;
}

const validPac = url => {
  try { return ['http:', 'https:', 'ftp:', 'file:'].includes(new URL(url).protocol); } catch { return false; }
};

/** Puts back what the app saved, but never over a change that someone else made in the meantime. */
async function restoreAutomatic(run, service, saved) {
  const pac = fields((await run(['-getautoproxyurl', service])).out);
  const discovery = fields((await run(['-getproxyautodiscovery', service])).out)['Auto Proxy Discovery'];
  if (pac.Enabled === 'Yes' || discovery === 'On') return; // not as we left it: somebody changed it, so leave it alone
  if (typeof saved.pacURL === 'string' && validPac(saved.pacURL)) await run(['-setautoproxyurl', service, saved.pacURL]); // also switches it on
  await run(['-setautoproxystate', service, saved.pacEnabled ? 'on' : 'off']);
  await run(['-setproxyautodiscovery', service, saved.discovery ? 'on' : 'off']);
}

async function removeAddedBypass(run, service, added) {
  if (!Array.isArray(added) || !added.length) return;
  const r = await run(['-getproxybypassdomains', service]);
  if (!r.ok) return; // unknown is not empty: never write over a list we could not read
  const current = r.out.split('\n').map(s => s.trim()).filter(s => s && !s.startsWith("There aren't"));
  const remaining = current.filter(entry => !added.includes(entry));
  await run(['-setproxybypassdomains', service, ...(remaining.length ? remaining : ['Empty'])]);
}

/**
 * Switches the proxy off on every network that points at our local port (or at the port of an earlier unfinished run,
 * from the record), leaves any other proxy alone, and restores the saved settings. Returns true when nothing points at us
 * any more. The record is kept if that could not be confirmed, so a later try can finish.
 */
export async function disableOurs(port, dir = null, { bin = NETWORKSETUP } = {}) { // `bin` is only replaced by tests
  const run = makeRun(bin);
  const record = dir ? readRecord(dir) : null;
  const ports = new Set([port]);
  if (record) ports.add(record.port);
  const services = await listServices(run);
  if (!services) return false;

  for (const service of services) {
    let ours = false;
    for (const p of ports) if (await pointsAtUs(run, service, p)) ours = true;
    if (ours) {
      await run(['-setwebproxystate', service, 'off']);
      await run(['-setsecurewebproxystate', service, 'off']);
    }
    const saved = record?.services?.[service];
    if (saved && typeof saved === 'object') {
      await restoreAutomatic(run, service, saved);
      await removeAddedBypass(run, service, saved.addedBypass);
    }
  }

  const after = await listServices(run);
  if (!after) return false;
  for (const service of after) for (const p of ports) if (await pointsAtUs(run, service, p)) return false;
  if (dir && record) { try { fs.rmSync(path.join(dir, RECORD), { force: true }); } catch {} }
  return true;
}
