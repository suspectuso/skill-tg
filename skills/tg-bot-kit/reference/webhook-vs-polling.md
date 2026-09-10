# Webhook vs long-polling — receiving Bot updates

Two ways to receive updates from Telegram. Same Bot API, very different failure modes.

## The trade-off, without the marketing

| | Long-polling (`getUpdates`) | Webhook (`setWebhook`) |
|---|---|---|
| Setup | zero — just start the poller | HTTPS endpoint reachable from Telegram, valid cert, `setWebhook` call |
| Public IP needed | no (outbound only) | yes (or a tunnel) |
| Latency to receive update | 0-100 ms (poller returns immediately when Telegram has data) | 0-100 ms (Telegram calls your endpoint) |
| Scale | one process consumes everything | multiple workers can share via a queue behind the webhook |
| Downtime recovery | Telegram queues updates for up to **24 h**; poller drains them on restart | Telegram retries with backoff for **~24 h**; then updates are lost |
| Debugging | `journalctl -u bot -f` shows every incoming update | Need nginx logs + your app logs + Telegram's opaque retry state |
| Firewalls | works behind any NAT | doesn't work behind NAT without a tunnel |
| Local dev | works everywhere | needs cloudflared / ngrok / `--test-server` |
| SSL cert | not needed | Let's Encrypt (Telegram accepts any CA-signed valid cert since 2020; self-signed is legacy) |

**Default: long-polling.** Switch to webhook only when you have a specific reason:

- Multi-worker deployment (load-balanced behind a queue).
- A serverless runtime that can't hold long-lived outbound connections (Cloudflare Workers,
  AWS Lambda).
- You need webhook-URL-based multi-tenancy (one process handles N bots, dispatched by path).

Long-polling is what 90% of production bots run.

## Long-polling — the shape

aiogram 3:

```python
from aiogram import Bot, Dispatcher
from aiogram.enums import ParseMode
from aiogram.client.default import DefaultBotProperties

bot = Bot(TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
dp  = Dispatcher()

if __name__ == "__main__":
    import asyncio
    asyncio.run(dp.start_polling(
        bot,
        allowed_updates=dp.resolve_used_update_types(),   # important, see below
        # drop_pending_updates=False,                     # keep queued updates by default
    ))
```

Go telebot.v3:

```go
b, err := tele.NewBot(tele.Settings{
    Token:  os.Getenv("BOT_TOKEN"),
    Poller: &tele.LongPoller{Timeout: 10 * time.Second},
})
// register handlers …
b.Start()   // blocks
```

Both libraries hold one long-lived HTTP connection to `api.telegram.org` and re-open it each
time a batch of updates arrives or the timeout expires. Systemd `Restart=always` covers the rest.

### `allowed_updates` — the update type whitelist

By default Telegram sends **every update type** — including ones you don't handle. That's
wasteful bandwidth and it makes it painful to add a new update type later: Telegram treats the
first `getUpdates` call as authoritative and caches your list until the bot restarts, so a
newly-added `chat_join_request` handler receives nothing until then.

aiogram's `dp.resolve_used_update_types()` reads the handlers you actually registered and
passes them as `allowed_updates` — self-documenting and self-updating. Do use it.

### `drop_pending_updates=True` — the double-edged sword

Passes `offset=-1` on the first `getUpdates`, effectively marking everything currently queued
as consumed. Use when:

- You deployed a broken version, users tapped buttons, now the queue has thousands of stale
  callback_query updates that would blow up the fresh version. Drain them once.

Do **not** use as a default. On every restart it silently drops legit updates users sent
during your downtime.

### Two bot processes racing for `getUpdates`

`getUpdates` uses `offset` semantics: the next call must specify `offset > id_of_last_delivered`,
which acks all prior updates. **Only one poller can be alive at a time** — a second poller
grabs the same batch and both handlers fire, or Telegram rejects one with `409 Conflict`.

Symptoms of a stray second poller:

- `terminated by other getUpdates request` in logs.
- Button styles / custom emoji intermittently missing — the two processes race on
  `editMessageReplyMarkup` and the loser's edit lands last.
- Duplicate replies to `/start`.

Fix: `ps auxf | grep -v grep | grep bot`. Kill everything not owned by systemd. This is the
single most common "prod bot is weird today" root cause.

## Webhook mode — the shape

