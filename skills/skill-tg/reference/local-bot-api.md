# Self-hosted Telegram Bot API server

## Contents
- When it's worth the operational cost
- Running it
- Migrating a bot from public → local
- Pointing your code at the local server
- Uploading a >50 MB file
- Downloading a >20 MB file
- Cleanup — the bot-api server never deletes files
- Webhook via the local server
- Cost model
- Two-server split (public + local) for one bot
- Common mistakes

The public `api.telegram.org` caps every bot at:

- 50 MB file upload (`sendPhoto`, `sendVideo`, `sendDocument`, `sendAudio`).
- 20 MB file **download** (`getFile` returns a URL that only works for files ≤ 20 MB).
- Response timeout ~15 s on long calls.
- No inspection of the raw HTTP request/response Telegram made when a webhook failed.

If any of those bites, run the [official Bot API server](https://core.telegram.org/bots/api#using-a-local-bot-api-server)
yourself. It's the same daemon Telegram runs, published open-source; your bot points at
`http://localhost:8081` instead of `https://api.telegram.org` and the caps become **2 GB
upload / unlimited download**.

## When it's worth the operational cost

Yes:

- You legitimately need to send/receive files > 50 MB (podcasts, HD video, backups).
- You need download for files > 20 MB (user-uploaded content processed by your pipeline).
- You want the raw webhook-failure logs to debug "Telegram says my endpoint 500'd, my logs say
  200".
- You want to use the bot as a file server for other bots (`file_id`s from a local server
  can't be used on the public server and vice-versa; run everything on one).

No, don't self-host if:

- All your media fits under 50 MB. The public server is free, redundant, and Someone Else's
  Problem — self-hosting is one more thing to monitor and back up.
- Your bot is Stars-only (no media) or DM-only text.

## Running it

Docker image (unofficial but widely used):

```bash
docker run -d --restart=unless-stopped --name tg-bot-api \
  -p 127.0.0.1:8081:8081 \
  -v tgbotapi-data:/var/lib/telegram-bot-api \
  -e TELEGRAM_API_ID=<your api_id> \
  -e TELEGRAM_API_HASH=<your api_hash> \
  -e TELEGRAM_LOCAL=1 \
  aiogram/telegram-bot-api:latest
```

Config:

- **`TELEGRAM_API_ID` / `TELEGRAM_API_HASH`** — the same pair you get from
  https://my.telegram.org/apps. **NOT the bot token.** They authenticate the *server*, not any
  particular bot. Same pair as a userbot session uses; see `reference/testing.md` for
  fetching or reusing one.
- **`TELEGRAM_LOCAL=1`** — enables the `--local` mode: files land on disk instead of being
  proxied. `getFile` returns `file_path` = an absolute local filesystem path (e.g.
  `/var/lib/telegram-bot-api/<botid>/documents/file_42.mp4`) instead of a URL.
- **Storage**: bind-mount a volume; media files live there indefinitely until you clean up.
- **Port**: bind on `127.0.0.1` — never expose 8081 publicly. It has no auth beyond the bot
  token being embedded in the URL path.

## Migrating a bot from public → local

Bots authorised on `api.telegram.org` cannot be used on a local server directly; you must
`logOut` from the public API first, then switch.

```bash
# 1. Log the bot out of the public API
curl "https://api.telegram.org/bot${TOKEN}/logOut"
# → {"ok":true,"result":true}

# 2. Point your bot at the local server (see next section) and restart.

# 3. Optionally, on the local server: logIn is implicit on first call.
```

`logOut` is one-way per side — after it, subsequent requests to the public API get `401
Unauthorized`. To go back to the public server:

```bash
# On the local server, log the bot out
curl "http://localhost:8081/bot${TOKEN}/close"
# then the bot is free to authorise on api.telegram.org again
```

`close` is the local-server counterpart to `logOut` — releases the bot's state so it can
migrate.

## Pointing your code at the local server

aiogram:

```python
from aiogram import Bot
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer

session = AiohttpSession(
    api=TelegramAPIServer.from_base("http://localhost:8081", is_local=True),
)
bot = Bot(TOKEN, session=session)
```

`is_local=True` toggles the URL rewriting for local file access — `file_path` in `getFile`
responses will be treated as a local path, not a URL.

python-telegram-bot:

```python
from telegram.ext import ApplicationBuilder

app = (ApplicationBuilder()
       .token(TOKEN)
       .base_url("http://localhost:8081/bot")
       .base_file_url("http://localhost:8081/file/bot")
       .local_mode(True)
       .build())
```

Go / telebot.v3:

```go
b, err := tele.NewBot(tele.Settings{
    Token:   os.Getenv("BOT_TOKEN"),
    URL:     "http://localhost:8081",
    Poller:  &tele.LongPoller{Timeout: 10 * time.Second},
})
```

telebot doesn't have a first-class `local_mode` flag, but with the base URL swapped, uploads
above 50 MB start working. File downloads: `getFile` returns a `file_path` that's a local
absolute path when the server is `--local`; open it directly with `os.Open`, don't try to fetch
it over HTTP.

## Uploading a >50 MB file

```python
from aiogram.types import FSInputFile
await bot.send_video(chat_id, FSInputFile("/media/full-hd-clip.mp4"))
```

No change to your code — the same `FSInputFile` now happily uploads a 500 MB file. Watch out:

- **Streaming**: aiogram streams the request body; memory stays flat. python-telegram-bot older
  versions load into memory — check the release notes.
- **Bot API timeout**: increase the client-side upload timeout (`AiohttpSession(timeout=…)`
  or telebot `client.timeout`). A 1 GB upload on a modest link is 15+ minutes; the default
  15 s timeout kills it.
- **Bot process memory**: don't `await bot.send_video(chat, open("big.mp4","rb").read())` — you
  read the whole file into RAM. `FSInputFile("path")` streams.

## Downloading a >20 MB file

On the public server this returns a 400 — file too big. On a local server:

```python
tg_file = await bot.get_file(file_id)         # returns File with file_path
# In local mode, file_path is a filesystem path on the bot-api server:
local_path = tg_file.file_path                # e.g. "/var/lib/telegram-bot-api/<botid>/videos/file_42.mp4"
# Either process in place, or copy it to your bot process's filesystem:
import shutil; shutil.copy(local_path, "/data/downloads/")
```

If your bot and the bot-api server are on different hosts, either NFS-mount the storage or
run them on the same host — the local mode gives you a filesystem path, not a URL, so a
cross-host setup needs shared storage.

## Cleanup — the bot-api server never deletes files

Every media a bot receives is stored under
`/var/lib/telegram-bot-api/<botid>/{photos,videos,documents,audios,…}/`. Nothing prunes them.
Your disk fills up.

Cron:

```bash
# purge everything older than 7 days
find /var/lib/telegram-bot-api -type f -mtime +7 -delete
# and empty dirs after
find /var/lib/telegram-bot-api -type d -empty -delete
```

Adjust the retention window to your product's needs. If you've stored `file_id`s in your DB
and users still access them, keep the files at least that long — a `file_id` for a purged file
returns 400 on `getFile`.

## Webhook via the local server

Local server takes webhook registrations same as the public one, but the `url` in
`setWebhook` still needs to be *your* endpoint (Telegram's public infrastructure calls your
webhook; the local bot-api server is only a bot-side accelerator, not a public inbound point).

Common misconception: "the local server proxies webhooks too" — no. Telegram → your webhook →
your bot process → local bot-api server. Only the *outbound* path (bot → Telegram) is
short-circuited.

## Cost model

- **Disk**: ~1 GB per 20 hours of received video traffic. Set a retention policy from day one.
- **CPU**: bot-api server is single-threaded per bot, but I/O bound. A t3.small handles a
  couple of high-traffic bots comfortably.
- **Bandwidth**: unchanged — Telegram still sends the media to your server, self-hosted just
  means you receive on 8081 instead of routing through `api.telegram.org`.

## Two-server split (public + local) for one bot

You can't — a bot is either on the public server or on the local one, `logOut`/`close` gates
the swap. Two bots pointing at different servers to split load is fine, but their `file_id`
namespaces don't overlap.

## Common mistakes

| Symptom | Cause |
|---|---|
| `401 Unauthorized` after switching to local server | Forgot `logOut` on the public API before switching |
| `file_id` from a local server returns 400 on `api.telegram.org` | `file_id`s are per-server; migrate both bot and downstream consumers together |
| Upload of a 100 MB file times out | Client HTTP timeout still at 15 s; bump it (`AiohttpSession(timeout=aiohttp.ClientTimeout(total=None))`) |
| `getFile` returns a URL, not a path | Server not in `--local` mode (`TELEGRAM_LOCAL=1`); or client not `is_local=True` |
| Disk full a month after deploy | Never set up the cleanup cron |
| Bot-api server responds slowly | The `TELEGRAM_LOCAL_*` request queues fill up on I/O; check `docker stats` for the container's CPU |
| Bot's own webhook stops delivering | `setWebhook` was pointed at `http://localhost:8081/webhook` by accident (that's the bot-api server's URL, not yours) |
| Migration from local → public loses `file_id`s | Cache new `file_id`s the first time each file is sent through the new server; treat the migration as a fresh install for media |
| Local server crashes on startup | Wrong `TELEGRAM_API_ID`/`TELEGRAM_API_HASH`, or storage volume lacks write permission (`chown` the mount to the container user) |
| Sending file works but download fails | The bot-api server needs `TELEGRAM_LOCAL=1` AND the bot's client needs to know files are local; both sides must agree |
| Two bots share the same storage volume | Fine, each gets its own subdirectory under `/var/lib/telegram-bot-api/<botid>/` |
