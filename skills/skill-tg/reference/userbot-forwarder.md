# Userbot mirrors and screeners (long-running MTProto services)

## Contents
- Why a user session at all
- Delivery: events are necessary but not sufficient
- The restart problem
- Deduplication
- Read-side flood limits
- Keeping the account healthy
- Screeners that also call an external API
- Monitoring
- Losing access to one source
- `chat.username` disappears for fragment / collectible names
- Fire-and-forget enrichment on the hot path
- Common mistakes

A different class of service from a command bot: a Telethon user session that watches many
chats around the clock and republishes what matches. Open this for mirrors, feed aggregators,
on-chain/price screeners — anything that must not miss a message and must not flood on restart.

## Why a user session at all

A Bot API bot cannot read a channel it was not added to, and cannot be added to someone
else's private channel. A user account can be a plain member. That is the only reason to
accept the extra cost: MTProto, session files, flood limits and ToS exposure.

Consequence: **the account is the dependency.** Losing it loses every source membership at
once, and re-joining private chats requires the invites again. Treat the session file as
production state, not as a dev artifact.

## Delivery: events are necessary but not sufficient

`events.NewMessage` is the fast path. It is not a guarantee:

- After a disconnect the client resyncs from a stored PTS. If the gap is too large the server
  answers `UpdatesTooLong` and simply **stops replaying** — those messages never arrive as
  events.
- Long-idle channels are delivered lazily; a "cold" channel can lag minutes behind a "hot" one.

Production shape is **events plus a polling loop** that pulls by `min_id` per source:

```python
async def pull_once(client, chat_id: int, last_id: int) -> int:
    newest = last_id
    async for msg in client.iter_messages(chat_id, min_id=last_id, reverse=True):
        await handle(msg)
        newest = max(newest, msg.id)
    return newest
```

Keep `{chat_id: last_seen_id}` durable (SQLite/JSON on disk). The loop is what makes the
service correct; events only make it fast.

## The restart problem

A service down for an hour comes back and discovers a backlog. Naively it republishes all of
it — subscribers get a wall of stale posts, and the account trips flood limits doing it.

Two independent guards, use both:

**1. Age ceiling.** Refuse to publish anything older than a threshold:

```python
MAX_PUBLISH_AGE = 300        # seconds

if (datetime.now(timezone.utc) - msg.date).total_seconds() > MAX_PUBLISH_AGE:
    skip("too_old")          # count it — a spike here means the service was down
    return
```

Five minutes is a workable default for a feed: long enough to survive a redeploy, short
enough that nothing stale ships.

**2. Offset bootstrap.** After downtime, fast-forward the stored offsets to the current head
*before* starting the pull loop, so the backlog is never fetched:

```python
for chat_id in sources:
    msgs = await client.get_messages(chat_id, limit=1)
    offsets[chat_id] = msgs[0].id if msgs else 0
```

Run it as a separate step (a flag or a small script) whenever the gap since the last run is
large. Without it, the age ceiling still protects subscribers, but the service burns its
flood budget fetching and discarding thousands of messages.

## Deduplication

A message can arrive twice — once as an event, once from the pull loop — and after a restart
the offsets may rewind. Key on `(source_chat_id, message_id)`, never on text:

```python
seen: set[tuple[int, int]] = load()

key = (msg.chat_id, msg.id)
if key in seen:
    return
seen.add(key)
```

Persist it. Two operational notes:

- The store grows forever; prune entries older than a few days, or it becomes the largest file
  in the deployment and slows startup.
- Losing the file re-publishes everything the pull loop still sees. The age ceiling is what
  bounds the damage — another reason to have both.

## Read-side flood limits

Reads are limited too, and independently of sends. Polling N sources every few seconds means
N `GetHistoryRequest` per tick.

- Set `flood_sleep_threshold` so short waits are absorbed by the library and only long ones
  surface as `FloodWaitError`.
- **Bound the fan-out.** A semaphore over the per-tick pull keeps concurrency flat as sources
  are added; without it, adding sources silently multiplies request rate.
- Sustained `Sleeping for Ns on GetHistoryRequest` in the logs means the poll interval is too
  aggressive for the number of sources — widen the interval before adding parallelism.
- Periodic `catch_up()` on top of a working pull loop is usually a net negative: it duplicates
  what the loop already does and is a common source of flood waits.

