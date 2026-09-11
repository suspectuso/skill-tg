# Observability — metrics, logs, and reconstructing what happened

## Contents
- What to expose as metrics
- aiogram middleware for the bot-level metrics
- Go / prometheus/client_golang
- Bot API call metrics — wrapping the client
- Structured logging — the log line you need at 3 AM
- `logfmt` for readable-in-terminal but still-machine-parseable output
- Traces / correlation ids for external calls
- The "user journey" query
- Health check endpoint
- Alerts — what to page on
- Dashboards — Grafana starter panels
- Common mistakes

The 3 AM debugging question is "why did this user drop off / see nothing / get double-charged?".
Answering it requires three things: metrics that tell you *what's* broken at a glance,
structured logs that let you trace *one specific update* end-to-end, and enough state in the DB
to reconstruct the user's journey after the fact.

## What to expose as metrics

The core set that lets you answer 80% of "is the bot healthy?" questions:

**Bot-level:**
- `tg_updates_total{type}` — counter of updates received, labelled by type (message, callback_query,
  chat_member, my_chat_member, chat_join_request, pre_checkout_query, successful_payment,
  inline_query).
- `tg_handler_seconds{handler}` — histogram of handler latency, labelled by handler name.
- `tg_handler_errors_total{handler,exc_type}` — counter of unhandled exceptions.
- `tg_api_seconds{method}` — histogram of outbound Bot API call latency, labelled by method
  (`sendMessage`, `editMessageText`, …).
- `tg_api_errors_total{method,error_code}` — counter of Bot API 4xx/5xx.
- `tg_webhook_pending_updates` — gauge, polled from `getWebhookInfo` every minute; alert when
  it grows.

**Business-level:**
- `bot_new_users_total{lang}` — counter of `/start`s from new users.
- `bot_paid_total{gateway,plan}` + `bot_paid_amount_total{gateway,plan}` — one counter of
  events, one of monetary sum.
- `bot_active_users` — gauge, computed from DAU/MAU rolling windows.
- `bot_broadcast_running` — gauge (0 or 1).

**Infra-level:**
- Standard Python / Go runtime metrics (memory, goroutine count, GC, event-loop lag). Free
  from `prometheus_client` / `prometheus/client_golang`.

## aiogram middleware for the bot-level metrics

```python
# middlewares/metrics.py
import time
from aiogram import BaseMiddleware
from aiogram.types import Update, TelegramObject
from prometheus_client import Counter, Histogram

UPDATES  = Counter("tg_updates_total", "updates received", ["type"])
LATENCY  = Histogram("tg_handler_seconds", "handler latency", ["handler"])
ERRORS   = Counter("tg_handler_errors_total", "handler errors", ["handler", "exc_type"])


class MetricsMiddleware(BaseMiddleware):
    async def __call__(self, handler, event: TelegramObject, data):
        # update type is set by aiogram in the outer scope; approximate here
        upd_type = type(event).__name__
        UPDATES.labels(type=upd_type).inc()

        handler_name = getattr(handler, "__qualname__", "unknown")
        t0 = time.perf_counter()
        try:
            return await handler(event, data)
        except Exception as e:
            ERRORS.labels(handler=handler_name, exc_type=type(e).__name__).inc()
            raise
        finally:
            LATENCY.labels(handler=handler_name).observe(time.perf_counter() - t0)


dp.message.middleware(MetricsMiddleware())
dp.callback_query.middleware(MetricsMiddleware())
dp.chat_member.middleware(MetricsMiddleware())
# … every dispatcher scope you use handlers on
```

Exposition endpoint (aiohttp):

```python
from prometheus_client import make_asgi_app
from aiohttp import web
from prometheus_client.exposition import generate_latest, CONTENT_TYPE_LATEST


async def metrics_handler(_req):
    return web.Response(body=generate_latest(), content_type=CONTENT_TYPE_LATEST)


# in your webhook-server / standalone metrics server:
app.router.add_get("/metrics", metrics_handler)
```

Bind on `127.0.0.1:9090` and scrape with Prometheus over an SSH tunnel, or on the private
network if you have one. Never expose `/metrics` publicly — it leaks handler names, error
patterns, sometimes user identifiers via labels.

## Go / prometheus/client_golang

```go
// internal/observability/metrics.go
package observability

import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    Updates = promauto.NewCounterVec(
        prometheus.CounterOpts{Name: "tg_updates_total", Help: "updates received"},
        []string{"type"},
    )
    HandlerLatency = promauto.NewHistogramVec(
        prometheus.HistogramOpts{Name: "tg_handler_seconds", Help: "handler latency",
            Buckets: prometheus.DefBuckets},
        []string{"handler"},
    )
    APIErrors = promauto.NewCounterVec(
        prometheus.CounterOpts{Name: "tg_api_errors_total", Help: "bot api errors"},
        []string{"method", "error_code"},
    )
)
```

telebot middleware:

```go
b.Use(func(next tele.HandlerFunc) tele.HandlerFunc {
    return func(c tele.Context) error {
        start := time.Now()
        name  := handlerNameFrom(c)         // "start", "cb:balance", …
        Updates.WithLabelValues(updateType(c)).Inc()
        err := next(c)
        HandlerLatency.WithLabelValues(name).Observe(time.Since(start).Seconds())
        return err
    }
})
```

Metrics HTTP handler on a dedicated `net/http` server; same rule — private port only.

## Bot API call metrics — wrapping the client

Instead of trying to instrument every `bot.send_message` call site, wrap the underlying
`Session`/`Bot` transport once:

```python
# aiogram — subclass AiohttpSession
from aiogram.client.session.aiohttp import AiohttpSession
from prometheus_client import Counter, Histogram

API_LATENCY = Histogram("tg_api_seconds", "bot API call latency", ["method"])
API_ERRORS  = Counter("tg_api_errors_total", "bot API errors", ["method", "error_code"])


class MeasuredSession(AiohttpSession):
    async def make_request(self, bot, method, *args, **kwargs):
        import time
        t0 = time.perf_counter()
        try:
            result = await super().make_request(bot, method, *args, **kwargs)
            return result
        except TelegramAPIError as e:
            API_ERRORS.labels(method=method.__api_method__,
                              error_code=getattr(e, "code", "unknown")).inc()
            raise
        finally:
            API_LATENCY.labels(method=method.__api_method__).observe(time.perf_counter() - t0)


bot = Bot(TOKEN, session=MeasuredSession())
```

Now every `sendMessage`, `editMessageText`, `answerCallbackQuery` etc. shows up in the metric
without touching handler code.

## Structured logging — the log line you need at 3 AM

Every log line should carry enough labels to run `grep` and reconstruct a single user's
journey. Minimum labels:

- `update_id` — unique per incoming update; correlates all logs for one action.
- `user_id` — the Telegram user id.
- `chat_id` — where the action happened.
- `handler` — which handler processed it.
- `screen` — which UI screen the user is on (from FSM state or callback data).

```python
# aiogram outer middleware — inject context into logging
import logging, contextvars
from aiogram import BaseMiddleware

_current: contextvars.ContextVar = contextvars.ContextVar("tg_ctx", default={})


class LogContextMiddleware(BaseMiddleware):
    async def __call__(self, handler, event, data):
        upd = data.get("event_update")
        ctx = {
            "update_id": getattr(upd, "update_id", None),
            "user_id":   getattr(event, "from_user", None) and event.from_user.id,
            "chat_id":   getattr(event, "chat", None) and event.chat.id,
        }
        token = _current.set(ctx)
        try:
            return await handler(event, data)
        finally:
            _current.reset(token)


class ContextFilter(logging.Filter):
    def filter(self, record):
        for k, v in _current.get().items():
            setattr(record, k, v)
        return True


logging.basicConfig(
    level=logging.INFO,
    format='{"ts":"%(asctime)s","lvl":"%(levelname)s","msg":"%(message)s",'
           '"update_id":%(update_id)s,"user_id":%(user_id)s,"chat_id":%(chat_id)s,'
           '"logger":"%(name)s"}',
)
for h in logging.root.handlers:
    h.addFilter(ContextFilter())
```

The JSON format lets Loki / ELK / CloudWatch parse each field automatically. Handlers just do
`log.info("purchase_initiated", extra={"amount": 50, "plan": "1m"})` — the context is added by
the filter.

## `logfmt` for readable-in-terminal but still-machine-parseable output

If you don't have a log aggregator yet, `key=value` on one line is human-friendly and greppable:

```
2026-09-10T21:12:34Z INFO purchase_initiated user_id=12345 chat_id=12345 amount=50 plan=1m gateway=cryptobot
```

Trivial parser: `python -c "import re, sys; [print(dict(re.findall(r'(\w+)=(\S+)', l))) for l in sys.stdin]"`.
`journalctl -u bot -f | grep user_id=12345` becomes the "trace this user" command.

## Traces / correlation ids for external calls

