# Link preview control — Bot API and MTProto (userbot)

Two entirely different mechanisms for the same visual effect: the rich card above (or below) a
text message. Open this file when a bot is skipping preview at random, when a userbot needs to
force a preview from a URL that is not visible in the text, or when the preview keeps rendering
the wrong URL from the message body.

## Which side controls what

| Concern | Bot API (`sendMessage`) | Userbot MTProto (`SendMediaRequest`) |
|---|---|---|
| Preview URL | `link_preview_options.url` | `InputMediaWebPage.url` |
| Preview above / below text | `show_above_text: true` | `SendMediaRequest.invert_media=True` |
| Force large media | `prefer_large_media: true` | `InputMediaWebPage.force_large_media=True` |
| Force small media | `prefer_small_media: true` | `InputMediaWebPage.force_small_media=True` |
| Fallback if URL unresolvable | `optional` field on `link_preview_options` (**since 10.1**); before that: skips preview silently | `InputMediaWebPage.optional=True/False` |
| Disable preview entirely | `link_preview_options.is_disabled: true` | `SendMessageRequest(no_webpage=True)` (different call) |
| Inline keyboards | ✅ | ❌ userbot cannot attach inline keyboards |
| Comments discussion (linked group) | Works normally in a public channel | Works when the userbot is a member of the linked group |

Rule of thumb: bots get buttons and colored keyboards, userbots get comment threads that read
as posts from a human. If you need both — post twice.

## MTProto: send a message with a controlled preview

```python
from telethon import TelegramClient
from telethon.tl.functions.messages import SendMediaRequest, SendMessageRequest
from telethon.tl.types import InputMediaWebPage, MessageEntityBlockquote
from telethon.extensions import html as tl_html

async def send_with_preview(client: TelegramClient, chat: str, html_text: str,
                             preview_url: str | None):
    text_plain, entities = tl_html.parse(html_text)
    peer = await client.get_input_entity(chat)

    if preview_url:
        req = SendMediaRequest(
            peer=peer,
            media=InputMediaWebPage(
                url=preview_url,
                force_large_media=True,
                optional=True,         # see "optional field" below
            ),
            message=text_plain,
            entities=entities,
            invert_media=True,          # preview above the text
        )
    else:
        req = SendMessageRequest(
            peer=peer,
            message=text_plain,
            entities=entities,
            no_webpage=True,
        )
    return await client(req)
```

Notes on the arguments:

- `parse_mode="html"` on `send_message` cannot express `invert_media` or a URL that is not in the
  text. That is why the raw request is used.
- `entities` come from Telethon's HTML parser. `MessageEntityBlockquote` supports
  `collapsed=True` (Telethon 1.36+) — pass it explicitly if the HTML source uses plain
  `<blockquote>` and you want collapsed behaviour:

  ```python
  for e in entities or []:
      if isinstance(e, MessageEntityBlockquote):
          e.collapsed = True
  ```
- `<blockquote expandable>` in the HTML source is parsed as a **collapsed** blockquote by newer
  Telethon; older versions ignore the attribute.

## The `optional` field on InputMediaWebPage

This is the switch that decides how strictly Telegram treats your preview URL.

| Value | Behaviour on the server |
|---|---|
| `optional=True` | Try to render the preview from `url`. If the URL is unresolvable, times out, has no OG tags, or is currently in the negative cache — **send the message anyway without a preview**. |
| `optional=False` | The URL must resolve to a webpage entity. If it does not, the whole `SendMediaRequest` **fails** with `WEBPAGE_NOT_FOUND` / `WEBPAGE_CURL_FAILED` / `WEBPAGE_MEDIA_EMPTY`, and the message is not sent. |

Trade-off:

- `optional=True` gives 100% send success but **variable preview**. On the exact same content
  the preview may render one time and be absent the next, because other URLs in the message
  text can win the preview arbitration (see below).
- `optional=False` gives **deterministic preview** but the message can be dropped if your OG
  host is slow, down, or Telegram's preview crawler has a stale negative cache entry.

Common production pattern: try `optional=False` first, on `RPCError.WEBPAGE_*` fall back to
`SendMessageRequest(no_webpage=True)` so the message still lands.

## Preview arbitration when the text also contains URLs

The MTProto server does not simply obey `InputMediaWebPage.url` when the message body contains
other URLs. Empirically:

