<p align="center">
  <img src="docs/logo.svg" width="96" alt="Kagewon logo">
</p>

# Kagewon

Kagewon is a macOS menu bar application that routes your traffic through rotating IP addresses. It runs a local proxy and
switches the Mac's proxy settings on and off for you. It supports two providers: Webshare (paid proxy lists) and Tor (free).
HTTP and HTTPS are both supported. HTTPS traffic is tunneled and is not decrypted.

> **Status: beta (0.1.0).** It changes your Mac's network settings, so read [Safety guidance](#safety-guidance) first and run the
> checks in [docs/manual-test.md](docs/manual-test.md) before you rely on it.

## Contents

- [About the name](#about-the-name)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Security model](#security-model)
- [Safety guidance](#safety-guidance)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [License](#license)
- [Disclaimer](#disclaimer)

## About the name

Kagewon combines two words: **kage** (影, Japanese for "shadow") and **won** (원, Korean for "circle"). The logo shows
the idea: a ring with a shadow inside it. The same two ideas exist as characters in Chinese (影, *yǐng*, and 圆, *yuán*).

## Requirements

- macOS 14 or later
- Xcode Command Line Tools, to build the app (`xcode-select --install`)
- Node.js 22 LTS or later is recommended. Node.js 20.11 also works, but the Node.js project no longer supports it.
- Tor, only if you want to use the Tor provider (see [docs/tor.md](docs/tor.md))

## Installation

Build the application from source on your own Mac. The resulting app is not notarized, so do not distribute it.

```bash
git clone https://github.com/joshghal/kagewon.git
cd kagewon
npm install
menubar/build.sh
open ~/Applications/Kagewon.app
```

`build.sh` compiles the app, draws its icon, and installs `Kagewon.app` into `~/Applications`. If you move the project
folder later, run `menubar/build.sh` again, because the app remembers the folder it was built from.

## Usage

Click the Kagewon icon in the menu bar. There is no configuration file to edit and no `.env` file. You paste your key
in the app.

| Area | Purpose |
|---|---|
| Dashboard | The power switch, your exit IP address, and the Sticky or Random rotation setting |
| Providers | Add, test, enable, disable, edit, and delete providers |
| Activity | Which site uses which proxy, and a live log |
| Settings | Local port, provider refresh interval, logging, and the kill switch (open it from the three-dot menu) |

Right-click the icon for a quick Turn On, Turn Off, and Quit.

### Providers

| Provider | What you provide |
|---|---|
| Webshare | Your API key. The proxy list and its logins are fetched automatically. |
| Tor | Nothing. Install Tor first; see [docs/tor.md](docs/tor.md). |

When several providers are enabled, the **Traffic share** value of each one controls how often it is used.

### Rotation

- **Sticky** keeps one IP address per website for a set time, so sessions and logins keep working. When the time is up,
  the address changes on its own, even if an application keeps its connection open. A switch controls this behavior,
  because closing connections interrupts downloads in progress.
- **Random** uses a new IP address for every connection. Logins may break.

### Kill switch

By default, if the helper process stops, the app switches the Mac's proxy settings off so that your internet keeps working
and your traffic goes out directly. The kill switch reverses this: the settings stay on, so applications that follow the
Mac's proxy settings cannot connect until the proxy is running again. The app also holds the proxy port with a listener
that drops every connection, so no other program on the Mac can take it over. Enable the kill switch in Settings if you
prefer losing the connection to exposing your real IP address. Press Try Again or quit the app to restore the connection.

## Security model

To report a vulnerability, see [SECURITY.md](SECURITY.md).

### What the proxy covers

- It covers every active network (Wi-Fi, Ethernet, a hotspot), including one that appears while it is on. The app warns you
  if another program changes those settings.
- While it is on, the automatic proxy settings of those networks (a PAC file and automatic proxy discovery) are switched off,
  because they can send traffic around a manual proxy. They are put back exactly as they were when you turn the proxy off.
  What was changed is written to `.system-proxy.json` first, so the next start of the app can undo it after a crash.
- When you turn the proxy on, the app checks that it works: it looks up your real IP address directly, then looks it up the
  way an application would. If the two match, a warning says that your real address is still reaching the internet, for
  example because a VPN client routes around the proxy.
- It covers only applications that follow the Mac's proxy settings. Command-line tools (use `curl -x http://127.0.0.1:8888`),
  some applications, system services, UDP traffic, and WebRTC can bypass it.
- Addresses on this Mac and on the local network are never sent to a provider: `localhost`, `10.x.x.x`, `172.16.x.x` to
  `172.31.x.x`, `192.168.x.x`, `100.64.x.x`, and names ending in `.local`, `.lan`, or `.internal`. They are added to the proxy
  bypass list, and the helper also refuses them with a 403 response if something sends them anyway, including unusual
  spellings such as `127.1`. Single-word names such as `http://nas/` are refused as well; use the IP address instead.

### Data handling

- The proxy and its control interface listen only on `127.0.0.1`. The control interface requires a random secret token and a
  matching `Host` header.
- Your Webshare API key is stored in `config.json` with mode 600. It is not encrypted, so any program running as your user
  can read it, and backup tools will copy it. Revoke the key in your Webshare dashboard if you believe it has leaked.
- The log file at `~/Library/Logs/Kagewon.log` is readable only by you and never contains the sites you visit. The Activity
  tab does show recent sites, but only in memory, and they are cleared when you turn the proxy off.
- The helper process receives only `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_ALL`, `USER`, and its own settings, not the rest of the
  environment that the app inherited.
- The app contacts `api.ipify.org` (with `icanhazip.com` as a fallback) to show your exit IP address, `proxy.webshare.io`
  to load your proxy list, and `check.torproject.org` briefly when Tor starts. Once when you turn the proxy on, it also asks
  `api.ipify.org` directly, without the proxy, to learn your real IP address for the leak check. That service sees your real
  address, as every website you visit does. The request carries no app name.

### Known limitations

- Webshare proxies are reached over plain HTTP. On an untrusted network, someone on the path can see the proxy login and the
  host names you connect to. Tor does not have this limitation.
- Anyone who can run programs on your Mac can use the proxy on `127.0.0.1:8888` and spend your bandwidth. It is not
  reachable from the network, and a web page cannot use it.
- If the Mac loses power, or both the app and its helper are killed, nothing listens on the proxy port any more. Another
  local program could bind that port until you open the app again. This matters on shared Macs.
- If the Mac loses power or restarts while the proxy is on, the proxy settings may stay on until you open the app, which
  clears them at startup and restores the automatic settings it saved. To clear them by hand:

  ```bash
  networksetup -listallnetworkservices | tail -n +2 | while read s; do
    networksetup -setwebproxystate "$s" off
    networksetup -setsecurewebproxystate "$s" off
  done
  ```

- Turning the proxy on replaces any manual proxy you had configured on the same network, and turning it off does not restore
  it. A PAC file and automatic proxy discovery are restored.

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
2. **Use Tor for sensitive browsing.** No single party sees both who you are and where you go. Tor is slower, and some sites
   block it.
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
   or post screenshots of it, and exclude it from cloud sync if you can. If you suspect it has leaked, revoke it in your
   Webshare dashboard and paste a new one in the app.
9. **Use proxies only for activities you are permitted to perform.** See the [Disclaimer](#disclaimer).

## Troubleshooting

| Symptom | What to do |
|---|---|
| "Tor is not installed" | Run `brew install tor`, then try again. See [docs/tor.md](docs/tor.md). |
| No provider is enabled | Open Providers and switch one on. |
| Webshare shows an error | Check the API key in your Webshare dashboard, then press Test in the provider's menu. |
| A site fails while others work | Some providers block specific sites. The Activity log notes this once per site. |
| The internet stops after a restart | Open the app, or run the command in the previous section. |
| Port already in use | Change the local port in Settings. |

## Development

```bash
npm install
npm test             # helper tests
npm run test:swift   # system proxy tests, run against a stand-in for networksetup (no real setting is changed)
npm run test:live    # turn on, kill switch, turn off and quit with a real Tor; needs Tor and a few minutes, changes no real setting
node proxy.mjs       # run the helper on its own; the app normally starts it
```

| Path | Contents |
|---|---|
| `proxy.mjs` | Helper entry point |
| `src/` | Helper modules: proxy engine, providers, Tor management, configuration, control interface |
| `menubar/` | The macOS app (Swift), its build script, and its tests |
| `docs/` | Additional documentation, the manual release checks, and the logo |
| `test/` | Automated tests |

Settings and providers are stored in `config.json` in the project folder. The environment variables `CONTROL_PORT`,
`CONTROL_TOKEN`, `AUTOSTART`, `WEBSHARE_API_BASE` (accepted only for local addresses), and `KAGEWON_DIR` exist for the app and
for tests. They are not needed for normal use.

## License

Kagewon is released under the [MIT License](LICENSE).

It depends on [proxy-chain](https://github.com/apify/proxy-chain), which is distributed under its own license, and it can
use Tor, which you install separately.

## Disclaimer

Kagewon is an independent project. It is not affiliated with, endorsed by, or sponsored by Webshare or the Tor Project.
Webshare and Tor are trademarks of their respective owners. Use proxies only for activities you are permitted to perform,
and follow the terms of the websites you visit, the terms of your proxy provider, and the laws that apply to you.
