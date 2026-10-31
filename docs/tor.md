# Setting up Tor

Tor is a free way to obtain a different IP address. Your traffic passes through three volunteer relays, and the last one,
called the exit relay, is the address that websites see. Tor is slower than paid proxies and many websites block it, but it
costs nothing and needs no account.

Kagewon starts Tor when you turn the proxy on and stops it when you turn the proxy off. There is no background service to
manage.

## 1. Install Tor

1. Install Homebrew if you do not have it. In Terminal, run `brew --version`. If the command is not found, follow the
   instructions at <https://brew.sh>.
2. Install Tor:

   ```bash
   brew install tor
   ```

3. Check the installation:

   ```bash
   tor --version
   ```

   The output should begin with `Tor version 0.4`.

You do not need to run `brew services start tor`. Kagewon runs its own Tor instance.

## 2. Add Tor in Kagewon

1. Click the Kagewon icon, open **Providers**, choose **Add**, then **Tor**.
2. Optional: enter **Exit countries** as two-letter codes, for example `US, DE`. More countries means more choice and a
   faster connection. See the privacy notes below before restricting this.
3. Leave the **Local port** at `9250` unless another program on your Mac already uses it.
4. Press **Test**. The first test can take up to a minute while Tor connects. A successful test reports the number of
   proxies and an exit IP address.
5. Press **Save**, and make sure the switch next to the Tor provider is on.

## 3. Use it

1. Turn the main switch on. The first start can take up to a minute. Later starts take a few seconds.
2. The **Exit IP** tile should show an address that is not your own.
3. To confirm that traffic leaves through Tor, run:

   ```bash
   curl -x http://127.0.0.1:8888 https://check.torproject.org/api/ip
   ```

   The response should contain `"IsTor":true`. The `-x` option is required because `curl` ignores the Mac's proxy settings.

## How rotation works with Tor

- Tor is a single local entry point that provides many exit addresses, so the dashboard reports the source as rotating
  rather than as a number of proxies.
- **Random** mode uses a new route for every connection, so the address changes constantly.
- **Sticky** mode gives each website its own route and keeps it for the sticky time. This is best effort. Tor may switch
  routes if a relay fails, and a newly started Tor sometimes switches once or twice in its first few requests. Kagewon
  sends a few warm-up requests to reduce this.

## Privacy notes

- Tor exit relays can read and alter traffic that is not encrypted. Prefer HTTPS sites, and do not send passwords over
  plain HTTP.
- Restricting exit countries reduces the number of possible routes, which can reduce anonymity and slow connections.
- Logging in to your own accounts over Tor tells those sites who you are, even though your IP address is hidden.
  Browser fingerprinting also still applies.
- Tor is not a VPN. Only traffic that follows the Mac's proxy settings uses it, and some applications ignore those settings.
- Tor listens on a local port (9250 by default) while the proxy is on. Any program on your Mac can connect to it.
- Do not use Tor for file sharing. It is slow and harms the network. Tor may be restricted or illegal in some countries;
  check your local rules.

## Troubleshooting

| What you see | What to do |
|---|---|
| "Tor is not installed" | Run `brew install tor` in Terminal, then try again. |
| "Tor did not finish starting" | Your network may block Tor, as some workplaces, schools, and countries do. Try another network or a phone hotspot. |
| "Could not bind" or "Address already in use" | Another program uses port 9250. Choose a different **Local port** for the provider. |
| The exit IP does not change | Make sure **Random** is selected, and that the Tor switch is on and the others are off. In Sticky mode a site keeps its address for the sticky time. |
| Websites show CAPTCHAs or refuse you | Many sites block Tor exit relays. Use another provider for those sites. |
| It is very slow | This is normal for Tor, and restricting exit countries can make it slower. |
