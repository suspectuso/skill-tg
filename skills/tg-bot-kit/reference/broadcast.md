# Mass broadcasts — rate limits, chunking, error handling

Sending one message to every user of the bot is deceptively simple. Six things make it hard:
Telegram's rate limits, users who blocked / deleted their account since signup, users who never
started the bot, media uploads that take orders of magnitude longer than text, retry after
FloodWait, and being able to stop / resume the run without duplicates.

## The rate limits you must respect

Telegram's rules for bot messages:

- **~30 messages per second globally** to *different* users. Above that, you get `429 Too Many
  Requests` with `retry_after`.
- **~1 message per second to the same chat.** Above that, same 429.
- Groups: **~20 messages per minute per group**. Broadcasting to groups is much slower than to
  users.
- Media uploads are counted the same, but each upload holds a connection for its full duration —
  a 10 MB video at 1 Mbps eats a "message slot" for 80 seconds. **Cache media as `file_id` first**;
  see `reference/media-and-deploy.md`.

Numbers are approximate — Telegram tunes them by traffic. The defensive default for a
production broadcast is **20 msg/s**, not 30; leaves headroom for the bot's regular traffic
running alongside.

## The `users` table you need

```sql
CREATE TABLE users (
  id           BIGSERIAL PRIMARY KEY,
  telegram_id  BIGINT UNIQUE NOT NULL,
  language     TEXT DEFAULT 'ru',
  is_blocked   BOOLEAN DEFAULT FALSE,      -- bot blocked by user, or account deactivated
  is_banned    BOOLEAN DEFAULT FALSE,      -- banned by us
  last_seen_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
```

`is_blocked` is the killer field. Every `403 Forbidden: bot was blocked by the user` and
`400 chat not found` and `400 user is deactivated` you get during a broadcast means that user
can never receive a message again — mark them and skip them in future runs. Not doing this
makes each broadcast take 5-10× longer and provokes flood limits from Telegram against a bot
that keeps hammering dead endpoints.

## The `broadcasts` table for run tracking

```sql
CREATE TABLE broadcasts (
  id           BIGSERIAL PRIMARY KEY,
  admin_id     BIGINT NOT NULL,
  audience     TEXT NOT NULL,                 -- 'all' | 'active_subs' | 'lang:ru' | …
  audience_sql TEXT NOT NULL,                 -- reproducibility: exact query used
  text         TEXT,
  photo_url    TEXT,
  reply_markup JSONB,
  status       TEXT DEFAULT 'draft',          -- draft | running | paused | done | cancelled
  total        INT,                           -- audience size snapshot at start
  sent         INT DEFAULT 0,
  blocked      INT DEFAULT 0,
  failed       INT DEFAULT 0,
  started_at   TIMESTAMPTZ,
  finished_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE broadcast_sends (
  broadcast_id BIGINT REFERENCES broadcasts(id),
  user_id      BIGINT NOT NULL,
  status       TEXT NOT NULL,                 -- sent | blocked | failed
  error        TEXT,
  sent_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(broadcast_id, user_id)
);
```

`broadcast_sends UNIQUE(broadcast_id, user_id)` is the idempotency guard. Resuming a paused
run: `SELECT tg_id FROM users LEFT JOIN broadcast_sends bs ON bs.user_id=users.id AND
bs.broadcast_id=$1 WHERE bs.user_id IS NULL AND is_blocked=false …` — everyone not yet sent to.

## aiogram broadcaster with concurrency + FloodWait handling

