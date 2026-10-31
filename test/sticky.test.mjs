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
  m.config.stickySeconds = 600;
  m.pick('example.com');
  const pinned = m.sticky.get('example.com');
  pinned.assigned -= 3 * 60_000; // pinned 3 minutes ago, under the old 10 minute setting

  m.pick('example.com');
  assert.equal(m.sticky.get('example.com'), pinned, 'still inside the 10 minute window');

  m.config.stickySeconds = 60; // the user lowers it to 1 minute
  m.pick('example.com');
  assert.notEqual(m.sticky.get('example.com'), pinned, 'a new pick must replace the expired one');
  assert.ok(Date.now() - m.sticky.get('example.com').assigned < 1000);
});

test('the Activity list shows the time left under the current setting', () => {
  const m = manager();
  m.config.stickySeconds = 600;
  m.pick('example.com');
  m.sticky.get('example.com').assigned -= 4 * 60_000;
  const left = m.status().sites[0].expiresIn;
  assert.ok(left > 5 * 60 - 5 && left <= 6 * 60, `expected about 6 minutes left, got ${left}s`);
  m.config.stickySeconds = 180; // already older than that, so it drops off the list
  assert.equal(m.status().sites.length, 0);
});

test('open connections are closed when their sticky time ends, so the client reconnects with a new IP', () => {
  const m = manager();
  m.config.stickySeconds = 60;
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
  m.config.stickySeconds = 600;
  const closed = [];
  m.server = { closeConnection: id => closed.push(id) };
  m.trackConnection(1, 'a.com', Date.now() - 3 * 60_000);
  m.sweepConnections();
  assert.deepEqual(closed, [], '3 minutes old is fine under a 10 minute setting');
  m.config.stickySeconds = 60;
  m.sweepConnections();
  assert.deepEqual(closed, [1]);
});

test('open connections are left alone when the setting is off or rotation is random', () => {
  const m = manager();
  m.config.stickySeconds = 60;
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

test('the sticky time can be 30 seconds: a pin lasts that long and not longer', () => {
  const m = manager();
  m.config.stickySeconds = 30;
  const key = m.pick('a.com').entry.key;
  m.sticky.get('a.com').assigned -= 29_000;
  assert.equal(m.pick('a.com').entry.key, key, 'still pinned after 29 seconds');
  m.sticky.get('a.com').assigned -= 2_000;
  assert.equal(m.sticky.get('a.com').assigned < Date.now() - 30_000, true);
  // after 31 seconds the pin is over, so a new pick makes a fresh one (assigned is now)
  m.pick('a.com');
  assert.ok(Date.now() - m.sticky.get('a.com').assigned < 1000, 'a new pin was made');
});

test('open connections are closed 30 seconds after their pin was made when the sticky time is 30 seconds', () => {
  const m = manager();
  m.config.stickySeconds = 30;
  const closed = [];
  m.server = { closeConnection: id => closed.push(id) };
  const now = Date.now();
  m.trackConnection(1, 'a.com', now - 31_000);
  m.trackConnection(2, 'b.com', now - 29_000);
  m.sweepConnections();
  assert.deepEqual(closed, [1]);
});

test('the status reports the sticky time in seconds, and in whole minutes for older apps', () => {
  const m = manager();
  m.config.stickySeconds = 90;
  assert.equal(m.status().stickySeconds, 90);
  assert.equal(m.status().stickyMinutes, 2);
  m.config.stickySeconds = 30;
  assert.equal(m.status().stickyMinutes, 1);
  m.config.stickySeconds = 600;
  assert.equal(m.status().stickyMinutes, 10);
});

test('setting the sticky time: 30 second steps, limits, and whole minutes from older apps', () => {
  const m = manager();
  m.persist = () => {};
  m.setSettings({ stickySeconds: 30 });
  assert.equal(m.config.stickySeconds, 30);
  m.setSettings({ stickySeconds: 90 });
  assert.equal(m.config.stickySeconds, 90);
  m.setSettings({ stickyMinutes: 5 });
  assert.equal(m.config.stickySeconds, 300, 'an older app that sends minutes still works');
  m.setSettings({ stickyMinutes: 3, stickySeconds: 45 });
  assert.equal(m.config.stickySeconds, 45, 'seconds win when both are sent');
  for (const bad of [{ stickySeconds: 29 }, { stickySeconds: 86401 }, { stickySeconds: 30.5 }, { stickySeconds: 'abc' }, { stickyMinutes: 0 }, { stickyMinutes: 1441 }]) {
    assert.throws(() => m.setSettings(bad), /Sticky time must be 30 seconds to 24 hours/, JSON.stringify(bad));
  }
  assert.equal(m.config.stickySeconds, 45, 'a rejected value changes nothing');
});
