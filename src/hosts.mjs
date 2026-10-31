import net from 'node:net';

// Three-label registrable domains: example.co.uk, someone.github.io. A short list of the common ones;
// anything else uses the last two labels.
const MULTI_PART_SUFFIXES = new Set([
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'me.uk', 'ltd.uk', 'plc.uk', 'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.nz', 'org.nz', 'net.nz', 'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'co.kr', 'or.kr', 'com.cn', 'net.cn', 'org.cn',
  'gov.cn', 'com.hk', 'com.tw', 'com.sg', 'com.my', 'co.id', 'co.th', 'co.in', 'net.in', 'org.in', 'co.za', 'com.br',
  'com.ar', 'com.mx', 'com.co', 'com.tr', 'com.ua', 'com.pl', 'co.il', 'github.io', 'gitlab.io', 'pages.dev',
  'workers.dev', 'vercel.app', 'netlify.app', 'herokuapp.com', 'blogspot.com', 'web.app', 'firebaseapp.com',
  'azurewebsites.net', 'cloudfront.net',
]);

const clean = hostname => String(hostname).toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');

/** The part of a hostname that identifies a "site": cdn.example.com and example.com share one, example.co.uk stays whole. */
export function siteKey(hostname) {
  const h = clean(hostname);
  if (net.isIP(h)) return h;
  const labels = h.split('.');
  if (labels.length <= 2) return h;
  return MULTI_PART_SUFFIXES.has(labels.slice(-2).join('.')) ? labels.slice(-3).join('.') : labels.slice(-2).join('.');
}

const BLOCKED = new net.BlockList();
for (const [addr, bits] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.168.0.0', 16], ['224.0.0.0', 4], ['240.0.0.0', 4],
]) BLOCKED.addSubnet(addr, bits, 'ipv4');
for (const [addr, bits] of [
  ['::', 96], // unspecified, loopback and the old IPv4-compatible range
  // IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) are checked against the IPv4 ranges above by BlockList itself.
  // Adding ::ffff:0:0/96 here would wrongly block every IPv4 address, because BlockList stores those as mapped ones.
  ['64:ff9b::', 96], // NAT64: an IPv4 address in disguise
  ['fc00::', 7], ['fe80::', 10], ['fec0::', 10], ['ff00::', 8],
]) BLOCKED.addSubnet(addr, bits, 'ipv6');

/**
 * Reads a host the way a browser would, so "127.1", "0x7f.1", "0177.0.0.1", "[::ffff:7f00:1]" and "localhost.." are
 * all recognised. Returns null when the name cannot be read at all.
 */
function normalize(hostname) {
  const h = String(hostname).trim().toLowerCase().replace(/\.+$/, '');
  if (!h) return null;
  const bare = h.startsWith('[') && h.endsWith(']') ? h.slice(1, -1) : h;
  try {
    return new URL(`http://${bare.includes(':') ? `[${bare}]` : bare}`).hostname.replace(/^\[|\]$/g, '');
  } catch {
    return null;
  }
}

/**
 * Hosts that belong to this Mac or its local network. They must never be sent to a proxy provider:
 * the provider would see the request (and any login in it), and it could never reach them anyway.
 * Anything that cannot be read is treated as internal, so odd spellings fail closed.
 */
export function isInternalHost(hostname) {
  const h = normalize(hostname);
  if (h === null) return true;
  const kind = net.isIP(h);
  if (kind === 4) return BLOCKED.check(h, 'ipv4');
  if (kind === 6) return BLOCKED.check(h, 'ipv6');
  if (!h.includes('.')) return true; // single-label names such as "localhost", "printer" or "nas"
  return /\.(localhost|local|lan|internal|home\.arpa|localdomain)$/.test(h);
}
