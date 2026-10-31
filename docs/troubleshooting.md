# Troubleshooting

| Symptom | What to do |
|---|---|
| "Tor is not installed" | Run `brew install tor`, then try again. See [tor.md](tor.md). |
| No provider is enabled | Open Providers and switch one on. |
| Webshare shows an error | Check the API key in your Webshare dashboard, then press Test connection in the provider's menu. |
| A site fails while others work | Some providers block specific sites. The Activity log notes this about once a minute per site. |
| The internet stops after a restart | Open the app. If it will not open, run the command under [Known limitations](security.md#known-limitations). |
| Port already in use | Change the local port in Settings. The helper waits a few seconds for the port before it gives up. |
| A router, NAS or other local device answers 403 | Use its IPv4 address. Single-word names and unusual spellings are refused, see [What the proxy covers](security.md#what-the-proxy-covers). |
| The icon keeps moving for a long time | The helper is loading or checking the proxy lists. The line under the app name says which step, and the log file records how long each step took. |