## Keeping the account healthy

An account that only reads looks like a scraper. Cheap mitigations:

- Periodically `send_read_acknowledge` on the watched chats — normal client behaviour.
- Set `device_model` / `system_version` / `app_version` to a real client profile and never
  change them for that session.
- Keep the send rate to the destination well under the per-chat ceiling; a mirror that
  republishes in bursts is the visible half of the account's footprint.

## Screeners that also call an external API

Enriching a post (price, holders, on-chain data) adds a second rate limit that is usually
tighter than Telegram's, and it is the one that breaks first.

The failure mode is structural: one goroutine/task per watched item, each polling on its own
timer. It works at ten items and returns `429` at a hundred, because nothing coordinates them.

**One shared limiter for the whole process**, not per worker:

```go
// one token every 300ms, process-wide
lim := rate.NewLimiter(rate.Every(300*time.Millisecond), 1)

func fetch(ctx context.Context, url string) (*http.Response, error) {
    if err := lim.Wait(ctx); err != nil {   // blocks until a token is free
        return nil, err
    }
    return http.DefaultClient.Do(req)
}
```

```python
class Limiter:
    def __init__(self, interval: float):
        self._interval, self._next = interval, 0.0
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        async with self._lock:
            now = time.monotonic()
            wait = max(0.0, self._next - now)
            self._next = max(now, self._next) + self._interval
        if wait:
            await asyncio.sleep(wait)
```

Then poll **sequentially** through the watch list rather than concurrently. A full sweep takes
`items × interval` — budget for it: at 300 ms and 200 items a cycle is about a minute, which
decides how fresh the data can be. If that is too slow, batch endpoints beat more concurrency.

## Monitoring

A mirror fails silently — it simply stops publishing, and nothing errors. Export at minimum:

| Metric | Why |
|---|---|
| `last_publish_timestamp{source}` | Alert on staleness; the only reliable liveness signal |
| `published_total{source}` | Sudden zero on one source = removed from that chat |
| `skipped_total{reason}` | A spike of `too_old` marks a restart; of `dedup`, an offset rewind |
| `errors_total{type}` | Separates `ChannelPrivate` (access lost) from flood and network |

Alert on **absence of publishes**, not on error rate. Losing access to a source raises
`ChannelPrivateError` once and then goes quiet forever.

## Losing access to one source

Resolve each source defensively and isolate failures — one dead source must not stop the
others:

```python
try:
    entity = await client.get_entity(chat_id)
except (errors.ChannelPrivateError, ValueError):
    log.warning("source %s unavailable, skipping", chat_id)
    disabled.add(chat_id)
    continue
```

Sources also get recreated: the same chat reappears under a new id, and the old one starts
failing permanently. Keep the mapping in config rather than hardcoded, so swapping an id is a
config change.

## `chat.username` disappears for fragment / collectible names

Older Telethon releases (1.36 line, and any client not on the latest TL schema) parse a
`Channel` record with **`username=None`** for public channels whose owner replaced the
regular username with a fragment / collectible one (auction usernames purchased via
Fragment). The channel is still publicly resolvable by `@name`, but neither
`event.chat.username` nor `event.chat.usernames` populates on the client.

Consequence: any code path that derives the display handle from `msg.chat.username` sees
`None` and falls back to `msg.chat.title`. In a mirror that publishes "posted by @handle",
half the posts lose the `@` and read as prose.

Fix: build a `chat_id → username` map at startup from the same config list the resolver
already reads, and consult it as a fallback:

```python
USERNAME_BY_CHAT_ID: dict[int, str] = {}

async def resolve_sources(client, raw_chats):
    for raw in raw_chats:
        try:
            ent = await client.get_input_entity(raw)
        except Exception:
            continue
        # If the caller wrote @name in config, we know the handle — keep it.
        if isinstance(raw, str) and raw.startswith("@"):
            cid = getattr(ent, "channel_id", None) or getattr(ent, "id", None)
            if cid:
                # Both id shapes seen in the wild (raw and -100 prefixed).
                USERNAME_BY_CHAT_ID[int(cid)] = raw[1:]
                USERNAME_BY_CHAT_ID[-(10**12) - int(cid)] = raw[1:]

def display_handle(msg) -> str:
    chat = getattr(msg, "chat", None)
    return (getattr(chat, "username", None)
            or USERNAME_BY_CHAT_ID.get(get_chat_id(msg))
            or getattr(chat, "title", None)
            or "?")
```

