# Inline mode + Mini App (WebApp) — practical patterns

Two adjacent problems that hit any product bot: giving users a way to search-and-share your bot
inline, and hosting an external booking/checkout URL that works inside Telegram's webview.

## Inline mode with a big photo above the text

Bot must have inline mode enabled in @BotFather (owner-only). Then handle
`OnInlineQuery` and answer with `answerInlineQuery`.

### The naïve approach that FAILS

An `article` result with `input_message_content` that just contains the text — Telegram shows a
small thumbnail in the dropdown, and the sent message renders as plain text with no image on top.

### The working recipe: OG preview + article

Each item you offer inline needs its own **public OG-tagged HTML page**. Telegram's server
crawls the URL you put in `link_preview_options.url` and shows the parsed `og:image` above the
text.

```jsonc
// answerInlineQuery result (raw JSON via bot.Raw / bot.session.request)
{
  "type": "article",
  "id":   "item-standard",
  "title": "Item title",
  "description": "Short description…",
  "thumbnail_url": "https://example.com/items/standard/thumb.jpg",
  "input_message_content": {
    "message_text": "*Item title*\n…",
    "parse_mode":   "HTML",
    "link_preview_options": {
      "url": "https://your-host.example/items/og/standard.html",
      "prefer_large_media":  true,
      "show_above_text":     true
    }
  },
  "reply_markup": {
    "inline_keyboard": [[
      {"text":"Details","url":"https://t.me/mybot?start=item_standard"}
    ]]
  }
}
```

The OG page is a static HTML with just the meta tags:

```html
<!doctype html><meta charset="utf-8">
<title>Item title — Brand</title>
<meta property="og:title"       content="Item title">
<meta property="og:description" content="Short description…">
<meta property="og:image"       content="https://your-host.example/items/standard.jpg">
```

Publish one OG page per item; hostname is your choice (a static folder behind nginx is enough).
`OG_BASE_URL` in `.env` + `{OG_BASE_URL}/<id>.html`.

### Gotchas that cost hours

- **Raw `.jpg` in `link_preview_options.url` does NOT trigger a big preview.** Telegram wants an
  HTML page with `og:image`, not the image itself.
- **`answerInlineQuery` needs Raw**, not the telebot/aiogram wrapper, if you want
  `link_preview_options` — the wrappers strip unknown fields.
- **`ChosenInlineResult` / the sent message**: MTProto's `m.web_preview` returns `None` right
  after the click. Telegram fetches the OG page asynchronously (~7 s in practice). Verify by
  clicking the inline result in Saved Messages, sleeping 7 s, re-fetching the message, and
  checking `MessageMediaWebPage` with `.webpage.photo` set.
- **Inline can't carry a photo carousel.** Inline is one message; if you need a swipe-carousel,
  put a URL-button `Details` with a deep-link (`t.me/bot?start=<id>`) that opens the bot and
  sends the full rich `slideshow` card.
- **Editing your bot's @BotFather settings from a user session:** if the bot-owner account is
  the same user session (Telethon), you can drive @BotFather to `/setinline` / `/setcommands`
  programmatically — no manual clicks. Same trick as @Stickers for emoji packs.

## Mini App (WebApp) — hosting an external URL through your own loader

Requirement: a button on a message opens a third-party checkout / booking / catalog that
happens to be slow, cookie-heavy, or SPA-only. Telegram's webview partitions cookies and
localStorage **per top-level origin**, so an iframe embed of the third-party site breaks their
session on the first load.

### The problem, concretely

- Button `web_app: {url: "https://booking-vendor.example/property/…"}` → opens in Telegram webview.
- Vendor page sets `SameSite=Lax` cookies for auth; webview's iframe/cookie partitioning drops them.
- First open: white screen or "please refresh". Second open (after refresh): works. Users
  don't refresh, they leave.

### The fix: a thin loader you host, that top-level-redirects

Host a small HTML page on your own domain. Telegram opens it directly (no iframe), it shows a
brief branded splash, then does a **top-level navigation** to the real URL. Cookies are then
first-party for the vendor.

```html
<!-- /var/www/booking-loader/index.html — behind nginx, HTTPS, CSP allows telegram.org -->
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="preconnect" href="https://booking-vendor.example">
<style>
  body { display:grid; place-items:center; min-height:100dvh; background:#FBF4F1; }
  .brand { animation: rise .6s ease-out both; }
  @keyframes rise { from{opacity:0;transform:translateY(6px)} to{opacity:1} }
  progress { accent-color:#6E3B44; }
</style>
<div class="brand"><img src="data:image/png;base64,…logo…" alt=""></div>
<progress></progress>
<script>
  window.Telegram?.WebApp?.ready?.();
  window.Telegram?.WebApp?.expand?.();
  setTimeout(() => window.location.replace("__REAL_URL__"), 900);
</script>
```

- **Telegram fetches the loader as a Mini App** (needs
  `Content-Security-Policy: frame-ancestors https://*.telegram.org` on that domain). The loader
  is not iframed by the vendor — it's the top document, so `window.location.replace` is a
  first-party navigation.
- **Never keep the vendor page in an iframe** — that reintroduces the cookie partitioning.
- `preconnect` warms TLS while the splash is on screen. 900 ms is enough for a logo animation
  without adding real latency.
