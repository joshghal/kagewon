import test from 'node:test';
import assert from 'node:assert/strict';
import { siteKey, isInternalHost } from '../src/hosts.mjs';

test('siteKey groups subdomains but keeps registrable domains with a country suffix apart', () => {
  assert.equal(siteKey('cdn.example.com'), 'example.com');
  assert.equal(siteKey('example.com'), 'example.com');
  assert.equal(siteKey('www.bbc.co.uk'), 'bbc.co.uk');
  assert.equal(siteKey('other.co.uk'), 'other.co.uk', 'a different .co.uk site is a different site');
  assert.equal(siteKey('alice.github.io'), 'alice.github.io');
  assert.equal(siteKey('bob.github.io'), 'bob.github.io');
  assert.equal(siteKey('example.com.'), 'example.com', 'a trailing dot is ignored');
  assert.equal(siteKey('1.2.3.4'), '1.2.3.4');
  assert.equal(siteKey('[2001:db8::1]'), '2001:db8::1');
});

test('local and private destinations are recognised', () => {
  for (const h of ['localhost', 'printer', 'nas.local', 'router.lan', 'x.internal', '127.0.0.1', '127.1.2.3', '10.0.0.5', '172.16.0.1',
    '172.31.255.255', '192.168.1.1', '169.254.1.1', '100.64.0.1', '0.0.0.0', '::1', 'fe80::1', 'fd00::1', '::ffff:192.168.0.1', '[::1]', '']) {
    assert.equal(isInternalHost(h), true, h);
  }
});

test('public destinations are not mistaken for local ones', () => {
  for (const h of ['example.com', 'api.ipify.org', '8.8.8.8', '172.32.0.1', '172.15.0.1', '192.169.0.1', '11.0.0.1', '2606:4700::1111', 'local.example.com']) {
    assert.equal(isInternalHost(h), false, h);
  }
});

test('odd spellings of local addresses are recognised, as they arrive on a CONNECT request (127.1 and friends)', () => {
  for (const h of ['127.1', '0x7f.1', '0177.0.0.1', '127.000.000.001', '10.1', '0xC0.0xA8.1.1', '2130706433', '[::ffff:7f00:1]',
    '[::ffff:a00:1]', '[::7f00:1]', '[64:ff9b::7f00:1]', '[fec0::1]', '[ff02::1]', 'localhost..', 'LOCALHOST', 'fe80::1%en0']) {
    assert.equal(isInternalHost(h), true, h);
  }
});

test('a name that cannot be read is treated as internal, so odd spellings fail closed', () => {
  for (const h of ['exa mple.com', 'a b', '%%', 'http://x']) assert.equal(isInternalHost(h), true, h);
});

test('public addresses written in odd ways are still public', () => {
  for (const h of ['0x08.0x08.0x08.0x08', '134744072', '[2606:4700::1111]', 'EXAMPLE.com.', 'xn--bcher-kva.example']) {
    assert.equal(isInternalHost(h), false, h);
  }
});
