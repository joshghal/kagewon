import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { normalizeProvider, normalizeSettings, maskProvider, loadConfig, saveConfig, configPath } from '../src/config.mjs';
import { tempDir } from './helpers.mjs';

const KEY = 'abcdefghij0123456789WXYZ'; // 24 characters

test('secrets are masked for the UI and kept when an edit leaves them empty', () => {
  const p = normalizeProvider({ type: 'webshare', apiKey: KEY });
  assert.equal(maskProvider(p).apiKey, '••••WXYZ');
  assert.equal(normalizeProvider({ type: 'webshare', apiKey: '' }, p).apiKey, KEY);
  assert.equal(normalizeProvider({ type: 'webshare', apiKey: maskProvider(p).apiKey }, p).apiKey, KEY);
});

test('a short secret is not partly revealed', () => {
  const p = normalizeProvider({ type: 'webshare', apiKey: 'shortkey12' });
  assert.equal(maskProvider(p).apiKey, '••••');
});

test('only Webshare and Tor exist, and each needs its required fields', () => {
  assert.throws(() => normalizeProvider({ type: 'webshare' }), /API key/);
  assert.throws(() => normalizeProvider({ type: 'tor', socksPort: 80 }), /1024/);
  for (const type of ['list', 'gateway', 'decodo', 'iproyal', 'brightdata', 'proxyscrape', 'proxysio', 'nope']) {
    assert.throws(() => normalizeProvider({ type }), /Unknown provider type/, type);
  }
});

test('an id supplied by the caller is never used', () => {
  const p = normalizeProvider({ type: 'tor', id: '../../etc/x\nSocksPort 1' });
  assert.match(p.id, /^tor-[0-9a-f]{6}$/);
});

test('there is no way to choose which program is run as Tor', () => {
  const p = normalizeProvider({ type: 'tor', binary: '/bin/sh' });
  assert.equal('binary' in p, false);
});

test('settings are validated and partial updates only return what was sent', () => {
  assert.deepEqual(normalizeSettings({ rotation: 'random' }), { rotation: 'random' });
  assert.deepEqual(normalizeSettings({ port: 9000, verbose: true, killSwitch: true }), { port: 9000, verbose: true, killSwitch: true });
  assert.throws(() => normalizeSettings({ rotation: 'banana' }), /Rotation/);
  assert.throws(() => normalizeSettings({ port: 80 }), /port/);
  assert.throws(() => normalizeSettings({ stickyMinutes: 0 }), /Sticky/);
  assert.equal('networkService' in normalizeSettings({ networkService: '-x' }), false);
});

test('loading config.json keeps valid providers and drops invalid or dangerous ones', () => {
  const dir = tempDir();
  fs.writeFileSync(configPath(dir), JSON.stringify({
    port: 9001,
    providers: [
      { id: 'webshare-1', type: 'webshare', apiKey: KEY, enabled: true },
      { id: 'x', type: 'decodo', username: 'a', password: 'b' }, // a type that no longer exists
      { id: 'tor-a\nSocksPort 9', type: 'tor', socksPort: 9250 }, // an id that would inject into the torrc
      { id: 'webshare-1', type: 'webshare', apiKey: KEY }, // a duplicate id
      { type: 'tor', socksPort: 80 }, // invalid port
      'not an object',
    ],
  }));
  const cfg = loadConfig(dir);
  assert.equal(cfg.port, 9001);
  assert.equal(cfg.providers.length, 3, 'the dropped ones are gone');
  const ids = cfg.providers.map(p => p.id);
  assert.equal(new Set(ids).size, ids.length, 'ids are unique');
  for (const id of ids) assert.match(id, /^[a-z0-9-]{1,40}$/);
  assert.ok(ids.includes('webshare-1'));
});

test('the config file is private and no temporary file is left behind', () => {
  const dir = tempDir();
  fs.writeFileSync(`${configPath(dir)}.${process.pid}.tmp`, 'stale', { mode: 0o644 }); // a leftover with loose permissions
  saveConfig(dir, { version: 1, providers: [] });
  assert.equal(fs.statSync(configPath(dir)).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(dir).filter(n => n.endsWith('.tmp')), []);
});

test('an unreadable config is set aside, and only the newest backups are kept', () => {
  const dir = tempDir();
  for (let i = 1; i <= 5; i++) fs.writeFileSync(path.join(dir, `config.json.broken-${1000 + i}`), 'old');
  fs.writeFileSync(configPath(dir), '{ not json');
  const cfg = loadConfig(dir);
  assert.deepEqual(cfg.providers, []);
  const backups = fs.readdirSync(dir).filter(n => n.startsWith('config.json.broken-'));
  assert.equal(backups.length, 3);
});

test('when providers are dropped on load, the original file is kept as a private backup', () => {
  const dir = tempDir();
  fs.writeFileSync(configPath(dir), JSON.stringify({ providers: [{ id: 'webshare-1', type: 'webshare', apiKey: KEY }, { id: 'x', type: 'gateway', host: 'h' }] }));
  const cfg = loadConfig(dir);
  assert.equal(cfg.providers.length, 1);
  const backups = fs.readdirSync(dir).filter(n => n.startsWith('config.json.broken-'));
  assert.equal(backups.length, 1);
  assert.equal(fs.statSync(path.join(dir, backups[0])).mode & 0o777, 0o600);
  assert.match(fs.readFileSync(path.join(dir, backups[0]), 'utf8'), /gateway/, 'the dropped provider is still in the backup');
});

test('the id "test" is reserved for unsaved tests and never given to a stored provider', () => {
  const dir = tempDir();
  fs.writeFileSync(configPath(dir), JSON.stringify({ providers: [{ id: 'test', type: 'tor', socksPort: 9250 }] }));
  const [p] = loadConfig(dir).providers;
  assert.notEqual(p.id, 'test');
});
