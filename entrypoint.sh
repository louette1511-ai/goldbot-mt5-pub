#!/usr/bin/env bash
# Runs the read-only MT5 probe under a virtual display, then idles so the container
# stays up for log inspection instead of restart-looping on exit.
set -uo pipefail
strip_wine_noise() { grep -v '^[0-9a-f]\{4,\}:' || true; }

# Single quotes: this is a literal Windows path for the Windows Python under Wine.
export MT5_TERMINAL='C:\MT5\terminal64.exe'
TERM_EXE='/wine/drive_c/MT5/terminal64.exe'

echo "PROBE_BOOT $(date -u +%Y-%m-%dT%H:%M:%SZ)"

xvfb-run -a wine /wine/drive_c/Python311/python.exe --version 2>&1 \
  | strip_wine_noise | sed 's/^/WINE_PYTHON /'
xvfb-run -a wine /wine/drive_c/Python311/python.exe -c \
  "import MetaTrader5 as m; print('MT5_PACKAGE ok', m.__version__)" 2>&1 | strip_wine_noise

if [ -f "$TERM_EXE" ]; then
  echo "TERMINAL_PRESENT ok $TERM_EXE $(stat -c%s "$TERM_EXE") bytes"
else
  echo "TERMINAL_PRESENT FAIL not staged at $TERM_EXE"
  ls -la /wine/drive_c/ 2>/dev/null | sed 's/^/  /'
fi

xvfb-run -a wine /wine/drive_c/Python311/python.exe /app/probe.py 2>&1 | strip_wine_noise

echo "PROBE_IDLE holding container up for log inspection"
sleep infinity
