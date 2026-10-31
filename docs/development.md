# Development

```bash
npm ci
npm test             # helper tests
npm run test:swift   # system proxy tests, run against a stand-in for networksetup (no real setting is changed)
npm run test:live    # turn on, kill switch, turn off and quit with a real Tor; needs Tor and a few minutes, changes no real setting
node proxy.mjs       # run the helper on its own; the app normally starts it
npm run hooks        # install the secret guard: git hooks that refuse a commit or push containing config.json, other private files, or your saved key
```

| Path | Contents |
|---|---|
| `proxy.mjs` | Helper entry point |
| `src/` | Helper modules: proxy engine, providers, Tor management, configuration, control interface |
| `menubar/` | The macOS app (Swift), its build script, and its tests |
| `docs/` | Additional documentation, the manual release checks, the demonstration recordings, and the logo |
| `scripts/hooks/` | The git hooks behind `npm run hooks` |
| `scripts/demo/` | Builds the demonstration copy of the app with dummy data and records the GIFs in `docs/demo/` (macOS; needs screen recording permission) |
| `test/` | Automated tests |

Settings and providers are stored in `config.json` in the project folder. The environment variables `CONTROL_PORT`,
`CONTROL_TOKEN`, `AUTOSTART`, and `KAGEWON_DIR` exist for the app and for tests, and `WEBSHARE_API_BASE` (accepted only for local
addresses) is honored only when `KAGEWON_DEV=1` is also set. None of them is needed for normal use.