```python
# app.py — aiohttp-based webhook mode
from aiohttp import web
from aiogram import Bot, Dispatcher
from aiogram.webhook.aiohttp_server import SimpleRequestHandler, setup_application

WEBHOOK_PATH   = "/tg/webhook"                            # any path you want
WEBHOOK_SECRET = os.environ["TG_WEBHOOK_SECRET"]          # random 32-char string

bot = Bot(TOKEN)
dp  = Dispatcher()
# register handlers …

async def on_startup(app: web.Application):
    await bot.set_webhook(
        url=f"{PUBLIC_URL}{WEBHOOK_PATH}",
        secret_token=WEBHOOK_SECRET,
        allowed_updates=dp.resolve_used_update_types(),
        drop_pending_updates=False,
    )

async def on_shutdown(app: web.Application):
    await bot.delete_webhook()

def main():
    app = web.Application()
    app.on_startup.append(on_startup)
    app.on_shutdown.append(on_shutdown)

    SimpleRequestHandler(dispatcher=dp, bot=bot,
                         secret_token=WEBHOOK_SECRET).register(app, path=WEBHOOK_PATH)
    setup_application(app, dp, bot=bot)
    web.run_app(app, host="127.0.0.1", port=8081)
```

nginx in front:

```nginx
location /tg/webhook {
    proxy_pass http://127.0.0.1:8081;
    proxy_set_header X-Real-IP        $remote_addr;
    proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # optional but recommended: reject requests from non-Telegram IPs
    allow 91.108.4.0/22; allow 91.108.56.0/22;
    allow 149.154.160.0/20; allow 91.108.12.0/22; allow 149.154.164.0/22;
    deny  all;
}
```

### `secret_token` — the auth on the endpoint

`setWebhook(secret_token=…)` tells Telegram to send that string in an `X-Telegram-Bot-Api-Secret-Token`
header on every callback. Your handler must verify it — otherwise anyone who guesses the URL
can inject fake updates.

- 1..256 characters, `[A-Za-z0-9_-]`. Use `secrets.token_urlsafe(32)`.
- **`secret_token` on the webhook is different from the Bot API token.** It's a shared secret
  between Telegram and your endpoint, nothing else.
- Frameworks (aiogram `SimpleRequestHandler(secret_token=…)`) verify it; hand-rolled handlers
  must compare it manually with `hmac.compare_digest`.

### Telegram's IP ranges

The nginx snippet above whitelists the current documented ranges. Telegram publishes them at
https://core.telegram.org/resources/cidr.txt. They change rarely but *do* change — pin the
ranges in your nginx config and cross-check after any Telegram infra announcement, or your
webhook mysteriously goes silent.

Cheaper alternative: don't IP-restrict, just verify `secret_token`. Both together is belt +
braces.

### `getWebhookInfo` — the health check you actually need

Telegram exposes the webhook's current state as `getWebhookInfo`:

```json
{
  "url": "https://your-host.example/tg/webhook",
  "has_custom_certificate": false,
  "pending_update_count": 0,        ← ← ← the number that matters
  "last_error_date": 0,
  "last_error_message": "",
  "max_connections": 40,
  "allowed_updates": ["message", "callback_query", "…"]
}
```

Alert on:

- `pending_update_count > 100` — your webhook is failing, updates are queued at Telegram, they
  will be dropped after ~24 h.
- `last_error_message` non-empty — Telegram's report of what went wrong on the last delivery.
  Common values: `Wrong response from the webhook: 502 Bad Gateway`, `Connection timed out`,
  `SSL routines:CONNECT_CR_SRVR_HELLO:sslv3 alert handshake failure` (cert expired), `Failed
  to resolve host` (DNS blip).

Poll `getWebhookInfo` every minute and export the numbers to your metrics system; see
`reference/testing.md`.

## Migration: long-polling → webhook (or reverse)

`getUpdates` and `setWebhook` are mutually exclusive. If a webhook is set, `getUpdates`
returns `409 Conflict: can't use getUpdates method while webhook is active`. Migration path:

**Polling → webhook (deploying):**

1. New version is ready with webhook mode enabled.
2. Old (poller) process still running. Do NOT shut it down.
3. New process calls `setWebhook(...)`. This immediately makes the current poller's `getUpdates`
   fail with `409` — the poller exits (systemd restarts it and it 409s in a loop). That's fine
   during the swap.
