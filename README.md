<p align="center">
  <img src="docs/logo.svg" width="96" alt="Kagewon logo">
</p>

# Kagewon

Kagewon is a macOS menu bar app that routes your traffic through rotating IP addresses. It runs a local proxy and switches the
Mac's proxy settings on and off for you. It supports two providers: Webshare (paid proxy lists) and Tor (free). HTTP and HTTPS
both work, and HTTPS is tunneled, never decrypted.

> **Status: beta (0.1.0).** It changes your Mac's network settings. Read [Safety](#safety-at-a-glance) first, and run the
> checks in [docs/manual-test.md](docs/manual-test.md) before you rely on it.

<p align="center">
  <img src="docs/demo/2-turn-on-and-off.gif" width="300" alt="Turning the proxy on: the list loads, the proxies are checked, the Mac's settings are switched on, and the exit IP appears">
  &nbsp;&nbsp;
  <img src="docs/demo/7-terminal.gif" width="420" alt="curl without the proxy shows the real address; through the proxy it shows a different one that stays the same while Sticky and changes on every request while Random">
</p>

All recordings use made-up data. See [more recordings](docs/demo.md).

## Contents

[About the name](#about-the-name) |
[Requirements](#requirements) |
[Installation](#installation) |
[Usage](#usage) |
[Safety](#safety-at-a-glance) |
[If your internet stops](#if-your-internet-stops) |
[Documentation](#documentation) |
[Development](#development) |
[License](#license) |
[Disclaimer](#disclaimer)

## About the name

Kagewon combines **kage** (影, Japanese for "shadow") and **won** (원, Korean for "circle"). The logo shows the idea: a globe,
which is also a circle, with its shadow falling beside it. The same two ideas exist as characters in Chinese (影, *yǐng*, and
圆, *yuán*).

## Requirements

- macOS 14 or later, and the Xcode Command Line Tools (`xcode-select --install`) to build the app
- Node.js 22 LTS or later (20.11 also works, but it is no longer supported by the Node.js project)
- Tor, only for the Tor provider (see [docs/tor.md](docs/tor.md))

## Installation

Build from source on your own Mac. The app is not notarized, so do not distribute it.

```bash
git clone https://github.com/joshghal/kagewon.git
cd kagewon
npm ci
menubar/build.sh
open ~/Applications/Kagewon.app
```

`build.sh` installs `Kagewon.app` into `~/Applications`, and quits a running copy first (which switches the proxy off). Run it
again if you move the project folder. Clone into a folder that iCloud Drive or a similar service does not sync: the project
folder holds `config.json` (your API key) and the Tor data folder.

More detail on requirements and the build is in [docs/installation.md](docs/installation.md).

## Usage

Click the Kagewon icon in the menu bar. There is no configuration file to edit and no `.env` file: you paste your key in the app.

| Area | Purpose |
|---|---|
| Dashboard | The power switch, your exit IP, and the Sticky or Random rotation setting |
| Providers | Add, test, enable, disable, edit, and delete providers (Webshare with an API key, or Tor) |
| Activity | Which site uses which proxy, and a live log |
| Settings | Local port, refresh interval, logging, and the kill switch (open it from the three-dot menu) |

- **Sticky** keeps one IP per website for a time you choose (30 seconds to 4 hours, in 30 second steps), so logins keep
  working. **Random** uses a new IP for every connection.
- **Kill switch** (off by default) keeps the internet blocked if the proxy stops, instead of letting traffic go out directly.
- Right-click the icon for a quick Turn On, Turn Off, and Quit.

The full guide, including providers, rotation details, and the kill switch, is in [docs/usage.md](docs/usage.md).

## Safety at a glance

- **Your provider sees which hosts you visit.** For plain HTTP sites it sees everything. Webshare proxies are reached over
  plain HTTP, so on an untrusted network prefer Tor.
- **Only apps that follow the Mac's proxy settings are covered.** Command-line tools (use `curl -x http://127.0.0.1:8888`),
  some apps, system services, UDP, and WebRTC can bypass it.
- **Your local network stays local.** Addresses on this Mac and on your network are never sent to a provider.
- **Your API key stays on your Mac** in `config.json` (mode 600, not encrypted). It never appears in the log.
- **A new IP does not hide who you are.** Logins, cookies, and the browser fingerprint still identify you.
- **A warning appears** if your real IP still reaches the internet, for example because of a VPN.

The security model, what each party can see, known limitations, and practical advice are in
[docs/security.md](docs/security.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## If your internet stops

Open the app first: it undoes its changes from a private recovery record, including the PAC file, automatic discovery, and the
bypass entries. If the app will not open, this switches off the manual proxy on every network that points at a local address.
It does not restore a PAC file or automatic discovery, so check System Settings, Network, your connection, Details, Proxies
afterwards:

```bash
networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while read -r s; do
  networksetup -getwebproxy "$s" | grep -q '^Server: 127\.0\.0\.1$' && networksetup -setwebproxystate "$s" off
  networksetup -getsecurewebproxy "$s" | grep -q '^Server: 127\.0\.0\.1$' && networksetup -setsecurewebproxystate "$s" off
done
```

More causes and fixes are in [docs/troubleshooting.md](docs/troubleshooting.md).

## Documentation

| Page | Contents |
|---|---|
| [docs/installation.md](docs/installation.md) | Requirements, building the app, moving the project folder, where to clone |
| [docs/usage.md](docs/usage.md) | The dashboard, providers, Sticky and Random rotation, the kill switch |
| [docs/security.md](docs/security.md) | Security model, data handling, known limitations, safety guidance |
| [docs/tor.md](docs/tor.md) | Setting up Tor from scratch, and what to expect from it |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms and what to do |
| [docs/demo.md](docs/demo.md) | Recordings of every flow, made with dummy data |
| [docs/manual-test.md](docs/manual-test.md) | Checks to run by hand before relying on a build |
| [docs/development.md](docs/development.md) | Tests, project layout, environment variables, hooks, the demo recorder |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability |

## Development

```bash
npm ci
npm test             # helper tests
npm run test:swift   # system proxy tests against a stand-in for networksetup
npm run test:live    # full flow with a real Tor; no real setting is changed
npm run hooks        # install the secret guard (refuses a commit or push that contains your key)
```

The layout, environment variables, and the demo recorder are in [docs/development.md](docs/development.md).

## License

Kagewon is released under the [MIT License](LICENSE). It depends on [proxy-chain](https://github.com/apify/proxy-chain), which is
distributed under its own license, and it can use Tor, which you install separately.

## Disclaimer

Kagewon is an independent project. It is not affiliated with, endorsed by, or sponsored by Webshare or the Tor Project.
Webshare and Tor are trademarks of their respective owners. Use proxies only for activities you are permitted to perform,
and follow the terms of the websites you visit, the terms of your proxy provider, and the laws that apply to you.