The map is the source of truth for handles you knew at boot time; the client is the source
of truth for handles that changed since. Prefer the map only when the client returns
`None`.

Do **not** blindly wrap arbitrary strings with `@`. Titles are free-form ("Some Channel
(EN)") and adding `@` produces broken mentions. Gate the `@` prefix on a strict handle regex
(`[A-Za-z0-9_]{4,32}`).

## Fire-and-forget enrichment on the hot path

A mirror often wants to attach cheap-looking metadata to each republished post — the
author's rolling reaction totals, a per-source post counter, a cached avatar. Each of those
lookups can silently be an MTProto call (`iter_messages`, `get_profile_photos`) that blocks
under flood limits. Blocking the publish path on any of them is how a 500 ms mirror turns
into a 30 s one during a flood wave.

Structure enrichment as a **fire-and-forget refresh**:

- Read the cached value synchronously from SQLite / Redis and use whatever is there.
- If the cache is stale, schedule a background task to refresh it. Do **not** await.
- Next publish sees the fresh value.

```python
INF_STATS_TTL = 300  # seconds

def get_source_stats_fast(userbot, source: str) -> dict:
    cached = _stats_read(source)               # sync SQLite read, <1 ms
    now = time.time()
    stale = (not cached) or (now - cached["updated"] >= INF_STATS_TTL)
    if stale and userbot is not None:
        asyncio.create_task(_stats_refresh_bg(userbot, source))
    return cached or {"hearts": 0, "clowns": 0}

async def _stats_refresh_bg(userbot, source: str):
    try:
        hearts = clowns = 0
        async for m in userbot.iter_messages(source, limit=50):
            r = _extract_reactions(m)
            hearts += r.get("❤", 0)
            clowns += r.get("🤡", 0)
        _stats_write(source, hearts, clowns)
    except Exception as e:
        log.warning("stats refresh failed for %s: %s", source, e)
```

Rules of thumb:

- The publish path awaits **only** what the message text needs to be correct. Everything
  else is background.
- Background tasks must catch their own exceptions — an unhandled exception in a
  `create_task`-scheduled coroutine goes to the default exception handler and is easy to
  miss. Log inside the task.
- The first post for a given source will show the default (`0/0`). This is the correct
  trade-off; the second post shows the real numbers. Do not "just await this one time" —
  that path is where every large refactor ended up back at 30 s publishes.

The same shape applies to avatars, to per-source post counters, and to any lookup that
could be blocking under load: read cached, use as-is, schedule a refresh.

## Common mistakes

| Symptom | Cause |
|---|---|
| Flood of stale posts after a restart | No age ceiling and no offset bootstrap — the backlog was replayed |
| Messages missing from quiet channels only | Relying on events alone; cold channels lag — the pull loop is what catches them |
| Same post published twice | Dedup keyed on text, or the key store is not persisted across restarts |
| `UpdatesTooLong`, then permanent silence | The gap exceeded what the server replays; only a pull loop recovers |
| `Sleeping for Ns on GetHistoryRequest` constantly | Poll interval too tight for the source count — widen it, don't parallelise |
| External API returns `429` as sources grow | Per-worker timers instead of one process-wide limiter |
| One source dies and the whole mirror stops | `get_entity` not wrapped per source |
| Dedup file becomes the largest artifact | Never pruned — drop entries older than a few days |
| Service looks healthy, publishes nothing | Alerting on errors instead of on `last_publish_timestamp` staleness |
| Session invalidated after a config tweak | `device_model`/`app_version` changed — they are part of session identity |
| `@handle` missing on half the posts even though the source is public | `chat.username=None` for fragment/collectible usernames on older Telethon — use a `chat_id → username` map from config as fallback |
| Publishes are 500 ms usually, 30 s during flood spikes | Enrichment (avatars, per-source stats) is on the hot path — move to fire-and-forget and read the cached value on publish |
| Caption reads `@Some Channel (EN) posted:` — the `@` wraps a title with spaces | `@` was prefixed to `chat.title`, not a username — gate the `@` on a strict handle regex (`[A-Za-z0-9_]{4,32}`) before formatting |
