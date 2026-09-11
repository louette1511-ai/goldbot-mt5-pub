#!/usr/bin/env bash
# Runs the read-only MT5 probe under a virtual display, then idles so the container
# stays up for log inspection instead of restart-looping on exit.
#
# One Xvfb for the whole script, not one per command: the terminal is launched in
# the background and has to outlive the command that started it.
set -uo pipefail
strip_wine_noise() { grep -v '^[0-9a-f]\{4,\}:' || true; }

# Single quotes: this is a literal Windows path for the Windows Python under Wine.
export MT5_TERMINAL='C:\MT5\terminal64.exe'
TERM_EXE='/wine/drive_c/MT5/terminal64.exe'
export DISPLAY=:99

echo "PROBE_BOOT $(date -u +%Y-%m-%dT%H:%M:%SZ)"

Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 30); do
  [ -S /tmp/.X11-unix/X99 ] && break
  sleep 1
done
if [ -S /tmp/.X11-unix/X99 ]; then
  echo "XVFB_READY pid=$XVFB_PID display=$DISPLAY"
else
  echo "XVFB_FAIL no socket after 30s"
  tail -5 /tmp/xvfb.log 2>/dev/null | sed 's/^/  /'
fi

wine /wine/drive_c/Python311/python.exe --version 2>&1 \
  | strip_wine_noise | sed 's/^/WINE_PYTHON /'
wine /wine/drive_c/Python311/python.exe -c \
  "import MetaTrader5 as m; print('MT5_PACKAGE ok', m.__version__)" 2>&1 | strip_wine_noise

if [ -f "$TERM_EXE" ]; then
  echo "TERMINAL_PRESENT ok $TERM_EXE $(stat -c%s "$TERM_EXE") bytes"
else
  echo "TERMINAL_PRESENT FAIL not staged at $TERM_EXE"
  ls -la /wine/drive_c/ 2>/dev/null | sed 's/^/  /'
fi

# servers.dat is the broker server list. Without it the terminal cannot resolve
# the demo server name at all, and the Python bridge dies on an IPC timeout.
SRVDAT=$(find /wine/drive_c/MT5 -maxdepth 2 -iname 'servers.dat' -print -quit 2>/dev/null)
if [ -n "$SRVDAT" ]; then
  echo "SERVERS_DAT ok $SRVDAT $(stat -c%s "$SRVDAT") bytes"
else
  echo "SERVERS_DAT FAIL not found under /wine/drive_c/MT5"
  ls -la /wine/drive_c/MT5/ 2>/dev/null | sed 's/^/  /'
fi

# Auto-login config, written at runtime from the environment and never baked into
# the image. Values are not echoed.
INI='/wine/drive_c/MT5/autologin.ini'
if [ -n "${MT5_DEMO_LOGIN:-}" ] && [ -n "${MT5_DEMO_SERVER:-}" ] && [ -n "${MT5_DEMO_PASSWORD:-}" ]; then
  ( umask 077
    printf '[Common]\r\nLogin=%s\r\nPassword=%s\r\nServer=%s\r\n' \
      "$MT5_DEMO_LOGIN" "$MT5_DEMO_PASSWORD" "$MT5_DEMO_SERVER" > "$INI" )
  echo "AUTOLOGIN_INI written $(stat -c%s "$INI") bytes"
  wine "$MT5_TERMINAL" '/config:C:\MT5\autologin.ini' >/tmp/terminal.log 2>&1 &
else
  echo "AUTOLOGIN_INI skipped: MT5_DEMO_LOGIN / MT5_DEMO_SERVER / MT5_DEMO_PASSWORD not all set"
  wine "$MT5_TERMINAL" >/tmp/terminal.log 2>&1 &
fi
echo "TERMINAL_LAUNCHED"

for i in $(seq 1 20); do
  if pgrep -f 'terminal64.exe' >/dev/null 2>&1; then
    echo "TERMINAL_RUNNING after ${i}s"
    break
  fi
  sleep 1
done
pgrep -f 'terminal64.exe' >/dev/null 2>&1 || {
  echo "TERMINAL_NOT_RUNNING after 20s"
  tail -20 /tmp/terminal.log 2>/dev/null | strip_wine_noise | sed 's/^/  /'
}

# Let the terminal build its profile and complete the broker handshake before the
# bridge attaches. probe.py retries on top of this.
sleep 45
echo "TERMINAL_SETTLED"

wine /wine/drive_c/Python311/python.exe /app/probe.py 2>&1 | strip_wine_noise

echo "--- terminal log tail ---"
tail -30 /tmp/terminal.log 2>/dev/null | strip_wine_noise | sed 's/^/  /'
find /wine/drive_c/MT5 -maxdepth 3 -iname '*.log' -newermt '-30 minutes' 2>/dev/null \
  | head -5 | while read -r f; do echo "--- $f ---"; tail -20 "$f" | sed 's/^/  /'; done

echo "PROBE_IDLE holding container up for log inspection"
sleep infinity
