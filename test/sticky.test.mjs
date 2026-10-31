import test from 'node:test';
import assert from 'node:assert/strict';
import { manager } from './helpers.mjs';

test('a site keeps its proxy while the sticky time has not passed', () => {
  const m = manager();
  const first = m.pick('example.com').entry.key;
  for (let i = 0; i < 20; i++) assert.equal(m.pick('example.com').entry.key, first);
});

test('lowering the sticky time applies to sites that were already pinned', () => {
  const m = manager();
  m.config.stickyMinutes = 10;
  m.pick('example.com');
  const pinned = m.sticky.get('example.com');
  pinned.assigned -= 3 * 60_000; // pinned 3 minutes ago, under the old 10 minute setting

  m.pick('example.com');
  assert.equal(m.sticky.get('example.com'), pinned, 'still inside the 10 minute window');

  m.config.stickyMinutes = 1; // the user lowers it to 1 minute
  m.pick('example.com');
  assert.notEqual(m.sticky.get('example.com'), pinned, 'a new pick must replace the expired one');
  assert.ok(Date.now() - m.sticky.get('example.com').assigned < 1000);
});

test('the Activity list shows the time left under the current setting', () => {
  const m = manager();
  m.config.stickyMinutes = 10;
  m.pick('example.com');
  m.sticky.get('example.com').assigned -= 4 * 60_000;
  const left = m.status().sites[0].expiresIn;
  assert.ok(left > 5 * 60 - 5 && left <= 6 * 60, `expected about 6 minutes left, got ${left}s`);
  m.config.stickyMinutes = 3; // already older than that, so it drops off the list
  assert.equal(m.status().sites.length, 0);
});

test('open connections are closed when their sticky time ends, so the client reconnects with a new IP', () => {
  const m = manager();
  m.config.stickyMinutes = 1;
  const closed = [];
  m.server = { closeConnection: id => closed.push(id) };
  const now = Date.now();
  m.trackConnection(1, 'a.com', now - 61_000); // pinned 61 s ago: expired
  m.trackConnection(2, 'b.com', now - 10_000); // pinned 10 s ago: still fresh
  m.trackConnection(3, 'c.com', null); // random mode: nothing to expire
  m.sweepConnections();
  assert.deepEqual(closed, [1]);
  assert.equal(m.conns.has(1), false);
  assert.equal(m.conns.has(2), true);
  assert.equal(m.conns.has(3), false);
});

test('lowering the sticky time also applies to connections that are already open', () => {
  const m = manager();
  m.config.stickyMinutes = 10;
  const closed = [];
  m.server = { closeConnection: id => closed.push(id) };
  m.trackConnection(1, 'a.com', Date.now() - 3 * 60_000);
  m.sweepConnections();
  assert.deepEqual(closed, [], '3 minutes old is fine under a 10 minute setting');
  m.config.stickyMinutes = 1;
  m.sweepConnections();
  assert.deepEqual(closed, [1]);
});

test('open connections are left alone when the setting is off or rotation is random', () => {
  const m = manager();
  m.config.stickyMinutes = 1;
  const closed = [];
  m.server = { closeConnection: id => closed.push(id) };
  m.trackConnection(1, 'a.com', Date.now() - 5 * 60_000);
  m.config.rotateOpenConnections = false;
  m.sweepConnections();
  m.config.rotateOpenConnections = true;
  m.config.rotation = 'random';
  m.sweepConnections();
  assert.deepEqual(closed, []);
});

test('switching the rotation mode closes the tracked connections so the new mode applies now', () => {
  const m = manager();
  const closed = [];
  m.server = { closeConnection: id => closed.push(id) };
  m.persist = () => {};
  m.trackConnection(7, 'a.com', Date.now());
  m.setSettings({ rotation: 'random' });
  assert.deepEqual(closed, [7]);
});
