import net from 'node:net';

// Three-label registrable domains: example.co.uk, someone.github.io. A short list of the common ones;
// anything else uses the last two labels.
const MULTI_PART_SUFFIXES = new Set([
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'me.uk', 'ltd.uk', 'plc.uk', 'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.nz', 'org.nz', 'net.nz', 'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'co.kr', 'or.kr', 'com.cn', 'net.cn', 'org.cn',
  'gov.cn', 'com.hk', 'com.tw', 'com.sg', 'com.my', 'co.id', 'co.th', 'co.in', 'net.in', 'org.in', 'co.za', 'com.br',
  'com.ar', 'com.mx', 'com.co', 'com.tr', 'com.ua', 'com.pl', 'co.il', 'github.io', 'gitlab.io', 'pages.dev',
  'workers.dev', 'vercel.app', 'netlify.app', 'herokuapp.com', 'blogspot.com', 'web.app', 'firebaseapp.com',
  'azurewebsites.net', 'cloudfront.net', 'appspot.com', 'onrender.com', 'fly.dev', 'myshopify.com', 'glitch.me',
  'repl.co', 'run.app', 'ondigitalocean.app', 'trycloudflare.com', 'ngrok-free.app', 'ngrok.io', 'wixsite.com',
  'weebly.com', 'azurestaticapps.net', 'elasticbeanstalk.com', 'vercel.dev', 'netlify.com', 'surge.sh', 'bubbleapps.io',
]);

const MAX_HOST_LENGTH = 253;

// Second-level labels used under country-code domains: a.com.vn, b.co.ke, c.org.uk. The registrable domain then has three labels.
const SECOND_LEVEL = new Set(['com', 'co', 'org', 'net', 'gov', 'edu', 'ac', 'or', 'ne', 'go', 'gob', 'nom', 'mil', 'sch']);

/** Removes every trailing dot with a loop (a regular expression on a very long string of dots would be slow). */
function trimDots(h) {
  let end = h.length;
  while (end > 0 && h.charCodeAt(end - 1) === 46) end--;
  return h.slice(0, end);
}

const clean = hostname => trimDots(String(hostname).toLowerCase().replace(/^\[|\]$/g, ''));

/** The part of a hostname that identifies a "site": cdn.example.com and example.com share one, example.co.uk stays whole. */
export function siteKey(hostname) {
  const h = clean(hostname);
  if (net.isIP(h)) return h;
  const labels = h.split('.');
  if (labels.length <= 2) return h;
  const last = labels[labels.length - 1];
  const second = labels[labels.length - 2];
  const threeLabels = MULTI_PART_SUFFIXES.has(`${second}.${last}`) || (last.length === 2 && SECOND_LEVEL.has(second));
  return threeLabels ? labels.slice(-3).join('.') : `${second}.${last}`;
}

const BLOCKED = new net.BlockList();
for (const [addr, bits] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.168.0.0', 16], ['224.0.0.0', 4], ['240.0.0.0', 4],
  ['192.0.0.0', 24], ['192.0.2.0', 24], ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24], // special use, documentation, benchmarking
]) BLOCKED.addSubnet(addr, bits, 'ipv4');
for (const [addr, bits] of [
  ['::', 96], // unspecified, loopback and the old IPv4-compatible range
  // IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) are checked against the IPv4 ranges above by BlockList itself.
  // Adding ::ffff:0:0/96 here would wrongly block every IPv4 address, because BlockList stores those as mapped ones.
  ['64:ff9b::', 96], // NAT64: an IPv4 address in disguise
  ['fc00::', 7], ['fe80::', 10], ['fec0::', 10], ['ff00::', 8],
  // IPv4 addresses carried inside IPv6: 6to4, Teredo, the local NAT64 prefix and SIIT. A translator could turn them into
  // 127.0.0.1 or 10.x.x.x on the provider's side.
  ['2002::', 16], ['2001::', 32], ['64:ff9b:1::', 48], ['::ffff:0:0:0', 96],
  ['2001:db8::', 32], // documentation
]) BLOCKED.addSubnet(addr, bits, 'ipv6');

/**
 * Reads a host the way a browser would, so "127.1", "0x7f.1", "0177.0.0.1", "[::ffff:7f00:1]" and "localhost.." are
 * all recognised. Returns null when the name cannot be read at all.
 */
function normalize(hostname) {
  const raw = String(hostname).trim().toLowerCase();
  if (!raw || raw.length > MAX_HOST_LENGTH + 2) return null; // an absurdly long name is refused rather than examined
  const h = trimDots(raw);
  if (!h) return null;
  const bare = h.startsWith('[') && h.endsWith(']') ? h.slice(1, -1) : h;
  try {
    const parsed = new URL(`http://${bare.includes(':') ? `[${bare}]` : bare}`).hostname.replace(/^\[|\]$/g, '');
    // A percent-encoded or full-width dot ("%2e", U+3002) only becomes a real trailing dot after parsing.
    return trimDots(parsed) || null;
  } catch {
    return null;
  }
}

/** True if a CONNECT target is a plain "host:port" or "[ipv6]:port". Anything else is ambiguous between us and the provider. */
export function isValidConnectTarget(target) {
  return typeof target === 'string' && target.length <= MAX_HOST_LENGTH + 8
    && /^(?:[A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\]):\d{1,5}$/.test(target);
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
  // A number-like host that is not already written as plain dotted decimal ("010.0.0.1", "0x7f.1", "2130706433") is read
  // differently by different programs: octal by a browser, decimal by some resolvers, hex by others. The provider could
  // read it another way than we did, so it is refused instead of judged.
  if (kind === 4 && /^[0-9a-fx.]+$/.test(trimDots(String(hostname).trim().toLowerCase())) && trimDots(String(hostname).trim().toLowerCase()) !== h) return true;
  if (kind === 4) return BLOCKED.check(h, 'ipv4');
  if (kind === 6) return BLOCKED.check(h, 'ipv6');
  if (!h.includes('.')) return true; // single-label names such as "localhost", "printer" or "nas"
  // names that only ever exist on a local network (home routers use .box and .home, offices use .corp and .intranet)
  return /\.(localhost|local|lan|internal|home\.arpa|localdomain|home|corp|box|intranet|private|test|invalid)$/.test(h);
}

/**
 * The proxy bypass list the app writes into the Mac's network settings: the destinations the helper refuses anyway, so
 * that local devices keep working directly instead of getting a refusal. The macOS list cannot express IPv6 or
 * single-word names (http://nas/), which the helper refuses with a 403; use the device's IP address for those.
 */
export const MACOS_BYPASS = [
  'localhost', '127.0.0.1', '127.0.0.0/8', '0.0.0.0/8', '169.254/16', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
  '100.64.0.0/10', '224.0.0.0/4', '240.0.0.0/4', '255.255.255.255',
  '*.local', '*.localhost', '*.lan', '*.internal', '*.home.arpa', '*.localdomain', '*.home', '*.corp', '*.box',
  '*.intranet', '*.private', '*.test', '*.invalid',
];