```python
# services/broadcaster.py
import asyncio, logging, time
from aiogram import Bot
from aiogram.exceptions import (
    TelegramForbiddenError,          # 403 blocked / deactivated
    TelegramBadRequest,              # 400 chat not found / user is deactivated
    TelegramRetryAfter,              # 429 flood
    TelegramNetworkError,            # transient
)
from db import DB

log = logging.getLogger("broadcast")

RATE_PER_SECOND = 20
BATCH_SIZE      = 25
BATCH_INTERVAL  = BATCH_SIZE / RATE_PER_SECOND      # ~1.25s per batch of 25


async def broadcast_run(bot: Bot, broadcast_id: int):
    b = await DB.fetchrow("SELECT * FROM broadcasts WHERE id=$1", broadcast_id)
    if b["status"] not in ("draft", "paused"):
        return
    await DB.execute(
        "UPDATE broadcasts SET status='running', started_at=COALESCE(started_at,NOW()) WHERE id=$1",
        broadcast_id,
    )

    while True:
        # cancellation check — a UI button flips status to 'paused' / 'cancelled'
        status = await DB.fetchval("SELECT status FROM broadcasts WHERE id=$1", broadcast_id)
        if status != "running":
            log.info("broadcast %s stopped: status=%s", broadcast_id, status)
            return

        rows = await DB.fetch(
            """
            SELECT u.id, u.telegram_id FROM users u
            LEFT JOIN broadcast_sends bs
                ON bs.user_id = u.id AND bs.broadcast_id = $1
            WHERE bs.user_id IS NULL
              AND u.is_blocked = false
              AND u.is_banned  = false
              -- + audience filter, e.g. AND u.id IN (SELECT user_id FROM subscriptions WHERE …)
            LIMIT $2
            """,
            broadcast_id, BATCH_SIZE,
        )
        if not rows:
            await DB.execute(
                "UPDATE broadcasts SET status='done', finished_at=NOW() WHERE id=$1",
                broadcast_id,
            )
            return

        t0 = time.monotonic()
        sem = asyncio.Semaphore(BATCH_SIZE)          # allow whole batch to run in parallel
        await asyncio.gather(*(
            _send_one(bot, broadcast_id, u["id"], u["telegram_id"], b, sem) for u in rows
        ))
        elapsed = time.monotonic() - t0
        sleep = BATCH_INTERVAL - elapsed
        if sleep > 0:
            await asyncio.sleep(sleep)


async def _send_one(bot, broadcast_id, user_id, tg_id, b, sem):
    async with sem:
        try:
            if b["photo_url"]:
                await bot.send_photo(tg_id, b["photo_url"], caption=b["text"],
                                     reply_markup=b["reply_markup"])
            else:
                await bot.send_message(tg_id, b["text"], reply_markup=b["reply_markup"],
                                       disable_web_page_preview=True)
            await DB.execute(
                "INSERT INTO broadcast_sends (broadcast_id, user_id, status) VALUES ($1,$2,'sent') "
                "ON CONFLICT DO NOTHING",
                broadcast_id, user_id,
            )
            await DB.execute("UPDATE broadcasts SET sent = sent + 1 WHERE id=$1", broadcast_id)

        except TelegramRetryAfter as e:
            log.warning("flood wait %ss on user %s", e.retry_after, tg_id)
            await asyncio.sleep(e.retry_after + 1)
            # do NOT record — retry next batch cycle (the user still isn't in broadcast_sends)

        except (TelegramForbiddenError, TelegramBadRequest) as e:
            msg = str(e).lower()
            if any(x in msg for x in (
                "bot was blocked", "user is deactivated", "chat not found",
                "peer_id_invalid", "user_deactivated_ban",
            )):
                await DB.execute("UPDATE users SET is_blocked=true WHERE id=$1", user_id)
                await DB.execute(
                    "INSERT INTO broadcast_sends VALUES ($1,$2,'blocked',$3) ON CONFLICT DO NOTHING",
                    broadcast_id, user_id, msg[:200],
                )
                await DB.execute("UPDATE broadcasts SET blocked = blocked + 1 WHERE id=$1", broadcast_id)
            else:
                await _mark_failed(broadcast_id, user_id, msg)

        except TelegramNetworkError as e:
            # transient — leave uninserted so next cycle retries
            log.warning("network err on %s: %s", tg_id, e)
            await asyncio.sleep(1)

        except Exception as e:
            await _mark_failed(broadcast_id, user_id, str(e)[:200])


async def _mark_failed(broadcast_id, user_id, err):
    await DB.execute(
        "INSERT INTO broadcast_sends VALUES ($1,$2,'failed',$3) ON CONFLICT DO NOTHING",
        broadcast_id, user_id, err,
    )
    await DB.execute("UPDATE broadcasts SET failed = failed + 1 WHERE id=$1", broadcast_id)
```

## Progress reporting to the admin

Long-running broadcasts feel broken without live progress. Edit a single message every N seconds:

```python
# services/broadcast_progress.py
async def progress_reporter(bot, admin_id, broadcast_id, poll_every=5):
    b = await DB.fetchrow("SELECT * FROM broadcasts WHERE id=$1", broadcast_id)
    msg = await bot.send_message(admin_id, _render(b))
    last_text = msg.text

    while True:
        await asyncio.sleep(poll_every)
        b = await DB.fetchrow("SELECT * FROM broadcasts WHERE id=$1", broadcast_id)
        text = _render(b)
        if text == last_text:                        # avoid "message is not modified" 400
            if b["status"] in ("done", "cancelled"):
                return
            continue
        try:
            await bot.edit_message_text(text, admin_id, msg.message_id,
                                        reply_markup=_progress_kb(b))
        except TelegramBadRequest:
            pass                                     # user closed the chat / message deleted
        last_text = text
        if b["status"] in ("done", "cancelled"):
            return


def _render(b):
    total  = b["total"] or 1
    done   = b["sent"] + b["blocked"] + b["failed"]
    pct    = done * 100 // total
    bar    = "▓" * (pct // 5) + "░" * (20 - pct // 5)
    return (
        f"📢 Broadcast #{b['id']}: {b['status']}\n"
        f"`{bar}` {pct}%\n\n"
        f"✅ Sent:    {b['sent']}\n"
        f"🚫 Blocked: {b['blocked']}\n"
        f"⚠️ Failed: {b['failed']}\n"
        f"Total:     {total}"
    )
```

