# OG preview image server

A small HTTP service that a bot or userbot sends links to, and Telegram's preview crawler
scrapes to render the card above/below a message. Open this file when building the second
half of a message-with-preview pipeline: the message-sending side is in
[link-preview-control.md](link-preview-control.md); this one covers the hosting side —
serving the OG-tagged HTML, rendering the image, caching, User-Agent handling, and staying
under the crawler's timeout budget.

## Two endpoints, one contract

The service exposes at least two endpoints:

| Path | Response | Cache-Control |
|---|---|---|
| `/page/{nonce}?…` | `text/html` with OG tags | `no-store` (crawler recrawls per URL) |
| `/img/{token}.png` | `image/png` | `public, max-age=300` (crawler and browsers cache) |

The bot sends the `/page/{nonce}` URL in `link_preview_options.url` (Bot API) or
`InputMediaWebPage.url` (MTProto). Telegram fetches it, parses `og:image`, then fetches the
image. Nonce/token are per-message — they let you cache-bust the crawler's per-URL cache when
the underlying content changes.

Reasonable defaults:

```
GET /page/{nonce}?symbol=…&user=…&…   → HTML
GET /img/{token}.png                  → PNG (nonce not needed here; content-addressed)
```

## The HTML page — minimum viable OG

```html
<!doctype html>
<meta charset="utf-8">
<title>{{ title }}</title>
<meta property="og:title" content="{{ title }}">
<meta property="og:description" content="{{ description }}">
<meta property="og:image" content="{{ img_url }}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
```

- `og:image:width`/`height` are **not optional in practice** — without them Telegram often
  renders a small thumbnail on mobile clients even when the image itself is 1200×630.
- Twitter card tags are read by some clients as a fallback. Include them; they are three
  lines and cost nothing.
- 1200×630 (1.91:1) is the size Telegram scales to on desktop. 1080×1080 works on mobile but
  looks empty on desktop. Do not use dimensions outside `1200×628`..`1200×1200`.

If the user should be redirected somewhere on click (e.g. from the HTML page to a deep-link),
**do not use `<meta http-equiv="refresh">`** — the crawler follows it and treats the
destination as the preview target, losing your OG tags. Instead:

```python
async def render_page(request):
    ua = (request.headers.get("User-Agent") or "").lower()
    is_crawler = "telegrambot" in ua or "twitterbot" in ua
    redirect_html = "" if is_crawler else f'<script>location.replace({dest_url!r})</script>'
    return web.Response(text=HTML_TEMPLATE.format(..., redirect=redirect_html),
                        content_type="text/html", headers={"Cache-Control": "no-store"})
```

Human browsers get the JS redirect; the crawler gets the OG page.

## The image endpoint — Pillow composition

The image is where dynamic content goes: chart, avatar, quote, badges. Pillow is enough for
95% of cases; reach for skia or PIL alternatives only for gradients / masks that Pillow's
`ImageDraw` cannot express.

```python
from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 630
canvas = Image.new("RGB", (W, H), (18, 18, 20))
d = ImageDraw.Draw(canvas)

# rounded card
d.rounded_rectangle((40, 40, W - 40, H - 40), radius=24, fill=(28, 28, 32))

# text
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 48)
d.text((80, 80), f"${symbol}", font=font, fill=(220, 220, 220))

# save to a BytesIO for HTTP response
buf = io.BytesIO()
canvas.save(buf, format="PNG", optimize=True)
```

Fonts on a stock Ubuntu / Debian image:

- `/usr/share/fonts/truetype/dejavu/DejaVuSans*.ttf` — always present, covers Latin+Cyrillic
- Emoji glyphs: install `fonts-noto-color-emoji` and load
  `/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf` — Pillow renders monochrome outline;
  colored emoji requires `Pillow[Freetype2]` + a compatible build. For the crawler it does
  not matter much — the PNG the crawler sees is opaque.

For UI fonts like Geist / Inter, ship the `.ttf` inside the container/deploy and load with
a full path. `fc-cache` is not needed for `ImageFont.truetype` — it uses direct file paths.

### `contain` vs `cover` when embedding third-party images

When you paste an avatar / chart / user-supplied photo into the composition:

- `cover` — resize the image so it fills the target box, cropping the overflow. Correct for
  square avatars into square slots.
- `contain` — resize to fit inside the target box preserving aspect, letterbox the rest. Use
  for user-supplied images of unknown aspect (landscape vs portrait) where cropping would
  lose meaningful content (a screenshot with text at the edge).

```python
def paste_contain(canvas, src, box):
    x0, y0, x1, y1 = box
    bw, bh = x1 - x0, y1 - y0
    scale = min(bw / src.width, bh / src.height)
    new_w, new_h = int(src.width * scale), int(src.height * scale)
    src = src.resize((new_w, new_h), Image.LANCZOS)
    ox = x0 + (bw - new_w) // 2
    oy = y0 + (bh - new_h) // 2
    canvas.paste(src, (ox, oy))
```

