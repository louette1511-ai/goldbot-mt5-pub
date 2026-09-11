"""Railway/Wine compatibility probe for the GoldBot demo trial. TRADING IS DISABLED.

Proves only what it prints. Never sends an order: MetaTrader5.order_send is not called
anywhere in this file and the module is monkey-patched shut below as a belt-and-braces
guard. Never prints a credential.
"""
import json
import os
import sys
import time
from datetime import datetime, timezone

import MetaTrader5 as m

# Hard guard: this probe must never be able to trade, even by mistake.
def _blocked(*_a, **_k):
    raise RuntimeError('PROBE_IS_READ_ONLY_ORDER_SEND_BLOCKED')
m.order_send = _blocked

# No account identity is baked into this image: the published container carries
# nothing about whose account it connects to. Login and server come from the
# host's environment, and a missing one is a hard stop rather than a default.
TERMINAL = os.environ.get('MT5_TERMINAL', r'C:\MT5\terminal64.exe')
_login = os.environ.get('MT5_DEMO_LOGIN')
SERVER = os.environ.get('MT5_DEMO_SERVER')
LOGIN = int(_login) if _login else 0
SYMBOLS = ('EURUSDm', 'GBPUSDm', 'USDJPYm', 'AUDUSDm', 'NZDUSDm',
           'USDCADm', 'USDCHFm', 'EURGBPm', 'EURJPYm', 'AUDJPYm')

results = {}
failures = []


def step(name, ok, detail=''):
    line = f'{name} {"ok" if ok else "FAIL"} {detail}'.rstrip()
    print(line, flush=True)
    results[name] = {'ok': bool(ok), 'detail': detail}
    if not ok:
        failures.append(name)
    return ok


def main():
    password = os.environ.get('MT5_DEMO_PASSWORD')
    missing = [n for n, v in (('MT5_DEMO_LOGIN', LOGIN), ('MT5_DEMO_SERVER', SERVER),
                              ('MT5_DEMO_PASSWORD', password)) if not v]
    if missing:
        step('MT5_CREDENTIAL', False, 'not set in environment: ' + ', '.join(missing))
        return

    # 1. Terminal starts under Wine and the Python bridge attaches.
    if not m.initialize(TERMINAL, login=LOGIN, password=password, server=SERVER, timeout=60000):
        step('MT5_CONNECTED', False, f'initialize failed code={m.last_error()}')
        return
    del password
    t = m.terminal_info()
    step('MT5_CONNECTED', bool(t and t.connected),
         f'build={getattr(t, "build", "?")} connected={getattr(t, "connected", None)}')

    # 2. Exact demo identity. Anything else is a hard stop.
    a = m.account_info()
    if a is None:
        step('DEMO_VERIFIED', False, 'account_info() returned None')
        return
    identity = (a.login, a.server, a.currency, a.trade_mode, a.leverage)
    expected = (LOGIN, SERVER, 'ZAR', m.ACCOUNT_TRADE_MODE_DEMO, 20)
    step('DEMO_VERIFIED', identity == expected,
         f'login={a.login} server={a.server} currency={a.currency} '
         f'demo={a.trade_mode == m.ACCOUNT_TRADE_MODE_DEMO} leverage={a.leverage} '
         f'equity={a.equity} balance={a.balance} trade_allowed={a.trade_allowed}')

    # 3. Live quotes and CLOSED candles for every pair the runner scans.
    now = time.time()
    quote_rows, bad = [], []
    for s in SYMBOLS:
        if not m.symbol_select(s, True):
            bad.append(f'{s}:select_failed')
            continue
        tick = m.symbol_info_tick(s)
        bars = m.copy_rates_from_pos(s, m.TIMEFRAME_M15, 1, 2)  # bar 1 = last CLOSED
        if tick is None or bars is None or len(bars) < 2:
            bad.append(f'{s}:no_data')
            continue
        tick_age = round(now - tick.time, 1)
        bar_age = round(now - int(bars[-1]['time']), 1)
        quote_rows.append({'symbol': s, 'bid': tick.bid, 'ask': tick.ask,
                           'tick_age_s': tick_age, 'closed_bar_age_s': bar_age})
        print(f'  QUOTE {s} bid={tick.bid} ask={tick.ask} '
              f'tick_age={tick_age}s closed_bar_age={bar_age}s', flush=True)
    step('QUOTES_OK', len(quote_rows) == len(SYMBOLS),
         f'{len(quote_rows)}/{len(SYMBOLS)} symbols' + (f' bad={bad}' if bad else ''))
    results['quotes'] = quote_rows

    # 4. Broker-side positions with their SL/TP, read from the cloud host.
    positions = m.positions_get() or ()
    for p in positions:
        print(f'  POSITION ticket={p.ticket} {p.symbol} type={p.type} volume={p.volume} '
              f'magic={p.magic} sl={p.sl} tp={p.tp} profit={p.profit}', flush=True)
    step('POSITIONS_READ', True, f'{len(positions)} open')
    results['positions'] = [{'ticket': p.ticket, 'symbol': p.symbol, 'magic': p.magic,
                             'volume': p.volume, 'sl': p.sl, 'tp': p.tp} for p in positions]

    # 5. Telegram from inside the container.
    telegram()

    m.shutdown()


def telegram():
    token = os.environ.get('TELEGRAM_BOT_TOKEN')
    chat = os.environ.get('TELEGRAM_CHAT_ID')
    if not token or not chat:
        step('TELEGRAM', False, 'TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set')
        return
    import requests
    text = (f'PAPER ONLY | DEMO {LOGIN}\n'
            'Railway/Wine compatibility probe. Trading disabled, no order path reachable. '
            'This message proves only that the container can reach Telegram.')
    try:
        r = requests.post(f'https://api.telegram.org/bot{token}/sendMessage',
                          json={'chat_id': chat, 'text': text}, timeout=20)
        data = r.json()
    except Exception:
        # Never surface the exception: its URL carries the bot token.
        step('TELEGRAM', False, 'delivery failed')
        return
    if not data.get('ok'):
        step('TELEGRAM', False, 'telegram did not acknowledge')
        return
    step('TELEGRAM', True, f'SENT_TG ok id={data["result"]["message_id"]}')


if __name__ == '__main__':
    try:
        main()
    finally:
        results['at'] = datetime.now(timezone.utc).isoformat()
        results['failures'] = failures
        out = os.environ.get('PROBE_OUT', r'C:\probe-result.json')
        try:
            with open(out, 'w', encoding='utf-8') as fh:
                json.dump(results, fh, indent=2)
        except Exception:
            pass
        print('PROBE_RESULT ' + ('PASS' if not failures else 'FAIL ' + ','.join(failures)), flush=True)
        sys.exit(0 if not failures else 1)
