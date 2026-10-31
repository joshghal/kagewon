import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { ensureTor, stopAllTor, hasTor, cleanupStaleTor } from '../src/tor.mjs';
import { tempDir } from './helpers.mjs';

const running = marker => {
  try { return execFileSync('pgrep', ['-f', marker], { encoding: 'utf8' }).trim().split('\n').filter(Boolean).length; } catch { return 0; }
};

test('overlapping starts for one provider leave exactly one Tor process, and stopping removes it', async () => {
  // a stand-in for tor: reports that it has bootstrapped, then waits
  const bin = tempDir();
  fs.writeFileSync(path.join(bin, 'tor'), '#!/bin/sh\necho "[notice] Bootstrapped 100% (done): Done"\nsleep 60 &\ntrap \'kill $! 2>/dev/null; exit 0\' TERM INT\nwait\n', { mode: 0o755 });
  const dir = tempDir();
  const originalPath = process.env.PATH;
  process.env.PATH = `${bin}:${originalPath}`;
  try {
    // the same provider id twice, with different ports: this used to start two processes and track one
    const results = await Promise.allSettled([
      ensureTor({ id: 'tor-a', socksPort: 9461, exitCountries: [] }, dir, () => {}),
      ensureTor({ id: 'tor-a', socksPort: 9462, exitCountries: [] }, dir, () => {}),
    ]);
    assert.ok(results.every(r => r.status === 'fulfilled'), JSON.stringify(results));
    assert.equal(hasTor('tor-a'), true);
    assert.equal(running(path.join(dir, '.tor')), 1, 'exactly one Tor process');

    await stopAllTor();
    assert.equal(hasTor('tor-a'), false);
    await new Promise(r => setTimeout(r, 300));
    assert.equal(running(path.join(dir, '.tor')), 0, 'nothing is left running');
  } finally {
    process.env.PATH = originalPath;
    await stopAllTor();
  }
});

const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };

/** A stand-in for a Tor left behind by a crashed helper: found by its command line and pid file, slow to stop. */
function leftBehind(dir, behaviour) {
  const bin = tempDir();
  fs.writeFileSync(path.join(bin, 'tor'), `#!/bin/sh\n${behaviour}\nwhile true; do sleep 0.1; done\n`, { mode: 0o755 });
  const folder = path.join(dir, '.tor', 'tor-old');
  fs.mkdirSync(folder, { recursive: true });
  const torrc = path.join(folder, 'torrc');
  fs.writeFileSync(torrc, '');
  // started from a short-lived shell, so that (as with a real orphan) launchd owns it and cleans up the moment it exits
  const out = spawnSync('/bin/sh', ['-c', `"${path.join(bin, 'tor')}" -f "${torrc}" </dev/null >/dev/null 2>&1 & echo $!`], { encoding: 'utf8' });
  const pid = Number(out.stdout.trim());
  fs.writeFileSync(path.join(folder, 'tor.pid'), String(pid));
  return pid;
}

test('a Tor left behind by a crash is gone when the cleanup returns, even if it is slow to stop', async () => {
  const dir = tempDir();
  const pid = leftBehind(dir, "trap 'sleep 1; exit 0' TERM");
  await new Promise(r => setTimeout(r, 300));
  assert.equal(alive(pid), true);
  cleanupStaleTor(dir);
  assert.equal(alive(pid), false, 'the old Tor must be gone before a new one can start');
  assert.equal(fs.existsSync(path.join(dir, '.tor', 'tor-old', 'tor.pid')), false);
});

test('a Tor that ignores the polite request is forced to stop after the grace period', async () => {
  const dir = tempDir();
  const pid = leftBehind(dir, "trap '' TERM");
  await new Promise(r => setTimeout(r, 300));
  cleanupStaleTor(dir, 400);
  assert.equal(alive(pid), false);
});

test('an unrelated process that reuses the pid is not touched', async () => {
  const dir = tempDir();
  const folder = path.join(dir, '.tor', 'tor-old');
  fs.mkdirSync(folder, { recursive: true });
  const bystander = spawn('sleep', ['30'], { stdio: 'ignore' });
  fs.writeFileSync(path.join(folder, 'tor.pid'), String(bystander.pid));
  try {
    cleanupStaleTor(dir);
    assert.equal(alive(bystander.pid), true, 'a process whose command line is not our Tor must survive');
  } finally { bystander.kill('SIGKILL'); }
});
