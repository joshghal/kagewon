<p align="center">
  <img src="docs/logo.svg" width="96" alt="Kagewon logo">
</p>

# Kagewon

Kagewon is a macOS menu bar application that routes your traffic through rotating IP addresses. It runs a local proxy and
switches the Mac's proxy settings on and off for you. It supports two providers: Webshare (paid proxy lists) and Tor (free).
HTTP and HTTPS are both supported. HTTPS traffic is tunneled and is not decrypted.

## Contents

- [About the name](#about-the-name)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Security model](#security-model)
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
- Node.js 20.11 or later; a current long-term-support release is recommended
- Tor, only if you want to use the Tor provider (see [docs/tor.md](docs/tor.md))

## Installation

Build the application from source on your own Mac. The resulting app is not notarized, so do not distribute it.

```bash
git clone https://github.com/kagewon-app/kagewon.git
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
Mac's proxy settings cannot connect until the proxy is running again. Enable it in Settings if you prefer losing the
connection to exposing your real IP address.

## Security model

### What the proxy covers

- It covers every active network (Wi-Fi, Ethernet, a hotspot), including one that appears while it is on. The app warns you
  if another program changes those settings.
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
  tab does show recent sites, but only in memory.
- The app contacts `api.ipify.org` (with `icanhazip.com` as a fallback) to show your exit IP address, `proxy.webshare.io`
  to load your proxy list, and `check.torproject.org` briefly when Tor starts.

### Known limitations

- Webshare proxies are reached over plain HTTP. On an untrusted network, someone on the path can see the proxy login and the
  host names you connect to. Tor does not have this limitation.
- Anyone who can run programs on your Mac can use the proxy on `127.0.0.1:8888` and spend your bandwidth. It is not
  reachable from the network, and a web page cannot use it.
- While the kill switch is active, or after an unclean shutdown, the Mac may point at a local port that nothing is listening
  on. Another local program could bind that port. This matters on shared Macs.
- If the Mac loses power or restarts while the proxy is on, the proxy settings may stay on until you open the app, which
  clears them at startup. To clear them by hand:

  ```bash
  networksetup -listallnetworkservices | tail -n +2 | while read s; do
    networksetup -setwebproxystate "$s" off
    networksetup -setsecurewebproxystate "$s" off
  done
  ```

- Turning the proxy on replaces any proxy you had configured on the same network. Turning it off does not restore it.

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
npm test             # unit and integration tests
node proxy.mjs       # run the helper on its own; the app normally starts it
```

| Path | Contents |
|---|---|
| `proxy.mjs` | Helper entry point |
| `src/` | Helper modules: proxy engine, providers, Tor management, configuration, control interface |
| `menubar/` | The macOS app (Swift) and its build script |
| `docs/` | Additional documentation and the logo |
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
