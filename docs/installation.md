# Installation

## Requirements

- macOS 14 or later
- Xcode Command Line Tools, to build the app (`xcode-select --install`)
- Node.js 22 LTS or later is recommended. Node.js 20.11 also works, but the Node.js project no longer supports it.
- Tor, only if you want to use the Tor provider (see [tor.md](tor.md))

## Build and install

Build the application from source on your own Mac. The resulting app is not notarized, so do not distribute it.

```bash
git clone https://github.com/joshghal/kagewon.git
cd kagewon
npm ci
menubar/build.sh
open ~/Applications/Kagewon.app
```

`build.sh` compiles the app, draws its icon, and installs `Kagewon.app` into `~/Applications`. If a copy is running, `build.sh`
quits it first, which switches the proxy off. If you move the project folder later, run `menubar/build.sh` again, because the
app remembers the folder it was built from.

Clone into a folder that is not synced by iCloud Drive or a similar service. The project folder holds `config.json`, which
contains your API key, and the Tor data folder.
