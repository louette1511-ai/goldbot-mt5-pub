# goldbot-mt5-pub

Public build context for a Linux container image that runs the MetaTrader 5
terminal under Wine, together with the Windows build of the `MetaTrader5`
Python package, so the MT5 Python bridge can be used on a Linux host.

Why this repository is public: the resulting container image needs to be
pullable anonymously by a hosting provider. The image itself is generic.

**Nothing here carries an account.** No login, server name, password, chat id
or API token is present in any file or in the git history. Every one of those
values is read from the runtime environment, and a missing one is a hard stop
rather than a default.

`probe.py` is read-only by construction: it monkey-patches `order_send` shut
before connecting, so the image cannot place an order.

## Contents

| File | Purpose |
| --- | --- |
| `Dockerfile` | Debian + WineHQ stable + Xvfb, Windows Python 3.11.9 inside the Wine prefix, `MetaTrader5==5.0.6180`, and the Exness MT5 terminal installed at build time |
| `probe.py` | Read-only connectivity probe: terminal connection, account identity, quotes, open positions |
| `entrypoint.sh` | Starts Xvfb, runs the probe, holds the container up for log inspection |
| `.github/workflows/build.yml` | Builds and pushes the image to GHCR |
