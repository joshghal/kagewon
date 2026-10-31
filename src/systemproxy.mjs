import { execFile } from 'node:child_process';

// Used only by the helper's watchdog, to switch the Mac's proxy off when the menu bar app has disappeared.
const NETWORKSETUP = '/usr/sbin/networksetup';

const run = args => new Promise(resolve => {
  if (process.platform !== 'darwin') return resolve('');
  execFile(NETWORKSETUP, args, { timeout: 5000, env: {} }, (err, out) => resolve(err ? '' : String(out)));
});

async function services() {
  return (await run(['-listallnetworkservices'])).split('\n').slice(1).map(s => s.trim()).filter(s => s && !s.startsWith('*'));
}

async function pointsAtUs(service, port) {
  for (const verb of ['-getwebproxy', '-getsecurewebproxy']) {
    const out = await run([verb, service]);
    if (/Enabled: Yes/.test(out) && /Server: 127\.0\.0\.1/.test(out) && new RegExp(`Port: ${port}\\b`).test(out)) return true;
  }
  return false;
}

/** Switches the proxy off on every network that points at our local port, and leaves any other proxy alone. */
export async function disableOurs(port) {
  for (const service of await services()) {
    if (!(await pointsAtUs(service, port))) continue;
    await run(['-setwebproxystate', service, 'off']);
    await run(['-setsecurewebproxystate', service, 'off']);
  }
}
