# Usage

Click the Kagewon icon in the menu bar. There is no configuration file to edit and no `.env` file. You paste your key
in the app.

| Area | Purpose |
|---|---|
| Dashboard | The power switch, your exit IP address, and the Sticky or Random rotation setting |
| Providers | Add, test, enable, disable, edit, and delete providers |
| Activity | Which site uses which proxy, and a live log |
| Settings | Local port, provider refresh interval, logging, and the kill switch (open it from the three-dot menu) |

Right-click the icon for a quick Turn On, Turn Off, and Quit.

## Providers

| Provider | What you provide |
|---|---|
| Webshare | Your API key. The proxy list and its logins are fetched automatically. |
| Tor | Nothing. Install Tor first; see [tor.md](tor.md). |

When several providers are enabled, the **Traffic share** value of each one controls how often it is used.

## Rotation

- **Sticky** keeps one IP address per website for a set time, so sessions and logins keep working. You choose the time on the
  dashboard, from 30 seconds to 4 hours in steps of 30 seconds (the default is 10 minutes). When the time is up,
  the address changes on its own, even if an application keeps its connection open. A switch controls this behavior,
  because closing connections interrupts downloads in progress.
- **Random** uses a new IP address for every connection. Logins may break.

## Kill switch

By default, if the helper process stops, the app switches the Mac's proxy settings off so that your internet keeps working
and your traffic goes out directly. The kill switch reverses this: the settings stay on, so applications that follow the
Mac's proxy settings cannot connect until the proxy is running again. The app also holds the proxy port with a listener
that drops every connection, so no other program on the Mac can take it over. Enable the kill switch in Settings if you
prefer losing the connection to exposing your real IP address. Press Try Again or quit the app to restore the connection.

If another program already owns the proxy port, blocking is impossible, because that program would receive your traffic. The
kill switch then says so, and when the app itself is force-quit the helper switches the settings off instead of leaving them
pointed at a stranger's listener.
