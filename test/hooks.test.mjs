import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tempDir } from './helpers.mjs';

const hooks = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'hooks');
const FAKE = 'FAKEKEY0123456789abcdefghij0123456789';

/** A scratch repository with the repo's hooks installed, a fake saved key, and a bare remote. */
function scratch({ withKey = true } = {}) {
  const dir = tempDir();
  const remote = path.join(dir, 'remote.git');
  const work = path.join(dir, 'work');
  fs.mkdirSync(work);
  const git = (...args) => spawnSync('git', args, { cwd: work, encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' } });
  execFileSync('git', ['init', '-q', '--bare', remote]);
  git('init', '-q', '.');
  git('config', 'user.email', 't@example.com');
  git('config', 'user.name', 't');
  git('config', 'core.hooksPath', hooks);
  git('remote', 'add', 'origin', remote);
  if (withKey) fs.writeFileSync(path.join(work, 'config.json'), JSON.stringify({ providers: [{ type: 'webshare', apiKey: FAKE }] }));
  const write = (name, content) => { fs.mkdirSync(path.dirname(path.join(work, name)), { recursive: true }); fs.writeFileSync(path.join(work, name), content); };
  return { git, write, work };
}

const commit = (s, msg = 'c', ...extra) => s.git('commit', '-q', '-m', msg, ...extra);

test('a clean commit is allowed, and the guard says when it has no key to compare with', () => {
  const s = scratch({ withKey: false });
  s.write('readme.txt', 'hello');
  s.git('add', 'readme.txt');
  const r = commit(s);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /only file names are checked/);
});

test('private files are blocked even when forced in', () => {
  const s = scratch();
  s.git('add', '-f', 'config.json');
  const r = commit(s);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /config\.json is a private file/);
  assert.equal(r.stderr.includes(FAKE), false, 'the key is never printed');
});

test('the saved key is found in text, and in binary files with non-ASCII names', () => {
  const s = scratch();
  s.write('note.txt', `see ${FAKE} here`);
  s.git('add', 'note.txt');
  assert.notEqual(commit(s).status, 0, 'plain text');
  s.git('reset', '-q');

  s.write('données/é.bin', Buffer.concat([Buffer.from([0, 1, 2, 255, 0]), Buffer.from(FAKE), Buffer.from([0, 9])]));
  s.git('add', 'données/é.bin');
  const r = commit(s);
  assert.notEqual(r.status, 0, 'a binary file with a non-ASCII name');
  assert.equal(r.stderr.includes(FAKE), false);
});

test('a push is blocked when a commit holds the key, even if the commit hook was skipped', () => {
  const s = scratch();
  s.write('clean.txt', 'ok');
  s.git('add', 'clean.txt');
  assert.equal(commit(s).status, 0);
  assert.equal(s.git('push', '-q', 'origin', 'HEAD:main').status, 0, 'a clean push is allowed');

  s.write('leak.txt', `key ${FAKE}`);
  s.git('add', 'leak.txt');
  assert.equal(commit(s, 'leak', '--no-verify').status, 0);
  const r = s.git('push', '-q', 'origin', 'HEAD:main');
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /BLOCKED by the secret guard/);
  assert.equal(r.stderr.includes(FAKE), false);

  // and the push of a leaking commit MESSAGE is blocked too
  const t = scratch();
  t.write('a.txt', 'a');
  t.git('add', 'a.txt');
  assert.equal(commit(t, `oops ${FAKE}`, '--no-verify').status, 0);
  assert.notEqual(t.git('push', '-q', 'origin', 'HEAD:main').status, 0);
});
