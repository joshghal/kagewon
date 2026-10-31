# Security and safety

This page has two parts: the security model (what the proxy covers, how data is handled, and its known limitations) and
practical safety guidance (what each party can see, what is not protected, and how to reduce the risk).

## Security model

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

### What the proxy covers

- It covers every enabled network service (Wi-Fi, Ethernet, a hotspot). A service that appears while it is on is covered at
  once, and the settings are checked again after the Mac wakes from sleep or the network changes. The app warns you if another
  program changes those settings.
- While it is on, the automatic proxy settings of those networks (a PAC file and automatic proxy discovery) are switched off,
  because they can send traffic around a manual proxy. They are put back as they were when you turn the proxy off, unless
  something else changed them in the meantime, and the bypass entries that Kagewon added are removed again. What was changed
  is written to `.system-proxy.json` first, so the next start of the app, or the helper itself after a force-quit, can undo
  it. If that record cannot be written, the proxy does not turn on.
- When you turn the proxy on, the app checks that it works: it looks up your real IP address directly, then looks it up the
  way an application would. If the two match, a warning says that your real address is still reaching the internet, for
  example because a VPN client routes around the proxy. After a wake from sleep or a network change the check is repeated
  against the remembered address, without another direct request.
- Made-up host names cannot disturb a real session. A web page can make your browser ask for host names that do not exist, and
  the provider refuses those. Only a host name that has worked before can change the pinned IP of its site or count against
  a proxy; a name that never worked only gets a short detour of its own.
- It covers only applications that follow the Mac's proxy settings. Command-line tools (use `curl -x http://127.0.0.1:8888`),
  some applications, system services, UDP traffic, and WebRTC can bypass it.
- Addresses on this Mac and on the local network are never sent to a provider. The app puts these on the proxy bypass list, so
  that local devices keep working directly: `localhost`, `127.0.0.0/8`, `0.0.0.0/8`, `169.254.0.0/16`, `10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `224.0.0.0/4`, `240.0.0.0/4`, `255.255.255.255`, and names ending in
  `.local`, `.localhost`, `.lan`, `.internal`, `.home.arpa`, `.localdomain`, `.home`, `.corp`, `.box`, `.intranet`,
  `.private`, `.test`, or `.invalid`. The helper also refuses them with a 403 response if something sends them anyway,
  including unusual spellings such as `127.1`, number-like hosts that are not plain dotted decimal (`010.0.0.1`), and local
  IPv6 ranges. The macOS list cannot hold IPv6 addresses or single-word names such as `http://nas/`, so those get the 403;
  use the device's IPv4 address instead. A public name that points at a private address (corporate split DNS, or a service
  such as `localtest.me`) cannot be recognised. The provider resolves it on its own network, not yours.

### Data handling

- The proxy and its control interface listen only on `127.0.0.1`. The control interface requires a random secret token and a
  matching `Host` header.
- Your Webshare API key is stored in `config.json` with mode 600. It is not encrypted, so any program running as your user
  can read it, and backup tools will copy it. Revoke the key in your Webshare dashboard if you believe it has leaked. If a
  file has to be set aside because it could not be read, the copy (`config.json.broken-*`) has the keys removed, and
  temporary files left by an interrupted write are deleted when the helper starts.
- Tor keeps its state, including its entry guard list, in `.tor/<provider>/` in the project folder between runs. The folder is
  private to your user.
- The log file at `~/Library/Logs/Kagewon.log` is readable only by you and never contains the sites you visit. It records
  when the proxy turned on and how long each step took, and it is emptied when it reaches 2 MB. The Activity tab does show recent sites, but only in memory, and
  they are cleared when you turn the proxy off or the helper stops.
- The helper process receives only `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_ALL`, `USER`, and its own settings, not the rest of the
  environment that the app inherited.
- The app contacts `api.ipify.org` (with `icanhazip.com` as a fallback) to show your exit IP address, `proxy.webshare.io`
  to load your proxy list, and `check.torproject.org` briefly when Tor starts. Each time you turn the proxy on (including
  Try Again), it also asks the same IP echo services directly, without the proxy, to learn your real IP address for the leak
  check. Those services see your real address, because that request does not use the proxy; the websites you reach through
  the proxy do not. The request carries no app name and a generic user agent, but like any browser request it carries your
  system language and the macOS TLS fingerprint.

### Known limitations

- Webshare proxies are reached over plain HTTP. On an untrusted network, someone on the path can see the proxy login and the
  host names you connect to. Tor does not have this limitation.
- Anyone who can run programs on your Mac can use the proxy on `127.0.0.1:8888` and spend your bandwidth. It is not
  reachable from the network, and a web page cannot use it.
