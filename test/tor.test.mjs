import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { ensureTor, stopAllTor, hasTor } from '../src/tor.mjs';
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