`edit_message_text` throws `400 message is not modified` if the text hasn't changed — check
`last_text` before editing, or wrap the edit in a try/except.

## The pause/cancel button

```python
# handlers/admin_broadcast.py
@dp.callback_query(F.data.startswith("bcast:cancel:"))
async def cancel(cb: CallbackQuery):
    bid = int(cb.data.split(":")[2])
    await DB.execute("UPDATE broadcasts SET status='cancelled' WHERE id=$1 AND status='running'", bid)
    await cb.answer("Broadcast cancelled")

@dp.callback_query(F.data.startswith("bcast:pause:"))
async def pause(cb: CallbackQuery):
    bid = int(cb.data.split(":")[2])
    await DB.execute("UPDATE broadcasts SET status='paused' WHERE id=$1 AND status='running'", bid)
    await cb.answer("Paused. Resume with the button below.")

@dp.callback_query(F.data.startswith("bcast:resume:"))
async def resume(cb: CallbackQuery, state: FSMContext):
    bid = int(cb.data.split(":")[2])
    await DB.execute("UPDATE broadcasts SET status='running' WHERE id=$1 AND status='paused'", bid)
    asyncio.create_task(broadcast_run(cb.bot, bid))          # kick the loop again
    await cb.answer("Resumed")
```

The `broadcast_run` loop itself does the cancellation check on every batch (`SELECT status FROM
broadcasts WHERE id=$1`) — so a `cancelled` flip stops the run within one batch cycle (~1 s).

## Preview + confirm before sending

Never launch a broadcast from a single button click. The pattern:

1. Admin picks audience → bot echoes computed size (`SELECT count(*) FROM users WHERE …`).
2. Admin types the text → bot shows the message **exactly as users will see it** (send it to
   admin's own DM, then a confirmation).
3. Admin taps `✅ Send to N users` → bot inserts the `broadcasts` row and kicks
   `broadcast_run`.

Preview by sending the real message to the admin, not by rendering it as a preview widget —
Telegram-rendering shows escaping, link previews, parse-mode quirks you can't preview any other
way.

## Reconciliation after a run

```sql
-- Users who blocked us during this broadcast
SELECT count(*) FROM broadcast_sends
WHERE broadcast_id = $1 AND status = 'blocked';

-- Compare with previous broadcasts to spot churn spikes
SELECT date_trunc('day', started_at) AS day,
       sum(blocked)::float / NULLIF(sum(sent+blocked+failed), 0) * 100 AS block_pct
FROM   broadcasts
WHERE  status = 'done'
GROUP  BY 1 ORDER BY 1 DESC LIMIT 30;
```

A single broadcast with `block_pct > 5%` is a signal that the content was off (irrelevant to
segment, too frequent, bad time of day, low quality). Track it — it's the closest thing to a
NPS on a bot.

## Broadcast to groups (chats, not users)

Rules change: **~20 messages per minute per group** instead of ~1/second. And `403 Forbidden:
bot was kicked` marks the *group* as blocked, not a user. Keep a separate `chats` table
mirroring the `users` fields (`is_blocked`, `is_banned`), broadcast worker uses `RATE_PER_MIN =
20` and batches accordingly.

## Common mistakes

| Symptom | Cause |
|---|---|
| Broadcast takes forever | Not marking `is_blocked` → hammering thousands of dead users, tripping flood limits repeatedly |
| Duplicate messages to same user on resume | `broadcast_sends` UNIQUE constraint missing, or resume query re-selects already-sent rows |
| `400 message is not modified` on progress bar | Progress text is identical between polls (e.g. `done` counter didn't change) — check `last_text` before edit |
| Cancellation button doesn't stop the run | Loop doesn't poll `broadcasts.status`, or does but only at start; add a check every batch |
| First 30 sends fast, then hangs 20 s | Hit the ~30 msg/s cap, got 429 with `retry_after=20` — set `RATE_PER_SECOND=20` in code, not 30 |
| Media broadcast is 100× slower than text | Uploading raw files instead of using cached `file_id` — see `reference/media-and-deploy.md` |
| Some users get the message with a delay of minutes | Concurrency too low (`Semaphore(5)` with 20 msg/s target means each user waits for 4 batches) — raise semaphore to match batch size |
| `broadcast_run` restarts on deploy → double-send | Fine: the UNIQUE constraint on `broadcast_sends` deduplicates. But the batch that was in-flight during shutdown may leave half-inserted rows — recover by using an outer transaction per user (insert row + increment counter atomically) |
| Sending photos: only the first user sees the image | `photo_url` is a public URL and Telegram cached a rate-limited version — send once, capture `file_id` from the response, use `file_id` from send #2 onwards |
| Progress message shows 0 for a while | `total` column not populated at start; snapshot audience size on kick-off, don't recompute per poll |
| Admin closes chat mid-run and worker crashes | `edit_message_text` raised — worker unhandled exception. Catch and continue silently, run itself doesn't need the progress message |