- If the Mac loses power, or both the app and its helper are killed, nothing listens on the proxy port any more. Another
  local program could bind that port until you open the app again. This matters on shared Macs.
- With the kill switch on, force-quitting the app leaves the helper holding the port, so the internet stays blocked until you
  open the app again. It stops the helper and restores the settings.
- If the Mac loses power or restarts while the proxy is on, the proxy settings may stay on until you open the app. Open the
  app first: it undoes the changes from its recovery record, including the PAC file, automatic discovery and the bypass
  entries. If the app will not open, this switches off the manual proxy on every network that points at a local address.
  It does not restore a PAC file or automatic discovery, so check System Settings, Network, your connection, Details, Proxies
  afterwards:

  ```bash
  networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while read -r s; do
    networksetup -getwebproxy "$s" | grep -q '^Server: 127\.0\.0\.1$' && networksetup -setwebproxystate "$s" off
    networksetup -getsecurewebproxy "$s" | grep -q '^Server: 127\.0\.0\.1$' && networksetup -setsecurewebproxystate "$s" off
  done
  ```

- Turning the proxy on replaces any manual proxy you had configured on the same network, and turning it off does not restore
  it. A PAC file and automatic proxy discovery are restored, and the bypass entries Kagewon added are removed.
- Captive portals (the sign-in pages of hotel, airport or cafe Wi-Fi) cannot be reached through the proxy. Turn Kagewon off,
  sign in, and turn it on again.
- A VPN that is installed as a network extension can route traffic in a way the Mac's proxy settings cannot see. The leak check
  catches it only when it runs: at turn-on, after a wake from sleep, and after a network change.
- "Reachable" means the proxy accepts connections. It may still refuse your login or a particular site. After a refusal,
  Kagewon uses another proxy for that site. If no proxy can be reached, the proxy refuses to turn on. If they all fail while
  it is on, applications get an error: there is no direct fallback.

## Safety guidance

Kagewon changes the IP address that websites see. It does not make you anonymous, and it does not hide your activity from
the proxy provider. This section explains what each party can see, what is not protected, and how to reduce the risk.

### What each party can see

| Traffic | Webshare proxy | Tor exit relay |
|---|---|---|
| HTTPS site (address starts with `https://`) | The host name and port, plus the size and timing of the encrypted traffic. Not the content. | The same |
| Plain HTTP site (address starts with `http://`) | Everything: the address, cookies, form data, and the response | The same |
| Your real IP address | Yes, because the connection comes from your Mac | No. Only the first Tor relay sees it, and it does not see where you go. |

Kagewon never decrypts HTTPS and sends no usage data to anyone. The services it contacts are listed under
[Data handling](#data-handling).

### What Kagewon cannot protect

- **Host names.** A provider can log which sites you connect to. Kagewon cannot prevent that.
- **Plain HTTP content.** Nothing protects it from the provider or from a Tor exit relay.
- **Applications that ignore the Mac's proxy settings.** Command-line tools (unless you use `curl -x http://127.0.0.1:8888`),
  some applications, system services, UDP traffic, and WebRTC go out with your real IP address.
- **Who you are on a site.** A site can still recognize you by your login, cookies, and browser fingerprint. A new IP address
  does not change them.
- **The proxy login on an untrusted network.** Webshare proxies are reached over plain HTTP, so someone on the same network
  can see the proxy login and the host names you connect to.

### Recommended practice

1. **Log in only to HTTPS sites.** On a plain HTTP site, the provider or the exit relay can read your password.
2. **Use Tor for sensitive browsing.** The relays you pass through do not see both who you are and where you go. The exit
   relay still sees plain HTTP content, and your browser can still identify you. Tor is slower, and some sites block it.
3. **Prefer Tor on public or shared networks.** Webshare proxies use plain HTTP to reach the proxy.
4. **Use Sticky rotation for logins.** Random rotation changes the IP address on every connection, which breaks sessions and
   can make a site flag your account.
5. **Check the result after turning the proxy on.** The Exit IP tile should show an address that is not your own. If a warning
   says that your real IP is still reaching the internet, stop and find the cause, for example a VPN client that routes around
   the proxy.
6. **Turn on the kill switch if exposing your real IP is worse than losing the connection.** It only affects applications that
   follow the Mac's proxy settings.
7. **Turn the proxy off when you are done.** The recent-sites list in the Activity tab is cleared at that point.
8. **Protect your API key.** `config.json` is private to your user account but is not encrypted. Do not commit it, share it,
   or post screenshots of it, and keep the project folder out of cloud sync. If you suspect it has leaked, revoke it in your
   Webshare dashboard and paste a new one in the app.
9. **Use proxies only for activities you are permitted to perform.** See the [Disclaimer](../README.md#disclaimer).