`contain` is the safer default for user-supplied media. It also protects against a common
failure mode where the user-supplied image is a screenshot of a chart of a similar topic —
`cover` scales it into the same aspect as your own chart slot, and the two look identical
next to each other. `contain` letterboxes it so the sizes visibly differ.

## Two-layer cache — hot memory + disk

The image endpoint is the hot path. Rendering fresh from Pillow on every request wastes CPU
and blows the crawler's timeout. Layer the cache:

```python
import time, io
from pathlib import Path

CACHE_DIR = Path("/var/cache/preview-server")
CACHE_DIR.mkdir(parents=True, exist_ok=True)

_MEMORY = {}   # token -> (image_bytes, expires_at)
_MEMORY_TTL = 60          # seconds
_DISK_TTL   = 24 * 3600   # seconds; keeps stale-fallback usable

async def get_or_render(token: str, render_fn) -> bytes:
    now = time.time()

    # 1. hot memory
    hit = _MEMORY.get(token)
    if hit and hit[1] > now:
        return hit[0]

    # 2. warm disk
    disk = CACHE_DIR / f"{token}.png"
    if disk.exists() and (now - disk.stat().st_mtime) < _DISK_TTL:
        data = disk.read_bytes()
        _MEMORY[token] = (data, now + _MEMORY_TTL)
        return data

    # 3. render fresh, backfill both layers
    data = await render_fn()
    disk.write_bytes(data)
    _MEMORY[token] = (data, now + _MEMORY_TTL)
    return data
```

- **Hot TTL short** (30–120 s) — the crawler makes at most a handful of requests per URL,
  and the message text keys the token, so long memory TTLs waste RAM.
- **Disk TTL long** (hours to a day) — enables stale-fallback (below).
- `token` should be content-addressed (hash of the parameters that affect the image), not the
  message id. Two identical enrichments then share a cache slot.

## Stale-fallback when upstream dies

The rendering usually depends on an upstream API (chart provider, avatar source, price
service). When that upstream returns 5xx or times out, do **not** return an error — Telegram
will cache the failure and stop trying for 5–15 minutes. Return the last successful render
instead:

```python
async def render_with_stale_fallback(token: str, upstream_fn):
    try:
        return await asyncio.wait_for(upstream_fn(), timeout=1.5)
    except Exception:
        pass  # fall through

    disk = CACHE_DIR / f"{token}.png"
    if disk.exists():
        return disk.read_bytes()

    # last-resort placeholder — never return an HTTP error to Telegram
    return _PLACEHOLDER_PNG   # a pre-built "unavailable" 1200×630
```

The placeholder is a static PNG shipped with the service (a dark card with the service name,
nothing dynamic). Its only job is to keep the preview slot filled while the upstream heals.

## The Telegram crawler's timeout budget

Measured behaviour of the preview crawler in 2026:

- **~1.5 s** to fetch the HTML page and complete parsing.
- **~1.5 s more** to fetch `og:image`. Fetched as a separate connection, no HTTP/2 push.
- If either step exceeds ~2 s, the preview is dropped and the URL is negative-cached for
  5–15 min.

Practical size targets for the image endpoint:

| Format | Safe under 300 ms | Border case | Fails often |
|---|---|---|---|
| PNG optimized | < 150 KB | 150–300 KB | > 300 KB |
| JPEG q=85 | < 100 KB | 100–200 KB | > 200 KB |
| WebP q=80 | < 80 KB | 80–150 KB | > 150 KB |

If your composition is inherently large (many text runs, chart with fine grid), render at
higher resolution then downscale for the response, or drop to JPEG q=85. Do not ship 1 MB
PNGs — Telegram will silently omit the preview for a subset of your posts and you will not
see why.

## User-Agent split — the crawler-safe HTML

The crawler identifies as either `TelegramBot (like TwitterBot)` (main preview service) or
plain `Mozilla/5.0` (mobile clients pre-fetching for scroll). Serve the same OG tags to
both. But if the HTML also serves a human — for a CTA, deep-link redirect, or a fallback
page — split responses by UA:

```python
def is_telegram_crawler(request) -> bool:
    ua = (request.headers.get("User-Agent") or "").lower()
    return ("telegrambot" in ua) or ("tdesktop" in ua)
```

Rules of thumb:

- Serve the crawler a static, side-effect-free HTML page: OG tags, no JS, no cookies, no
  redirects. Response in < 200 ms.
- Serve humans whatever the product needs: JS `location.replace(...)`, analytics beacons,
  A/B assignment cookies.
