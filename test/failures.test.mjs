import test from 'node:test';
import assert from 'node:assert/strict';
import { manager } from './helpers.mjs';

/** Host names that have worked before: only those are allowed to affect a site's pin or a proxy's standing. */
const known = (m, ...hosts) => hosts.forEach(h => m.markEstablished(h));

test('a site the provider blocks does not bench the proxy or move other sites (the stripe.com bug)', () => {
  const m = manager();
  known(m, 'stripe.com');
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
  known(m, 'stripe.com');
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
  known(m, 'stripe.com');
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
  known(m, 'a.com', 'b.com', 'c.com');
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
  known(m, 'a.com');
  const first = m.pick('a.com');
  assert.equal(first.session, 'sess');
  m.onFailure({ site: 'a.com', key: 'k0' }, 502);
  assert.equal(m.sticky.has('a.com'), false, 'the pin is cleared so the next connection takes a new session');
  assert.equal(m.isBenched(m.entryByKey.get('k0')), false);
  assert.ok(m.pick('a.com').entry, 'still usable');
});

test('old failure records are cleaned up', () => {
  const m = manager();
  known(m, 'stripe.com');
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
  known(m, 'bank.com');
  const key = m.pick('bank.com').entry.key;
  const pin = m.sticky.get('bank.com');
  for (const port of [9, 22, 8080, 4443]) m.onFailure({ site: 'bank.com', key, port }, 403);
  assert.equal(m.sticky.get('bank.com'), pin, 'the pin survives requests to other ports');
  assert.equal(m.siteBad.size, 0);
  m.onFailure({ site: 'bank.com', key, port: 443 }, 403);
  assert.equal(m.sticky.has('bank.com'), false, 'a real failure on port 443 is still handled');
});

// ---- host names that never worked (the audit finding: a web page could reset the IP of a real session) -----------------

/** A real session: the site is pinned to a proxy and a tunnel through it has worked. */
function realSession(m, site = 'bank.com', host = `www.${site}`) {
  const { entry, session, detour } = m.pick(site, host);
  m.onSuccess({ site, host, key: entry.key, session, detour });
  return { key: entry.key, pin: m.sticky.get(site) };
}

test('made-up host names of a real site cannot move its pinned IP, bench proxies or block the site', () => {
  const m = manager(20);
  const { key, pin } = realSession(m);
  assert.equal(pin.confirmed, true);
  for (let i = 0; i < 300; i++) {
    for (const k of [key, `k${i % 20}`]) m.onFailure({ site: 'bank.com', host: `nx${i}.bank.com`, key: k, port: 443 }, 502);
  }
  assert.equal(m.sticky.get('bank.com'), pin, 'the pin is untouched');
  assert.equal(m.pick('bank.com', 'www.bank.com').entry.key, key, 'the real host keeps its IP');
  assert.equal(m.bad.size, 0, 'no proxy was benched');
  assert.equal(m.blocked.size, 0, 'the site was not marked blocked');
  assert.equal(m.siteBad.size, 0);
  assert.equal(m.proxyFails.size, 0);
});

test('a host name that failed on the pinned proxy takes another proxy for itself, and the pin stays', () => {
  const m = manager(20);
  const { key, pin } = realSession(m);
  m.onFailure({ site: 'bank.com', host: 'nx.bank.com', key, port: 443 }, 502);
  for (let i = 0; i < 50; i++) {
    const r = m.pick('bank.com', 'nx.bank.com');
    assert.equal(r.detour, true);
    assert.notEqual(r.entry.key, key);
    assert.equal(r.assigned, null, 'a detour has no pin to expire');
  }
  assert.equal(m.sticky.get('bank.com'), pin);
  assert.equal(m.pick('bank.com', 'www.bank.com').entry.key, key, 'other host names of the site still use the pin');
});

test('a host name refused by several proxies is not retried on every proxy for ten minutes', () => {
  const m = manager(20);
  for (const k of ['k1', 'k2', 'k3']) m.onFailure({ site: 'a.com', host: 'nx.a.com', key: k, port: 443 }, 502);
  assert.ok(m.hostBlocked.has('nx.a.com'));
  assert.equal(m.blocked.size, 0, 'only the host name is blocked, not the site');
});

test('a pin that never carried a working request is only a guess and is dropped when its first host fails', () => {
  const m = manager(20);
  const first = m.pick('new.com', 'www.new.com');
  assert.equal(m.sticky.get('new.com').confirmed, false);
  m.onFailure({ site: 'new.com', host: 'www.new.com', key: first.entry.key, port: 443 }, 403);
  assert.equal(m.sticky.has('new.com'), false);

  // and a detour that works moves the guess to the proxy that works
  const again = m.pick('new.com', 'www.new.com');
  m.onFailure({ site: 'new.com', host: 'www.new.com', key: again.entry.key, port: 443 }, 403);
  const third = m.pick('new.com', 'www.new.com');
  m.onSuccess({ site: 'new.com', host: 'www.new.com', key: third.entry.key, session: third.session, detour: third.detour });
  assert.equal(m.sticky.get('new.com').key, third.entry.key);
  assert.equal(m.sticky.get('new.com').confirmed, true);
  assert.equal(m.isEstablished('www.new.com'), true);
});

test('thousands of made-up sites cannot push the pins of real sessions out of the table', () => {
  const m = manager(20);
  const { pin } = realSession(m);
  for (let i = 0; i < 6000; i++) m.pick(`junk${i}.example`, `junk${i}.example`);
  assert.ok(m.sticky.size <= 5000);
  assert.equal(m.sticky.get('bank.com'), pin, 'the confirmed pin survived the flood');
});

test('a host name that has worked is judged like before: its failure counts for its site', () => {
  const m = manager(20);
  const { key } = realSession(m, 'shop.com', 'www.shop.com');
  m.onFailure({ site: 'shop.com', host: 'www.shop.com', key, port: 443 }, 502);
  assert.equal(m.sticky.has('shop.com'), false, 'its pin is dropped');
  assert.ok(m.siteBad.has(`shop.com|${key}`));
});
