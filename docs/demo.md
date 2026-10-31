# Demo

These recordings show every flow. They were made with the real app and helper, but with made-up data: a fake Webshare service,
twelve dummy proxies, a dummy API key, and addresses from the ranges reserved for documentation (`203.0.113.0/24` and
`198.51.100.0/24`). A stand-in replaces the Mac's network settings, so no real account, address, or setting appears. The Terminal
recording runs the real `curl` commands against the demonstration helper and draws their real output; it is not a screenshot of
a Terminal window. You can record them again with [`scripts/demo/run-demo.sh`](../scripts/demo/run-demo.sh).

## Add a provider

<img src="demo/1-add-provider.gif" width="360" alt="Adding a Webshare provider: a wrong key is rejected, a valid key shows the proxies and an exit IP, and the provider is saved">

## Turn the proxy on and off

<img src="demo/2-turn-on-and-off.gif" width="360" alt="Turning the proxy on: the list loads, the proxies are checked, the Mac's settings are switched on, and the exit IP appears; then turning it off">

## Terminal: IP check, curl, and rotation

<img src="demo/7-terminal.gif" width="460" alt="curl without the proxy shows the real address; through the proxy it shows a different address that stays the same while Sticky, changes on every request while Random, and can be set once with http_proxy">

## Sticky and Random rotation

<img src="demo/3-rotation-and-activity.gif" width="360" alt="The Activity tab lists each site with its proxy; the sticky time is set in 30 second steps; Random mode gives the same site a different proxy on every connection">

## A warning when your real address is exposed

<img src="demo/4-leak-warning.gif" width="360" alt="A warning card says that the real IP address is still reaching the internet">

## Kill switch

<img src="demo/5-kill-switch.gif" width="360" alt="With the kill switch on, a stopped helper leaves the internet blocked until Try Again is pressed">

## Settings and Tor

<img src="demo/6-settings-and-tor.gif" width="360" alt="The Settings screen and the Tor provider form with its built-in setup guide">

## Menu bar icon

<img src="demo/menu-bar-icons.png" width="460" alt="The menu bar icon when off, connecting, on, and on error, on a dark and a light menu bar">