- Config it via `BOOKING_WEBAPP_URL` in bot `.env`, so you can swap loader hosts without redeploying.

### CSP + hosting checklist

- Loader domain must send `Content-Security-Policy: frame-ancestors https://*.telegram.org`
  (or omit CSP entirely).
- The same CSP does not prevent OG previews (Telegram fetches HTML over HTTP, doesn't iframe it).
- Use nginx `location /booking/ { root /var/www/; }` on an existing HTTPS host, add a Let's
  Encrypt cert covering that host, done.
- For per-item OG pages (see above), reuse the same host — just publish them into a subfolder
  like `/booking/og/<id>.html`.

### Verifying the loader from an SSH terminal

`curl -I https://your-host.example/booking/` → 200, `content-security-policy` header includes
`frame-ancestors https://*.telegram.org`. Fetch the HTML, confirm the `<script>` includes the
top-level `window.location.replace`. Then open the bot as your user session and click the
`web_app` button — the vendor page should load first-try.

## Validating `initData` — the Mini App auth boundary

Everything a Mini App receives about the user arrives in `window.Telegram.WebApp.initData`:
a query-string containing `user`, `chat`, `auth_date`, `query_id` and a `hash`. It is sent by
the client, so **it is user-controlled input**. A Mini App that trusts `initDataUnsafe.user.id`
lets anyone read or buy as any user by editing one field.

The `hash` is an HMAC the backend must verify. The signing key is derived from the bot token,
so the check runs server-side only — never ship the token to the page.

### Algorithm

1. Parse `initData` as a query string; take `hash` out of the pairs.
2. Sort the remaining `key=value` pairs by key, join with `\n` → *data-check-string*.
3. `secret_key = HMAC_SHA256(key="WebAppData", msg=bot_token)`.
4. Expected hash = `HMAC_SHA256(key=secret_key, msg=data_check_string)`, hex.
5. Compare in constant time; then reject stale `auth_date`.

Note the inversion in step 3: the literal `"WebAppData"` is the HMAC **key** and the token is
the message. Swapping them is the usual reason a correct-looking implementation never validates.

```python
import hashlib, hmac, time
from urllib.parse import parse_qsl

def verify_init_data(init_data: str, bot_token: str, max_age: int = 86400) -> dict:
    pairs = dict(parse_qsl(init_data, strict_parsing=True))
    received = pairs.pop("hash", "")
    check_string = "\n".join(f"{k}={pairs[k]}" for k in sorted(pairs))

    secret = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    expected = hmac.new(secret, check_string.encode(), hashlib.sha256).hexdigest()

    if not hmac.compare_digest(expected, received):
        raise ValueError("bad initData signature")
    if max_age and time.time() - int(pairs.get("auth_date", 0)) > max_age:
        raise ValueError("initData expired")
    return pairs          # pairs["user"] is a JSON string
```

```go
func VerifyInitData(initData, botToken string, maxAge time.Duration) (url.Values, error) {
    v, err := url.ParseQuery(initData)
    if err != nil {
        return nil, err
    }
    received := v.Get("hash")
    v.Del("hash")

    keys := make([]string, 0, len(v))
    for k := range v {
        keys = append(keys, k)
    }
    sort.Strings(keys)
    parts := make([]string, 0, len(keys))
    for _, k := range keys {
        parts = append(parts, k+"="+v.Get(k))
    }

    secret := hmac.New(sha256.New, []byte("WebAppData"))
    secret.Write([]byte(botToken))
    mac := hmac.New(sha256.New, secret.Sum(nil))
    mac.Write([]byte(strings.Join(parts, "\n")))

    if !hmac.Equal([]byte(hex.EncodeToString(mac.Sum(nil))), []byte(received)) {
        return nil, errors.New("bad initData signature")
    }
    ts, _ := strconv.ParseInt(v.Get("auth_date"), 10, 64)
    if maxAge > 0 && time.Since(time.Unix(ts, 0)) > maxAge {
        return nil, errors.New("initData expired")
    }
    return v, nil
}
```

### Rules

- **Verify on every request**, not once at load. The page can call the API many times; each
  call carries `initData` in a header (commonly `Authorization: tma <initData>`).
- **Take the user id from the verified payload**, never from a request body field the page
  filled in.
- **`initDataUnsafe` is for rendering only** — the name is literal. Greeting by first name is
  fine; deciding what to sell is not.
- **Enforce `auth_date`.** Without it a leaked `initData` string works forever.
- **`query_id` is single-use** and only present when the Mini App was opened from a keyboard
  button; it is what `answerWebAppQuery` consumes.
- Requests signed for one bot validate only against that bot's token — with several bots,
  pick the token by which bot the request claims to come from, then verify.

## Testing without your own device

- Send the bot the inline query from your Telethon user session:
  `await client.get_inline_bot_results(bot_username, "ter")` → list of results with `article` +
  media metadata (post-Telegram-crawl).
- Click a result from Saved Messages: `msg = (await client.get_messages("me", limit=1))[0]`;
  `await msg.click(...)`.
- Confirm OG preview: wait ~7 s, re-fetch the message, assert `msg.media` is
  `MessageMediaWebPage` and `msg.media.webpage.photo` is non-empty.