4. Stop the old process.

**Webhook → polling (rolling back):**

1. Old version calls `deleteWebhook()`.
2. Start the poller. It gets any pending updates that Telegram had queued at the webhook.
3. Kill the webhook process.

Either direction preserves updates because Telegram keeps them queued at its side until you
consume them via *either* method.

### `drop_pending_updates` on the switch

The switch itself doesn't drop updates. Pass `drop_pending_updates=True` on `setWebhook` /
`deleteWebhook` only if you deliberately want to discard the queue (broken deploy, spam
storm). Default false, always.

## Local development for a webhook bot

You need a public HTTPS URL. Options:

- **cloudflared quick tunnel** (free, no account): `cloudflared tunnel --url http://localhost:8081`
  → prints `https://<random>.trycloudflare.com` valid until you Ctrl-C.
- **ngrok**: `ngrok http 8081` → `https://<random>.ngrok-free.app`. Free tier rotates the URL
  each run; paid tier gives you a stable domain.
- **Real DNS + Let's Encrypt on a dev VPS**: needed if you use `web_app` (Telegram doesn't open
  `*.trycloudflare.com` URLs as Mini Apps on some clients).

Then `setWebhook` with the tunnel URL. When you close the tunnel, the webhook is dead until
the next `setWebhook` — either accept the manual step or run a helper script that reads the
current tunnel URL and calls `setWebhook` for you.

## Debugging a silent webhook

Symptom: users send messages, `getWebhookInfo.pending_update_count` climbs, your app logs
nothing. Order to check:

1. `curl -X POST https://your-host.example/tg/webhook -H 'Content-Type: application/json' \
   -H 'X-Telegram-Bot-Api-Secret-Token: <token>' -d '{"update_id":1}'` → expect 200.
2. `nginx access log` for the webhook path — is Telegram actually hitting it? If not: DNS,
   cert, firewall.
3. `getWebhookInfo.last_error_message` — Telegram's own diagnosis.
4. `journalctl -u bot -f` while triggering an update — is the framework parsing the update? An
   internal 500 on the aiohttp handler shows here.
5. Check `max_connections` on `setWebhook` — default 40 is fine, but a server that only listens
   on 127.0.0.1 with the wrong port produces `Connection refused` in Telegram's queue.

## Ordering guarantees

- **Long-polling:** updates arrive **in `update_id` order**. `getUpdates` semantics.
- **Webhook:** updates for a given chat arrive **in order**, but *between* chats Telegram may
  send them in parallel (multiple connections). Your handler ordering guarantees end at the
  chat level.

Consequence: don't design per-user handlers that assume "the previous update finished before
this one starts" — always guard with FSM state or DB row locks. `reference/fsm.md` covers this.

## Common mistakes

| Symptom | Cause |
|---|---|
| `409 Conflict: terminated by other getUpdates request` | A second poller is alive somewhere (stale `nohup`, forgotten container). `ps auxf` |
| Webhook works locally, `pending_update_count` climbs in prod | Telegram can't reach your endpoint. Check DNS + TLS + nginx access log; then `curl -Iv` from another host |
| Handler for new update type doesn't fire | `allowed_updates` was set to a fixed list not including it; either restart with `resolve_used_update_types()` or call `setWebhook`/`getUpdates(-1)` again with the new list |
| Restart replays yesterday's updates | Bot was down for a day, Telegram queued 24 h of updates, `drop_pending_updates` not set. Either accept the replay or drop them intentionally |
| First deploy dropped user messages | `drop_pending_updates=True` in `start_polling` — remove it unless you *want* to discard the queue |
| Webhook returns 401 to Telegram | Missing / wrong `secret_token` verification, or nginx IP-allowlist rejecting Telegram's new IPs |
| `509 CONFLICT` on `setWebhook` | Bot already has a webhook set. `deleteWebhook` first, or pass the new URL directly to `setWebhook` — it overwrites |
| Handlers fire out of order for the same user | Multiple webhook workers behind a load balancer with no session affinity. Route by `update.from_user.id` hash, or handle idempotency in each handler |
| Local webhook dev is a pain | Use polling for dev, webhook for prod. Same handler code, one env var flag |
| `getWebhookInfo.last_error_message` is empty but pending count is growing | Rare — usually means Telegram is throttling your endpoint because it returned 5xx too often; check nginx access log for 5xx spikes |
