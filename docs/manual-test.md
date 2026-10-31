# Manual checks before a release

The automated tests cover the helper and the system proxy code. They cannot press the buttons or watch the real network
settings, so run these checks by hand on a Mac before you rely on a new build or publish one. Use a Mac where an interrupted
test cannot cost you anything important.

`npm run test:live` automates much of steps 2, 7, 8, 10, and 11 with a real Tor and a stand-in for the network settings. It is
not a replacement for doing them once on your own Mac.

Note your starting point first:

```bash
networksetup -getwebproxy "Wi-Fi"            # expect: Enabled: No
networksetup -getautoproxyurl "Wi-Fi"        # note whether a PAC file is set
networksetup -getproxyautodiscovery "Wi-Fi"  # note whether discovery is on
```

Also look up your real IP address with the proxy off (for example in a browser), so you can compare.

| Step | Do | Expect |
|---|---|---|
| 1. Start | Open the app. | The ring icon appears, the Providers tab lists your providers, and there is no error. |
| 2. Turn on | Press the power switch. | The icon shows a disc inside the ring. The Exit IP tile shows an address that is not your real one. The card "Your real IP may be exposed" does not appear. |
| 3. Settings | Run the three commands above again. | The web proxy is on for `127.0.0.1` and your port. A PAC file and discovery are off. |
| 4. Rotation | Use Sticky, then Random, and reload a site. | Sticky keeps one address for the site. Random changes it. |
| 5. Local addresses | Open your router page (for example `http://192.168.1.1/`) in a browser. | It does not go through the proxy, and the Activity tab does not list it. |
| 6. Tampering | With the proxy on, switch the Wi-Fi proxy off in System Settings. | Within about 15 seconds the app shows that the settings were changed by something else. |
| 7. Turn off | Press the power switch. | Everything from step 3 is back to the starting point, including any PAC file and discovery. `.system-proxy.json` is gone. |
| 8. Quit while on | Turn on, then choose Quit from the icon's menu. | Your internet works afterwards, with the same starting point. |
| 9. Force quit | Turn on, then run `pkill -9 Kagewon`. | Within a few seconds the helper switches the settings off. Opening the app again leaves no leftovers. |
| 10. Kill switch | Enable it in Settings and save. Turn on, then run `pkill -f kagewon/proxy.mjs`. | The icon shows an error, the internet stays blocked, and `lsof -nP -iTCP:8888 -sTCP:LISTEN` shows the Kagewon app holding the port. Press Try Again: it recovers. Quit: the internet works. |
| 11. Turn off, turn on | Press the switch off and on again quickly. | The proxy ends up on, and it is not stopped by the earlier turn-off. |

If any step fails, restore your network with the command in the README (Known limitations) and open an issue or a private report
(see [SECURITY.md](../SECURITY.md)) with the step number.
