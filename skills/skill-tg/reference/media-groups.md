# Media groups (albums) — sending, receiving, editing

Telegram "albums" are `MediaGroup`s: 2..10 media items delivered as one visually-grouped
message. They look like one message but are technically **N separate messages** with the same
`media_group_id` — that quirk drives every gotcha in this file.

## Sending an album

```python
# aiogram
from aiogram.types import InputMediaPhoto, InputMediaVideo, FSInputFile

media = [
    InputMediaPhoto(media=FSInputFile("photo1.jpg"),
                    caption="Album caption goes on the first item",
                    parse_mode="HTML"),
    InputMediaPhoto(media=FSInputFile("photo2.jpg")),
    InputMediaPhoto(media=FSInputFile("photo3.jpg")),
    InputMediaVideo(media=FSInputFile("clip.mp4")),
]
messages = await bot.send_media_group(chat_id, media=media,
                                       disable_notification=True)
# messages is a list of len(media); each has its own message_id
```

Rules:

- **2..10 items** per group. 1 = use plain `sendPhoto`; 11+ = split into groups (Telegram
  rejects with `Bad Request: media group must include`).
- **Types can mix within the same group** as follows: `photo`+`video` freely; `document`
  albums (docs only, no mixing); `audio` albums (audio only). Photo+document in one group =
  400.
- **Caption on the FIRST item only.** Any caption on items 2..N is silently displayed as an
  individual caption under that photo — not what you usually want. Put the whole caption on
  item 0, leave the rest bare.
- **`parse_mode`, `caption_entities`** live on the item that carries the caption. Same rules
  as plain `sendPhoto` (HTML/Markdown v2, `<blockquote expandable>` etc.).
- **`disable_notification`, `protect_content`** apply to the whole group.
- **`reply_to_message_id`, `message_thread_id`** apply to the whole group.
- **`reply_markup` is NOT supported.** You cannot attach inline buttons to a media group. If
  you need buttons, send the album as-is, then send a follow-up text message with the buttons
  referencing the album by reply.

## Receiving an album — the "wait ~1 second" trick

Telegram delivers albums as **N separate `Message` updates**, each with the same
`media_group_id` string but no signal about "this is the last one". Naive handlers process
photo 1 alone, then photo 2 alone, etc.

Buffer by `media_group_id`, debounce ~1 second, then process:

```python
# services/album_buffer.py
import asyncio, time
from collections import defaultdict

_buffers: dict[str, list] = defaultdict(list)
_last_seen: dict[str, float] = {}
_locks: dict[str, asyncio.Lock] = {}


async def collect_album(m, timeout=1.0):
    """
    Call from a message handler when m.media_group_id is set.
    Returns the full list of messages exactly once (to the message that arrived last).
    Returns None otherwise — the caller should return without responding.
    """
    gid = m.media_group_id
    _buffers[gid].append(m)
    _last_seen[gid] = time.monotonic()

    lock = _locks.setdefault(gid, asyncio.Lock())
    async with lock:
        await asyncio.sleep(timeout)
        # if another message arrived while we slept, bail out — the later handler owns it
        if time.monotonic() - _last_seen[gid] < timeout * 0.9:
            return None
        msgs = _buffers.pop(gid)
        _last_seen.pop(gid, None)
        _locks.pop(gid, None)
        return sorted(msgs, key=lambda x: x.message_id)


# handler
@dp.message(F.media_group_id)
async def on_album(m: Message):
    msgs = await collect_album(m)
    if msgs is None:
        return                                 # not the last message; another handler will fire
    caption = msgs[0].caption or ""
    photos  = [x.photo[-1].file_id for x in msgs if x.photo]
    videos  = [x.video.file_id for x in msgs if x.video]
    await process(caption, photos, videos)
```

Why the timeout: Telegram doesn't tell you the album is complete, and you can't rely on order
either (updates in a group arrive close together but not always in `message_id` order for a
webhook deployment). 1 second is enough for practical album delivery; increase to 2 s if you
see occasional splits.

The `_locks[gid]` guard is important — without it, N handlers race and each thinks it's the
last.

## Forwarding / copying an album

`forwardMessages` and `copyMessages` (plural) — Bot API 7.1+ — take a list of `message_id`s
of the album and preserve the group:

```python
await bot.forward_messages(
    to_chat_id=dst_chat,
    from_chat_id=src_chat,
    message_ids=[m.message_id for m in album],
    disable_notification=True,
    protect_content=False,
)
```

Older `forwardMessage` (singular) forwards items one by one and **breaks the album** — each
photo lands as a separate message in the destination. Always use the plural methods for
albums, both aiogram and telebot expose them (`Bot.forward_messages`, `Bot.copy_messages`).

## Editing an album

You can't `editMessage` the album as a unit. Options:

- **Edit one item's media** (`editMessageMedia`) — the item is replaced in place, the album
  container stays.
