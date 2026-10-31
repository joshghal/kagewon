# Security policy

## Reporting a vulnerability

Please report security problems privately. Do not open a public issue that describes them.

Preferred: use GitHub's private vulnerability reporting. Open the **Security** tab of the repository and choose **Report a
vulnerability**. If that button is not shown, the maintainer has not enabled it yet.

If you cannot use it, open a public issue titled "Security contact request" that says nothing about the problem itself. The
maintainer will arrange a private channel.

Include:

- The Kagewon version (see `package.json`), your macOS version, and your Node.js version
- Steps to reproduce the problem
- What an attacker could achieve, and what they would need first

Do not include real API keys, proxy logins, or the contents of `config.json` in a report.

Kagewon is an independent project that is maintained in spare time, so replies are best effort. If you want to be credited
for a report, say so.

## Supported versions

Kagewon is in beta. Only the latest version on the `main` branch receives fixes.

## Scope

In scope:

- The local proxy and the control interface: who can reach them and what they can be made to do
- How API keys and `config.json` are stored, logged, and passed between processes
- The changes made to the Mac's proxy settings, and whether they are always undone
- The destination filter: any way for a request to a local or private address to reach a provider
- Starting, stopping, and cleaning up the helper process and Tor
- The build script

Out of scope (these are documented in the README, under Safety guidance):

- What a proxy provider or a Tor exit relay can see of your traffic
- Applications that ignore the Mac's proxy settings
- Anyone who can already run programs as your user, because they can read `config.json`
- Vulnerabilities in Webshare, Tor, macOS, or Node.js themselves; please report those to their maintainers
- Use of the tool for activities that are not permitted

## If your key may have leaked

Revoke the key in your Webshare dashboard, then paste a new one in the app.
