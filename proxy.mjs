import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './src/config.mjs';
import { Manager } from './src/manager.mjs';
import { startControl } from './src/control.mjs';
import { cleanupStaleTor, killAllTorNow } from './src/tor.mjs';
import { disableOurs } from './src/systemproxy.mjs';

// There is no .env file: providers and settings are managed in the menu bar app and saved in config.json.
// These variables are only for the app and for development, never required from a user.
const env = process.env;
const dir = path.dirname(fileURLToPath(import.meta.url));
const CONTROL_PORT = Number(env.CONTROL_PORT) || 8889;
// The menu bar app sets AUTOSTART=false and starts/stops the proxy through the control API.
const AUTOSTART = env.AUTOSTART !== 'false';
const token = env.CONTROL_TOKEN || crypto.randomBytes(16).toString('hex');

// The menu bar app reads our output through a pipe. If the app is force-killed, writing to that closed pipe raises
// an error, and without these handlers it would crash us before the watchdog below has switched the Mac's proxy off.
process.stdout.on('error', () => {});
process.stderr.on('error', () => {});

const PARENT_PID = process.ppid; // read before anything slow, or a parent that dies early would go unnoticed
const config = loadConfig(dir);
const manager = new Manager({ dir, config, env });

let control;
try {
  control = await startControl({ manager, host: '127.0.0.1', port: CONTROL_PORT, token });
} catch (err) {
  console.error(err.code === 'EADDRINUSE' ? `Control port ${CONTROL_PORT} is already in use (is the menu bar app or another copy running?)` : err.message);
  process.exit(1);
}
console.log(`Control API listening on 127.0.0.1:${CONTROL_PORT}`);

// Only now do we know no other helper owns this folder, so leftovers from a force-killed run are safe to clean up.
cleanupStaleTor(dir);
process.on('exit', killAllTorNow);

// The app uses this file to find a helper that survived a crash. It is checked against the command line before use.
const pidFile = path.join(dir, '.helper.pid');
try { fs.writeFileSync(pidFile, String(process.pid), { mode: 0o600 }); } catch {}
process.on('exit', () => { try { fs.rmSync(pidFile, { force: true }); } catch {} });

if (AUTOSTART) {
  try {
    await manager.start();
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}

async function shutdown() {
  await manager.stop();
  control.close();
  process.exit(0);
}
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, shutdown);

// If the menu bar app that started us disappears (a crash or a force-quit), do not keep a proxy running and do not
// leave the Mac pointing at it. With the kill switch on, the proxy settings stay so that nothing can leak.
if (!AUTOSTART) {
  let leaving = false;
  const appGone = async () => {
    if (leaving) return;
    leaving = true;
    console.log('The app is gone; shutting down');
    const port = manager.listenPort ?? config.port;
    try {
      // First, because the Mac must not keep pointing at a proxy that is about to close.
      if (!config.killSwitch) await disableOurs(port);
    } finally {
      await manager.stop().catch(() => {});
      control.close();
      if (config.killSwitch) {
        // The Mac keeps pointing at this port, so another program must not be able to take it over. Hold it, and refuse
        // every connection, until the app starts again (it stops this helper and clears the settings).
        const holder = net.createServer(socket => socket.destroy());
        holder.once('error', () => process.exit(0));
        holder.listen(port, '127.0.0.1');
      } else {
        process.exit(0);
      }
    }
  };
  if (PARENT_PID === 1) appGone(); // the app was already gone before we got this far
  setInterval(() => { if (process.ppid !== PARENT_PID) appGone(); }, 1000).unref();
}