- **Edit one item's caption** (`editMessageCaption`) — same.
- **Replace the whole album** — delete all N messages (`deleteMessage` × N), send a fresh
  album. Users see a "message deleted → new message appeared" jump.

Individual edits:

```python
from aiogram.types import InputMediaPhoto

await bot.edit_message_media(
    chat_id=chat_id,
    message_id=album_msgs[0].message_id,       # any specific item id
    media=InputMediaPhoto(media=new_file_id, caption="Replaced caption"),
)
```

## Deleting an album

Same issue: N messages, N deletes. Batch with `deleteMessages` (plural, Bot API 7.1+):

```python
await bot.delete_messages(chat_id, [m.message_id for m in album])
```

Silently skips messages that no longer exist (users can delete individually) — check
`getUpdates` if you need to know what actually got deleted.

## `file_id` caching for albums

Sending the same album twice = re-upload each item unless you cache `file_id`s. First send:

```python
sent = await bot.send_media_group(chat_id, media=[
    InputMediaPhoto(media=FSInputFile("photo1.jpg"), caption="…"),
    InputMediaPhoto(media=FSInputFile("photo2.jpg")),
])
# capture file_ids in order
for i, m in enumerate(sent):
    db.meta_set(f"fileid:album/{album_id}/{i}", m.photo[-1].file_id)
```

Later sends: reuse the ids.

```python
ids = [db.meta_get(f"fileid:album/{album_id}/{i}") for i in range(len(sent))]
await bot.send_media_group(chat_id, media=[
    InputMediaPhoto(media=ids[0], caption="…"),
    InputMediaPhoto(media=ids[1]),
])
```

Details on file_id lifecycle: `reference/media-and-deploy.md`.

## Rich `slideshow` vs. classic album

Bot API 10.1 `sendRichMessage` with a `slideshow` block gives you a **swipeable single-message
carousel** — one message id, not N, edit-in-place preserved, coloured buttons attach. That's
the modern replacement when your users are on clients that support it.

Comparison:

| | Classic album | Rich `slideshow` |
|---|---|---|
| Message count | N | 1 |
| Buttons | none | full `reply_markup` |
| Edit-in-place | per item only | whole slideshow via `editMessageText + rich_message` |
| Older client fallback | works everywhere | client that doesn't render rich sees "the bot sent an unsupported message" |
| Sendable via wrapper | `send_media_group` | Raw call only |

Use albums when: your audience spans very old clients, or you need photos+documents+audio
mixing (rich `slideshow` is photos/videos). Use rich `slideshow` when: you need buttons on the
carousel or in-place edits.

## Deployment tips

- **Max photo dimensions** for `sendPhoto`/`InputMediaPhoto`: **10 000 × 10 000 px**, with a
  width/height ratio ≤ 20. Over these, Telegram rejects with `PHOTO_INVALID_DIMENSIONS`; scale
  down to fit before sending.
- **Max photo file size** (as photo, JPEG): **10 MB**. If bigger, either resize or send as
  `InputMediaDocument` (up to 50 MB via Bot API, 2 GB via self-hosted Bot API — see
  `reference/media-and-deploy.md`).
- **Video in albums**: same 50 MB cap. Compress: see the ffmpeg one-liner in
  `reference/media-and-deploy.md`.
- **Audio in albums** must all be `.mp3` / `.m4a` / `.ogg` with `performer` and `title`
  metadata visible — Telegram uses those to render the "playlist" look. Without metadata each
  audio is just a "voice message" and they don't visually group.

## Common mistakes

| Symptom | Cause |
|---|---|
| Only one photo of the intended 5 arrives | Sent them as 5 separate `send_photo` calls instead of one `send_media_group`. Use the plural |
| Caption appears under each photo | Caption was set on every item; only set it on `media[0]` |
| Bot's inline button is missing on the album | Media groups don't support `reply_markup`. Send the album, then a follow-up text with buttons |
| Album received as N separate handler calls | Missing `media_group_id` buffer; add the debounce collector from above |
| Second handler processes the same album because 1 s wasn't enough | Bump the debounce to 2 s, or add a "we already handled this gid" set with 60 s TTL |
| `forwardMessage` × N → destination sees isolated photos, no album | Use `forward_messages` (plural) with the list of ids |
| `edit_message_media` "message to edit not found" | Passed the wrong `message_id`, or the item was deleted by the user |
| `delete_message` × N left 3 out of 5 items visible | Rate limit hit; use `delete_messages` (plural), which is one API call |
| `sendMediaGroup` returned `MEDIA_INVALID` | Mixed `photo` + `document` in one group; split into separate groups |
| Album from a URL is very slow / times out | Telegram fetches each URL server-side; either upload files directly or send once and reuse `file_id` on subsequent sends |
| Album re-send uploads full files every time | Not caching `file_id`s from the first `sendMediaGroup` response. Store them keyed by `(album_id, index)` |
| Older Telegram desktop shows "unsupported message" for rich slideshow | Rich Messages are Bot API 10.1+, some clients haven't updated; keep the classic album path as a fallback when the client is known-old |