- `t.me/...` links inside the message body **win over** your `InputMediaWebPage.url` under
  `optional=True`. If the `t.me` link is a bot deep-link (`t.me/somebot?start=...`) — bots have
  no rich preview and the resulting preview is empty. Result: your carefully hosted OG card
  disappears.
- External `https://` links (Twitter/X, GitHub, Wikipedia, etc.) do **not** win over
  `InputMediaWebPage`; your URL is used.
- Escaping visibility with `<a href="…">visible text</a>` does not fully suppress the
  arbitration — Telegram still parses the href as a candidate.

Mitigations:

- `optional=False` — Telegram is forced to use your URL, arbitration is bypassed. Combine with
  fallback on `WEBPAGE_*` errors.
- Strip or rewrite `t.me/*` URLs in the message body if they are secondary information
  (e.g. lift them into buttons for a bot; for a userbot post, drop them into a footer as
  `MessageEntityTextUrl` with visible label but no raw URL).

## Preview above vs below the text

- Bot API: `link_preview_options: { "show_above_text": true }` — since Bot API 7.0
  (Dec 2023). Bot must be able to send the message; it is a purely presentational field.
- MTProto: `SendMediaRequest.invert_media=True`. The name is legacy from photo captions where
  "inverted" meant "media above caption instead of below". Same visual effect.

