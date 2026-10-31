# Manual checks before a release

The automated tests cover the helper and the system proxy code. They cannot press the buttons or watch the real network
settings, so run these checks by hand on a Mac before you rely on a new build or publish one. Use a Mac where an interrupted
test cannot cost you anything important.

`npm run test:live` automates much of steps 2, 7, 8, 10, and 11 with a real Tor and a stand-in for the network settings. It is
not a replacement for doing them once on your own Mac.

Note your starting point first:

```bash
networksetup -getwebproxy "Wi-Fi"            # expect: Enabled: No
networksetup -getsecurewebproxy "Wi-Fi"      # expect: Enabled: No
networksetup -getautoproxyurl "Wi-Fi"        # note whether a PAC file is set
networksetup -getproxyautodiscovery "Wi-Fi"  # note whether discovery is on
networksetup -getproxybypassdomains "Wi-Fi"  # note your own bypass entries
```

Also look up your real IP address with the proxy off (for example in a browser), so you can compare.

| Step | Do | Expect |
|---|---|---|
| 1. Start | Open the app. | A globe with a thin arc of shadow beside it appears in the menu bar, the Providers tab lists your providers, and there is no error. |
| 2. Turn on | Press the power switch. | While connecting, dashes travel around a circle and the line under the app name names each step. Then the globe has a solid crescent beside it. The Exit IP tile shows an address that is not your real one. The card "Your real IP may be exposed" does not appear. |
| 3. Settings | Run the commands above again. | Both the web proxy and the secure web proxy are on for `127.0.0.1` and your port. A PAC file and discovery are off. The bypass list has your own entries plus the local addresses listed in [security.md](security.md#what-the-proxy-covers). |
| 4. Rotation | Use Sticky, then Random, and reload a site. | Sticky keeps one address for the site. Random changes it. |
| 5. Local addresses | Open your router page (for example `http://192.168.1.1/`) in a browser. | It does not go through the proxy, and the Activity tab does not list it. |
| 6. Tampering | With the proxy on, switch the Wi-Fi proxy off in System Settings. | Within about 15 seconds the app shows that the settings were changed by something else. |
| 7. Turn off | Press the power switch. | Everything is back to the starting point: both proxy halves, any PAC file and discovery, and your own bypass entries without the ones Kagewon added. `.system-proxy.json` is gone. |
| 8. Quit while on | Turn on, then choose Quit from the icon's menu. | Your internet works afterwards, with the same starting point. |
| 9. Force quit | Turn on, then run `pkill -9 -x Kagewon`. | Within a few seconds the helper switches the settings off and restores any PAC file, discovery and bypass list. Opening the app again leaves no leftovers. |
| 10. Kill switch | Enable it in Settings and save. Turn on, then run `pkill -f kagewon/proxy.mjs`. | The icon shows an error, the internet stays blocked, and `lsof -nP -iTCP:8888 -sTCP:LISTEN` shows the Kagewon app holding the port. Press Try Again: it recovers. Quit: the internet works. |
| 11. Turn off, turn on | Press the switch off and on again quickly. | The proxy ends up on, and it is not stopped by the earlier turn-off. |
| 12. Sleep | Turn on, close the lid or choose Sleep, then wake the Mac. | Within a few seconds the proxy settings are still on and no warning appears. |
| 13. Another network | Turn on, then connect to a different Wi-Fi network or plug in Ethernet. | The new network is covered within moments. Turn off and check that its settings are back as they were. |

If any step fails, restore your network with the command in the [README](../README.md#if-your-internet-stops) and open an issue or a private report
(see [SECURITY.md](../SECURITY.md)) with the step number.