- Do not gate by UA on the image endpoint — the crawler always fetches the image with a
  crawler UA, but a linked chat's inline expansion later fetches with a mobile UA. Same PNG.

## Rate-limit and per-domain preview throttling

When one bot posts many messages that all use OG previews from the same host, the crawler
starts skipping every N-th URL. Symptoms:

- The first 5–10 posts get previews.
- Posts 11–30 get random previews (~50%).
- The pattern recovers after 10–30 min of no fresh URLs.

Mitigations:

- **Multiple subdomains** — `p1.example.com`, `p2.example.com`, round-robin. Each subdomain
  keeps its own per-source counter.
- **Content-addressed URLs** with strong caching — repeated preview URLs share cache entries,
  reducing distinct URL load on the crawler.
- **Batch fewer per minute** — one preview per 5 seconds from the same bot is quiet enough
  that no throttling was observed.
- Do not use a single hostname for tens of thousands of unique URLs per hour with one bot
  identity. Split by content type (`chart.example.com` vs `avatar.example.com`) or add a
  redirect layer with independent cache keys.

## When user-supplied media is a bad hero image

Screener/mirror bots often receive posts where the user-attached image is not a meme or
avatar but a **screenshot of the same third-party UI** you are rendering below (a chart,
a leaderboard). Using it as the hero image of your card duplicates content and looks
broken.

Heuristic filter:

```python
from PIL import Image

def looks_like_dashboard_screenshot(path: str) -> bool:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    if w == 0 or h == 0:
        return False
    aspect = w / h
    # landscape rectangles are usually screenshots, not memes
    if not (1.3 < aspect < 2.4):
        return False
    # sample the image and check mean brightness
    thumb = im.resize((32, 32))
    px = list(thumb.getdata())
    mean = sum(sum(p) for p in px) / (len(px) * 3)
    return mean < 60   # very dark background → chart / terminal / dashboard
```

When the check returns `True`, fall back to a synthesized card (avatar + text) instead of
using the user-supplied image. False-positive rate on a screener corpus was ~5%; adjust the
thresholds against your own sample.

## Systemd unit template

Pattern used for a Python aiohttp server serving preview traffic. Minimal, restart-always:

```ini
[Unit]
Description=OG preview image server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/preview-server
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/opt/preview-server/.env
ExecStart=/opt/preview-server/.venv/bin/python -m preview_server
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Front it with nginx for TLS. The nginx block only needs SSL termination and a proxy_pass;
do not add rate-limiting on the image endpoint or the crawler starves. Access log format
that captures crawler activity:

```
log_format preview '$remote_addr $host "$request" $status $body_bytes_sent '
                   '"$http_user_agent" ${request_time}s';
```

Filter by `TelegramBot` in the UA to see exactly which URLs the crawler is fetching and how
long each request takes — the primary debug tool for "why is preview missing on this post".

## Common mistakes

| Symptom | Cause |
|---|---|
| Preview appears once, then never for the same URL. | Cache-bust with a nonce per message. Telegram positive-caches URL→image. |
| Preview missing on every N-th post from the same bot. | Per-bot per-domain crawler throttle. Split by subdomain or slow the send rate. |
| Preview shows a small thumbnail on mobile, big card on desktop. | Missing `og:image:width` / `og:image:height`. Add them. |
| Image endpoint returns 200 OK in browser but Telegram fetches "not found". | Image endpoint takes > 1.5 s. Move upstream calls to a background warmer, serve from cache. |
| Preview renders the destination URL after a redirect, not your page. | `<meta http-equiv="refresh">` — the crawler follows. Use a JS redirect and split by UA. |
| PNG is 1.2 MB and preview is dropped silently. | Compress. Target < 200 KB PNG or drop to JPEG q=85. |
| Local dev serves the preview but Telegram cannot fetch it. | `localhost` / `127.0.0.1` / non-HTTPS. The crawler needs a public HTTPS URL — use ngrok / cloudflared for local previews. |
| Preview stuck at old content after the underlying data changed. | Positive cache. Include the affected fields in the URL nonce so the crawler sees a new URL. |
| Font glyphs render as boxes / missing chars in Pillow. | `ImageFont.truetype` loaded a font missing that glyph. Load a fallback font (DejaVu covers Latin+Cyrillic; Noto Sans CJK for CJK). |
| Emoji in Pillow-rendered text are monochrome outlines. | `ImageFont.truetype` renders emoji as outline glyphs. Use `Pilmoji` (a Pillow wrapper that composites color emoji from Twemoji SVGs) or replace emoji with images in your layout. |
| First request after boot takes 3–5 s and Telegram drops the preview. | Cold start of Pillow / font-cache. Warm the process with a synthetic render on boot before opening the listen socket. |
