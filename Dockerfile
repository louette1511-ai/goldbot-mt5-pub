# GoldBot MT5 compatibility probe: Wine + Windows Python + the Exness terminal.
# TRADING IS DISABLED in this image. probe.py monkey-patches order_send shut.
#
# Why the terminal is COPIED and not installed: MetaQuotes' web installer
# (mt5setup.exe /auto) was measured on Railway build 2a82f125 and installed
# NOTHING into the prefix - "Program Files" held only Wine's stock folders and
# find turned up no terminal64.exe. The binary this demo account already trades
# on is shipped instead, staged into terminal/ by hand.
FROM debian:bookworm-slim

ENV WINEARCH=win64 \
    WINEPREFIX=/wine \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    DEBIAN_FRONTEND=noninteractive

# mscoree/mshtml are disabled above so wineboot cannot hang on the Mono/Gecko
# install dialogs, which have no one to click them under a bare Xvfb.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg xvfb xauth cabextract procps tini \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
      -o /etc/apt/keyrings/winehq-archive.key \
 && curl -fsSL https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
      -o /etc/apt/sources.list.d/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends winehq-stable \
 && rm -rf /var/lib/apt/lists/*

RUN xvfb-run -a wineboot --init && wineserver -w

# Windows Python inside the prefix, because the MetaTrader5 wheel is win_amd64
# only - all nine PyPI wheels for 5.0.6180 are, so there is no Linux build to use.
# Wine's ShellExecuteEx fails intermittently launching this installer (seen on
# build d7332fad), so retry rather than fail the whole image on a flake.
ARG PYWIN=3.11.9
RUN curl -fsSL "https://www.python.org/ftp/python/${PYWIN}/python-${PYWIN}-amd64.exe" -o /tmp/py.exe \
 && for attempt in 1 2 3; do \
      echo "PY_INSTALL_ATTEMPT $attempt"; \
      xvfb-run -a wine /tmp/py.exe /quiet InstallAllUsers=1 PrependPath=1 \
        Include_test=0 TargetDir=C:/Python311 || true; \
      wineserver -w || true; \
      if [ -f /wine/drive_c/Python311/python.exe ]; then echo "PY_INSTALL_OK"; break; fi; \
      wineserver -k || true; \
    done \
 && rm -f /tmp/py.exe \
 && test -f /wine/drive_c/Python311/python.exe

RUN xvfb-run -a wine /wine/drive_c/Python311/python.exe -m pip install --no-cache-dir --upgrade pip \
 && xvfb-run -a wine /wine/drive_c/Python311/python.exe -m pip install --no-cache-dir \
      MetaTrader5==5.0.6180 requests \
 && wineserver -w \
 && xvfb-run -a wine /wine/drive_c/Python311/python.exe \
      -c "import MetaTrader5 as m; print('MT5_PACKAGE_IMPORT_OK', m.__version__)"

# The Exness-branded terminal, fetched at build time. The previous attempt used
# MetaQuotes' mt5setup.exe with '|| true' masking the result, and build 2a82f125
# went green on an EMPTY prefix. Nothing is masked here: every failure prints and
# the final test -f fails the build rather than shipping a terminal-less image.
ARG MT5_SETUP_URL=https://download.mql5.com/cdn/web/exness.technologies.ltd/mt5/exness5setup.exe
RUN set -x \
 && curl -fsSL "$MT5_SETUP_URL" -o /tmp/mt5setup.exe \
 && ls -l /tmp/mt5setup.exe \
 && (timeout 600 xvfb-run -a wine /tmp/mt5setup.exe /auto; echo "INSTALLER_EXIT=$?") \
 && sleep 20 \
 && (wineserver -k || true) \
 && echo "--- prefix tree after installer ---" \
 && ls -la "/wine/drive_c/Program Files/" "/wine/drive_c/Program Files (x86)/" 2>&1 | head -40 \
 && find /wine/drive_c -maxdepth 4 -iname 'terminal64.exe' -print \
 && FOUND=$(find /wine/drive_c -maxdepth 4 -iname 'terminal64.exe' -print -quit) \
 && echo "FOUND_TERMINAL=$FOUND" \
 && test -n "$FOUND" \
 && MT5DIR=$(dirname "$FOUND") \
 && echo "MT5_INSTALL_DIR=$MT5DIR" \
 && ls -la "$MT5DIR" \
 && mkdir -p /wine/drive_c/MT5 \
 && cp -a "$MT5DIR"/. /wine/drive_c/MT5/ \
 && rm -f /wine/drive_c/MT5/MetaEditor64.exe \
          /wine/drive_c/MT5/metatester64.exe \
          /wine/drive_c/MT5/uninstall.exe \
 && rm -f /tmp/mt5setup.exe \
 && test -s /wine/drive_c/MT5/terminal64.exe \
 && SRVDAT=$(find /wine/drive_c/MT5 -maxdepth 2 -iname 'servers.dat' -print -quit) \
 && echo "SERVERS_DAT=$SRVDAT" \
 && test -n "$SRVDAT" \
 && echo "TERMINAL_STAGED_OK" \
 && ls -la /wine/drive_c/MT5/

ARG CACHEBUST=1
WORKDIR /app
COPY probe.py entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

# tini reaps the terminal and wineserver; bash is named explicitly so a stray
# CRLF shebang can never reproduce the env: 'bash\r' crash loop again.
ENTRYPOINT ["/usr/bin/tini","--","/bin/bash","/app/entrypoint.sh"]