Give each incoming update a correlation id (aiogram's `update_id` is fine) and pass it through
to every external call:

```python
async def create_invoice(user_id, amount, gateway, *, trace_id):
    log.info("invoice_create_start", extra={"gateway": gateway, "trace_id": trace_id})
    resp = await gateway_api.create(amount, extra={"X-Trace-Id": trace_id})
    log.info("invoice_create_done", extra={"gateway": gateway, "trace_id": trace_id,
                                            "invoice_id": resp.id})
    return resp
```

Then when a webhook comes back and you don't know which user it's for, the log line for that
invoice id has the `trace_id` which has the `update_id` which has the `user_id`.

## The "user journey" query

Once you're logging with `user_id`, reconstructing a specific user's session is a `SELECT`:

```sql
SELECT ts, msg, extra
FROM   bot_logs
WHERE  extra->>'user_id' = '12345'
  AND  ts > now() - interval '2 hours'
ORDER  BY ts;
```

If you use Loki: `{app="bot"} | json | user_id = "12345" | line_format "{{.ts}} {{.msg}} {{.extra}}"`.

Handy variants:

- **Where did users drop off between `/start` and first purchase?**
  ```sql
  WITH t AS (SELECT extra->>'user_id' AS uid, MIN(ts) FILTER (WHERE msg='start') AS start_at,
                    MIN(ts) FILTER (WHERE msg='purchase_paid') AS paid_at
             FROM bot_logs GROUP BY 1)
  SELECT count(*) FILTER (WHERE start_at IS NOT NULL) AS started,
         count(*) FILTER (WHERE paid_at  IS NOT NULL) AS paid,
         count(*) FILTER (WHERE paid_at  IS NULL AND start_at < now()-'1d') AS dropped
  FROM t;
  ```

- **Which callback_data 404s (handler missing)?**
  Log every callback with `callback_data` label; a callback with no matching handler still
  gets `cb.answer()` from a fallback — log the fallback fires with the data.

## Health check endpoint

```python
# webhook_server.py — add a /healthz
@routes.get("/healthz")
async def healthz(_req):
    try:
        await asyncio.wait_for(bot.get_me(), timeout=3.0)
        await DB.execute("SELECT 1")
        return web.Response(text="ok")
    except Exception as e:
        return web.Response(text=f"unhealthy: {e}", status=503)
```

Bind on `127.0.0.1`, wire to `systemd`'s `WatchdogSec=` (systemd will restart the process if
it stops writing the watchdog signal), or hit from your uptime monitor via SSH tunnel /
private network.

## Alerts — what to page on

Not everything. Only the alerts that require human action:

- `tg_webhook_pending_updates > 100 for 2m` — updates are queueing at Telegram, deploy is down.
- `rate(tg_api_errors_total{error_code=~"4.."}[5m]) > 1/s` — you started shipping bad requests,
  bot code regression.
- `rate(tg_api_errors_total{error_code="429"}[1m]) > 0` — rate-limited by Telegram, something
  is spamming (bug or intentional broadcast without throttle).
- `process_resident_memory_bytes > $threshold` — memory leak.
- `bot_paid_total: no increase in 6 h during business hours` — payment gateway is down or
  webhook broken (harder to detect but valuable).

Non-alerts (they belong on dashboards, not pagers): update rate spikes, handler latency drift,
individual handler error counts.

## Dashboards — Grafana starter panels

1. **Health strip**: `tg_webhook_pending_updates`, `up{job="bot"}`, error rate 5-min. Big
   numbers, red when bad.
2. **Traffic**: `sum by (type) (rate(tg_updates_total[5m]))` — one line per update type.
3. **Latency heat-map**: `sum by (le) (rate(tg_handler_seconds_bucket[5m]))` — heat-map of p50-p99.
4. **API errors**: `sum by (method, error_code) (rate(tg_api_errors_total[5m]))`.
5. **Business**: `rate(bot_paid_total[1h])`, `sum(bot_paid_amount_total)` (converted to your
   currency at query time), `bot_active_users`.

Keep dashboards short. Six panels people look at every morning beat sixty they never open.

## Common mistakes

| Symptom | Cause |
|---|---|
| `/metrics` endpoint exposed publicly, gets scraped by attackers | Bind on `127.0.0.1`, tunnel to Prometheus; or nginx `allow`-list your prometheus server IP |
| Cardinality explodes with `user_id` as a label | **Never use user_id as a metric label.** High-cardinality labels blow up Prometheus's memory. Put user_id in logs, not metrics |
| Handler latency metric mixes fast and slow handlers | Handler name label distinguishes them — but if you register a single "generic" handler for many callbacks, sub-label by `callback_data` prefix |
| Logs are unparseable JSON when a message contains a quote | `logging.Formatter` doesn't escape. Use `python-json-logger` or a structured logger like `structlog` |
| `getWebhookInfo` scrape adds noise to `sendMessage` metrics | It's a `getWebhookInfo` API call — label your metric by method, so it lands separately |
| Log context lost across `asyncio.create_task` | Contextvars propagate, but only if you don't `run_in_executor`. For threads, capture the ctx explicitly and set it in the thread |
| Adding a new handler skips metrics because middleware wasn't attached to that scope | aiogram scopes: `dp.message`, `dp.callback_query`, `dp.chat_member`, `dp.my_chat_member`, `dp.pre_checkout_query`, `dp.chosen_inline_result`, … — attach middleware to each you use |
| Prometheus alert is too flappy | Use `for: 2m` / `for: 5m` on burn conditions; add a `min_samples` check so a 60-second outage during a deploy doesn't page |
| Business metric misses events because it's incremented after the DB commit | Increment BOTH in the DB (idempotent) AND in a metric; on process restart, reconstruct the gauge from the DB but recognise the counter is best-effort |
| Health check succeeds but bot is unresponsive | `getMe` cached at Telegram edge; ping via `getUpdates` with a short timeout, or `getWebhookInfo` — those are real round-trips |
| Structured logs fine locally, look empty on server | `journalctl` truncates long lines; pipe to Loki / a file with `LineMax` unset; or write to `stdout` and let systemd's journal store as-is |
