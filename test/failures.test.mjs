import test from 'node:test';
import assert from 'node:assert/strict';
import { manager } from './helpers.mjs';

test('a site the provider blocks does not bench the proxy or move other sites (the stripe.com bug)', () => {
  const m = manager();
  m.pick('example.com');
  const pinned = m.sticky.get('example.com');
  m.sticky.set('other.com', { ...pinned }); // another site pinned to the very same proxy

  m.onFailure({ site: 'stripe.com', key: pinned.key }, 403);

  assert.equal(m.isBenched(m.entryByKey.get(pinned.key)), false);
  assert.equal(m.pick('example.com').entry.key, pinned.key, 'example.com keeps its IP');
  assert.equal(m.pick('other.com').entry.key, pinned.key, 'other.com keeps its IP');
});

test('a proxy that refused a site is not picked again for that site', () => {
  const m = manager();
  m.onFailure({ site: 'stripe.com', key: 'k0' }, 403);
  for (let i = 0; i < 300; i++) {
    m.sticky.delete('stripe.com');
    assert.notEqual(m.pick('stripe.com').entry.key, 'k0');
  }
  // ...but it is still fine for everyone else
  const others = new Set();
  for (let i = 0; i < 300; i++) { m.sticky.delete('example.com'); others.add(m.pick('example.com').entry.key); }
  assert.ok(others.has('k0'));
});

test('a site refused by 3 different proxies counts as blocked: stop rotating and stop benching', () => {
  const m = manager();
  const first = m.pick('stripe.com').entry.key;
  for (const k of ['k1', 'k2', 'k3']) m.onFailure({ site: 'stripe.com', key: k }, 403);
  assert.ok(m.blocked.has('stripe.com'));
  for (const k of ['k1', 'k2', 'k3']) assert.equal(m.isBenched(m.entryByKey.get(k)), false);

  // after giving up, a failure no longer throws the pin away
  const keep = m.pick('stripe.com').entry.key;
  m.onFailure({ site: 'stripe.com', key: keep }, 403);
  assert.equal(m.pick('stripe.com').entry.key, keep);
  assert.ok(first);
});

test('a proxy that fails for several DIFFERENT sites is benched', () => {
  const m = manager();
  m.onFailure({ site: 'a.com', key: 'k5' }, 502);
  m.onFailure({ site: 'b.com', key: 'k5' }, 502);
  assert.equal(m.isBenched(m.entryByKey.get('k5')), false);
  m.onFailure({ site: 'c.com', key: 'k5' }, 502);
  assert.equal(m.isBenched(m.entryByKey.get('k5')), true);
});

test('a rejected login (407) benches the proxy at once', () => {
  const m = manager();
  m.onFailure({ site: 'a.com', key: 'k7' }, 407);
  assert.equal(m.isBenched(m.entryByKey.get('k7')), true);
});

test('one missed health probe keeps existing pins, but new connections already avoid the proxy', () => {
  const m = manager();
  const key = m.pick('a.com').entry.key;
  m.probeFails.set(key, 1); // one missed probe
  assert.equal(m.pick('a.com').entry.key, key, 'the pin survives a single missed probe');
  for (let i = 0; i < 300; i++) { m.sticky.delete('b.com'); assert.notEqual(m.pick('b.com').entry.key, key); }

  m.probeFails.set(key, 2); // two in a row: really down
  assert.notEqual(m.pick('a.com').entry.key, key, 'the pin is dropped after two missed probes');
});

test('a gateway that fails for a site gets a new session and is never benched', () => {
  const m = manager(1, 'gateway');
  const first = m.pick('a.com');
  assert.equal(first.session, 'sess');
  m.onFailure({ site: 'a.com', key: 'k0' }, 502);
  assert.equal(m.sticky.has('a.com'), false, 'the pin is cleared so the next connection takes a new session');
  assert.equal(m.isBenched(m.entryByKey.get('k0')), false);
  assert.ok(m.pick('a.com').entry, 'still usable');
});

test('old failure records are cleaned up', () => {
  const m = manager();
  m.onFailure({ site: 'stripe.com', key: 'k1' }, 403);
  assert.ok(m.siteBad.size > 0);
  for (const [k] of m.siteBad) m.siteBad.set(k, Date.now() - 1);
  for (const inner of m.siteFails.values()) for (const k of inner.keys()) inner.set(k, Date.now() - 10 * 60_000);
  m.prune();
  assert.equal(m.siteBad.size, 0);
  assert.equal(m.siteFails.size, 0);
});

test('a failure on an unusual port does not touch the pinned IP of the real site', () => {
  const m = manager();
  const key = m.pick('bank.com').entry.key;
  const pin = m.sticky.get('bank.com');
  for (const port of [9, 22, 8080, 4443]) m.onFailure({ site: 'bank.com', key, port }, 403);
  assert.equal(m.sticky.get('bank.com'), pin, 'the pin survives requests to other ports');
  assert.equal(m.siteBad.size, 0);
  m.onFailure({ site: 'bank.com', key, port: 443 }, 403);
  assert.equal(m.sticky.has('bank.com'), false, 'a real failure on port 443 is still handled');
});