Without either flag the preview renders below the text (the default since Telegram's inception).

## Hosting the URL that Telegram will crawl

The preview URL you put in `link_preview_options.url` or `InputMediaWebPage.url` is fetched by
a Telegram-side crawler ("preview service" — sometimes announces itself as
`TelegramBot (like TwitterBot)`, sometimes just `Mozilla/5.0`). Requirements:

### HTML side

- Correct OG tags: `og:title`, `og:image`, `og:description`, `og:type`.
- `og:image:width` and `og:image:height` are recommended; without them, Telegram may under-scale
  the image.
- `og:image` URL must return a raster image (PNG/JPEG/WebP). SVG and animated GIF work
  inconsistently; use PNG or JPEG for reliability.
- Do **not** rely on `<meta http-equiv="refresh">` for redirecting the crawler — Telegram
  follows the refresh and treats the destination as the preview target. If your goal is
  `og:image` from one host and a click-through to another, use JS `location.replace()` for
  humans and serve a header-less HTML variant to the `TelegramBot` User-Agent:

  ```python
  ua = (request.headers.get("User-Agent") or "").lower()
  is_crawler = "telegrambot" in ua or "tdesktop" in ua
  redirect_html = "" if is_crawler else f'<script>location.replace({dest_url!r})</script>'
  ```

### Timing side

- Telegram's crawler timeout is roughly **1–2 seconds** end-to-end. If your HTML endpoint plus
  the `og:image` fetch takes longer, the crawler gives up and caches "not found".
- **`og:image` must be independently fast** — the crawler fetches it as a separate request. If
  your `og:image` URL calls out to a slow upstream (e.g. a third-party chart API), pre-warm it
  or proxy through a fast local cache. 200 KB PNG served in <200 ms is a safe target; > 500 KB
  starts causing preview to be absent under load.

### HTTP side

- HTTPS is required. Let's Encrypt via `certbot --nginx -d preview.example.com` is standard.
- Serve `Cache-Control: public, max-age=300` on the OG-image endpoint to let the crawler and
  browsers cache. Telegram respects HTTP caching for the image, not for the HTML page.
- Redirects (301/302) are followed. Do not redirect the HTML page to a URL with different
  OG tags — the crawler uses the final URL as the preview URL.

## Telegram-side preview cache

The preview service maintains an **aggressive positive and negative cache** keyed on the full
URL. Observable behaviour:

- After a successful render, the same URL keeps returning the same preview for **5–30 minutes**
  even if the underlying OG tags change. Include a cache-buster in the query string
  (`&t={unix_ts}` or a per-message nonce) if the preview content must change per post.
- After `og:image` returns a 5xx or times out, Telegram caches "no preview" for **5–15 minutes**
  for that URL. Fixing the upstream in the meantime does not help — new send calls with the
  same URL will still show no preview until the negative cache expires. Use a fresh URL.
- Per-bot per-domain rate limits exist (unofficially confirmed by behaviour): sending many
  preview URLs to the same host from one bot in a short window causes the crawler to skip
  every N-th URL entirely. Symptom: preview appears for the first N posts, is absent for the
  next M posts. Mitigation: spread previews across subdomains, batch fewer per minute, or
  serve the OG image directly (no redirect) so the crawler finishes faster.

Path uniqueness helps cache-busting more than query uniqueness: `/preview/{nonce}/page?…`
survives some intermediary caches that strip or ignore query strings.

## Errors on `SendMediaRequest` with `InputMediaWebPage`

| RPCError | Meaning | Common cause |
|---|---|---|
| `WEBPAGE_NOT_FOUND` | Crawler could not fetch the URL, or it is in the negative cache. | Slow upstream, wrong hostname, negative cache from a previous failure. |
| `WEBPAGE_CURL_FAILED` | Network-level failure fetching the URL. | DNS, TLS handshake, connection refused, timeout. |
| `WEBPAGE_MEDIA_EMPTY` | HTML fetched but no `og:image` (or the image itself failed). | Missing meta tags, image endpoint returned non-image content-type. |
| `MEDIA_INVALID` | The `InputMediaWebPage` structure was rejected. | Sending it in a chat type that does not accept media (e.g. some anonymous channels). |
| `MESSAGE_TOO_LONG` | `message` field exceeds ~4096 chars. | Long captions with many blockquote entities. Truncate before send. |

## Bot API side quick reference

Since Bot API 7.0 the shape is `sendMessage` with `link_preview_options`:

```jsonc
{
  "chat_id": "@channel",
  "text": "…HTML with entities…",
  "parse_mode": "HTML",
  "link_preview_options": {
    "url": "https://preview.example.com/card/abc",
    "show_above_text": true,
    "prefer_large_media": true,
    "is_disabled": false
  },
  "reply_markup": {"inline_keyboard": [[{"text": "Open", "url": "…", "style": "success"}]]}
}
```

- `style: "success" | "primary" | "danger"` — coloured buttons since Bot API 9.4
  (Feb 2026). Green / blue / red respectively. Buttons in channels always render as
  standard blue regardless of `style` — the field is silently ignored.
- Bot API does **not** support `invert_media` for the same message layout the way MTProto does.
  `show_above_text` is the only preview-position knob.
- `link_preview_options.url` on a bot behaves like `optional=True` — never fails the send.
  Bot API 10.1 added an `optional` field mirroring MTProto semantics; when `false`, the send
  fails on unresolvable URLs (see Rich Messages).

## Common mistakes

| Symptom | Cause |
|---|---|
| Preview appears once, then never for that URL. | Positive Telegram cache. Add per-send nonce or timestamp to the URL. |
| Preview absent for every send from a userbot that includes a `t.me/…` URL in the body. | MTProto preview arbitration picks the `t.me` URL over your `InputMediaWebPage.url`. Move the URL to a `MessageEntityTextUrl` footer or set `optional=False`. |
| `WEBPAGE_NOT_FOUND` on `SendMediaRequest` while the URL works in a browser. | `og:image` fetch is timing out for the crawler even though the HTML is fast. Serve `og:image` from a local cache and shrink it under 200 KB. |
| Bot API `link_preview_options.url` renders no preview and no error. | Bot API preview is `optional`-by-default. There is no error surface; check with `curl -A "TelegramBot"` and see if the crawler is even reaching your host. |
| Coloured button (`style: "success"`) is grey in a channel post. | Coloured buttons are ignored in channel-broadcast chats. Green renders only in private/group/supergroup. |
| Preview above text works on iOS but not on Android/Desktop. | Stale client. `show_above_text` and `invert_media` shipped everywhere in 2023-Q4. Users on very old clients degrade to "below". |
| `optional=False` intermittently fails with `WEBPAGE_NOT_FOUND` even though the URL is up. | Telegram negative cache from an earlier transient failure. Wait 15 min or use a fresh URL. |
| Preview shows the OG tags of the *destination* URL after a redirect, not the tags on your own page. | Meta-refresh or HTTP 301/302 to a different host — the crawler follows and re-parses. Split by User-Agent. |
| Preview is stuck at Twitter's card even though you set your own URL. | `t.me` / `twitter.com` / `x.com` URLs in the body outrank yours under `optional=True`. Rewrite them as text-links or use `optional=False`. |
