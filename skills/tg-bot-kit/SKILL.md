---
name: tg-bot-kit
description: >
  Building production Telegram bots — aiogram 3 and Go + telebot.v3. Covers premium (custom
  animated) emoji via Bot API 9.4, colored inline buttons, rich HTML and Bot API 10.1 Rich
  Messages (`heading`/`table`/`slideshow`/`details`, edit-in-place), inline mode with OG-preview
  big photos, WebApp Mini-App loader (top-level redirect to bypass webview cookie
  partitioning) plus server-side `initData` HMAC verification, file_id media cache and
  classic media groups (albums), Telegram Stars (XTR) native payments with
  `pre_checkout_query`+`successful_payment`, a unified invoice + payment-webhook model with
  HMAC signature verification for CryptoBot / xRocket / OxaPay / YooKassa / platega, the full
  closed-channel subscription flow (kick+unban, expiry warnings, referrals, promo codes),
  mass broadcasts with rate limiting and resume-safe idempotency, in-memory FSM (aiogram
  MemoryStorage / Go state map) for text-input flows, deep-links / `?start=<payload>` /
  `?startapp=<payload>` and `setMyCommands` scope sync, groups and supergroup / forum-topic
  administration, join-time captcha + trust-ramp + content-filter moderation for community
  bots, webhook vs long-polling trade-offs with `secret_token` and `getWebhookInfo` alerting,
  Prometheus metrics and structured JSON/logfmt logs with `update_id`/`user_id` context, a
  self-hosted Bot API server for >50MB uploads / >20MB downloads, RU/EN/UA localization,
  cloning a competitor bot's UI through a Telethon user session, running E2E tests in CI
  against a real bot with the same session, and the mac-tar/rsync deploy hazards that eat
  productions. Invoke when building, extending, or debugging a Telegram
  shop/service/community bot; when a task mentions custom/premium emoji, colored buttons,
  rich messages, inline mode, Mini App / initData validation, file_id caching, media groups /
  albums, Stars payments, webhook signature verification, FSM flows, subscription gating,
  broadcasts / mass messaging, deep links / start payloads, BotFather commands, forum topics,
  group moderation / captcha / anti-spam, webhook vs polling, metrics / observability,
  self-hosted Bot API, or reconning another bot's screens.
---

# tg-bot-kit — Telegram bot building kit

Distilled from building production Telegram bots on two stacks: **aiogram 3 + Python** and
**Go + telebot.v3**. Same tricks, different mechanics — every modern Bot API surface (Bot API
9.4 coloured buttons / custom emoji, Bot API 10.1 Rich Messages, `link_preview_options`) is
delivered via a Raw call because neither library wraps them natively yet. Concrete patterns and
verified schemas live in `reference/`.

## Stack
- **aiogram 3.x**, Python 3.12+, **SQLite**, aiohttp webhook server, systemd (long-polling).
- One `Bot(token, default=DefaultBotProperties(parse_mode=ParseMode.HTML))`, one `Dispatcher`.
- Files: `bot.py` (all handlers) · `config.py` (settings/catalog/prices) · `db.py` (SQLite) ·
  `keyboards.py` (inline kb) · `texts.py`+`texts_ru/en.py` (localized strings) ·
  `emoji_map.py` (premium emoji) · `*_api.py` (each upstream) · `publish_legal.py` (telegra.ph docs).

## Premium (custom) emoji — Bot API 9.4
Requirement: **the bot-owner account must have Telegram Premium** to send custom emoji
(this is NOT the old Fragment rule). Two places they appear:

1. **In message text** (HTML parse mode): wrap the glyph in `<tg-emoji emoji-id="ID">😀</tg-emoji>`.
   Pattern (`emoji_map.premiumize`): `html.escape(text)` first, then replace known glyphs with
   their `<tg-emoji>` wrapper. Keep a `GLYPH_TO_ID` dict `{ "⭐": 5848259999763011021, ... }`.
   A `PREMIUM_EMOJI=off` env fallback should skip wrapping → plain unicode (looks the same, no animation).
2. **On inline buttons**: `InlineKeyboardButton(text=..., callback_data=..., icon_custom_emoji_id="ID")`.

**Colored buttons** (same Bot API 9.4): `InlineKeyboardButton(..., style="success" | "primary" | "danger")`.
Wrap your button factory: `cb(text, data, style=None, icon=None)` / `url(text, link, style, icon)`.

**Finding emoji ids** (via a Telethon user session, see recon below):
- From a message you received: iterate `message.entities` → `MessageEntityCustomEmoji.document_id`.
- By keyword: `client(SearchCustomEmojiRequest(emoticon="🌐", hash=0))` → list of document ids.
- Never invent an id — a wrong id silently breaks the button/emoji. Pull a real one first.

**Own an emoji pack** (so you don't leak the source pack's name): download the docs and re-publish.
See `reference/emoji-pack.md`.

## Rich text (HTML parse mode)
- `<b>`, `<i>`, `<code>`, `<a href>`, and **`<blockquote expandable>…</blockquote>`** (collapsible).
  Build blockquote/`<tg-emoji>` **after** `html.escape` so the tags survive.
- Monospace copy-links: `<code>t.me/bot?start=…</code>`.

## Rich Messages (Bot API 10.1) — document-grade content, edit-in-place
When HTML parse mode isn't enough (tables, swipeable carousels, collapsible sections, media
that redraws in place), use `sendRichMessage` / `editMessageText` with a `rich_message: {"blocks": […]}`
payload via Raw. **`editMessageText` + `rich_message` converts a plain text message into rich
in place** — `reply_markup` (including coloured buttons) survives, and a `slideshow` swap
becomes a live in-cell edit instead of a new message.

Verified block types: `heading` (`size` 1|2 + `text`), `paragraph`, `table` (`cells` grid),
`divider`, `list`, `blockquote` (wraps `blocks`, not `text`; supports `collapsed`/`expandable`),
`collage`, **`slideshow`** (swipeable carousel — `blocks: [photo…]`), `details` (collapsible),
`photo`/`video`/`audio` (double-nested: `{"type":"photo","photo":{"type":"photo","media":"<file_id>"}}`).

Traps that will cost a deploy: the docs are wrong or silent about half of this. `type:"plain"`
is invalid. `paragraph` with `align:"center"` is silently ignored — centring requires a 1×1
table cell. `details` needs `summary` + `title` + `header` set to the same string (a lone
`title` renders an empty arrow). `slideshow` uses `blocks`, not `items`/`photos`/`media` (those
return `RICH_MESSAGE_EMPTY`). Custom emoji inside text arrays go as
`{"type":"custom_emoji","custom_emoji_id":"<id>","alternative_text":"⬜"}` — note
`alternative_text`, not `text`. **The API silently swallows unknown fields inside a known block,
so `ok:true` does NOT prove that a field works** — only a real client render does. MTProto /
Telethon does NOT render rich, so a user session can only confirm `edited=True`, never content.

Full verified schema + recipes: `reference/rich-messages.md`.

## Inline mode + Mini App (WebApp)
Two adjacent product surfaces. Both use `bot.Raw` because the wrappers strip
`link_preview_options` and Mini-App details.

**Inline with a big photo above the text** — a `type: article` result whose
`input_message_content.link_preview_options = {url, prefer_large_media: true,
show_above_text: true}` points at a **per-item OG-tagged HTML page** you host. Telegram
server-side-crawls the URL and puts the parsed `og:image` above the message. Raw `.jpg` in
that field does NOT trigger a big preview — Telegram needs an HTML page with `og:image` meta.
Inline can't carry a photo carousel, so the button is `Подробнее` with deep-link
`t.me/bot?start=<id>` that fires the full `slideshow` card from within the bot.

**Mini App (WebApp) via a loader you host** — external checkout/booking pages that set
`SameSite=Lax` cookies break inside Telegram's webview because webview partitions cookies per
top-level origin. Solution: your button opens a small HTML **loader page on your own domain**
(brief branded splash + `preconnect`), which does a **top-level** `window.location.replace(realURL)`.
Now cookies are first-party for the vendor and the page works first-try. The loader host must
send `Content-Security-Policy: frame-ancestors https://*.telegram.org` so Telegram can Mini-App
frame it. Configure via `BOOKING_WEBAPP_URL` in `.env` so you can move the loader without
redeploying the bot.

Full patterns + Telethon verification of OG previews: `reference/inline-and-webapp.md`.

## Cloning a competitor bot's UI (Telethon recon)
Drive another bot from a **user session** (Telethon), click through every screen, capture text +
buttons + styles + custom-emoji ids → that's your 1-to-1 spec. See `reference/recon.md` for the
full driver pattern. Core moves:
- Resolve by username or id from `iter_dialogs()`; `/start`; `await msg.click(data=b"callback")`.
- Read `msg.reply_markup.rows[].buttons[]`: `.text`, `.data` (already bytes), and the style flags
  `b.style.bg_success / bg_primary / bg_danger` + `b.style.icon` (custom-emoji id on the button).
- **One process per session file** (SQLite lock / AUTH_KEY_DUPLICATED otherwise).
- **`DataInvalidError: Encrypted data invalid`** = you clicked a *stale* message; callback data is
  bound to the message it rendered on. Always click the freshest message; you cannot fire an
  arbitrary callback on a different message.
- **Pagination**: match only the *forward* button (`nav:page:CAT:N` where `N==cur+1`); a naive
  "any page button" grabs the ⬅️ back-arrow and ping-pongs forever.
- **Flood-wait**: `TelegramClient(..., flood_sleep_threshold=90)` + catch `FloodWaitError` and sleep.
  Space clicks ~2s. A big crawl belongs in a detached background run, not a foreground SSH call.
- **SSH heredocs mangle escaping** — write the driver to a file and `scp` it, then run `./venv/bin/python x.py`.

## Telegram Stars (XTR) — native in-app payments
The one gateway without a third-party webhook: Telegram carries the whole flow. Since 2024
Telegram's policy requires Stars for **digital** goods/services (subscriptions, media access,
in-bot features); third-party PSPs are for physical goods delivered outside Telegram.

Shape: `sendInvoice(currency="XTR", prices=[...], payload=<idempotency key>)` — **omit
`provider_token` entirely** for Stars, providing one makes Telegram reject the invoice as a
legacy fiat one. Bot receives `pre_checkout_query` (must answer within **10 s** — do only
validation, no slow work) then `successful_payment` inside a Message update. Idempotency key
for fulfillment is **`telegram_payment_charge_id`** on a UNIQUE column; Telegram retries
`successful_payment` if the update isn't acked. Refunds via `refundStarPayment(user_id,
telegram_payment_charge_id)` within Telegram's window (currently 21 days) — reverse the
fulfillment on your side in the same transaction. See `reference/stars-payments.md`.

## Payments & fulfillment (one model for everything)
Single `invoices` table with a `kind` column; one `create_split_invoice(uid, kind, recipient, units, total)`.
`fulfill_invoice(inv)` sets status=paid once and dispatches by kind → `fulfill_stars/premium/vpn/domain/...`.
- Direct **pay-per-order** (no stored balance) avoids holding customer funds / unused-balance refunds.
- Gateways: Telegram Stars (native), CryptoBot / xRocket / platega / OxaPay. Non-Stars confirm via an
  aiohttp **webhook** (verify HMAC signature) that calls `fulfill_invoice`.
- Surcharge per method: `config.with_surcharge(base, method_code)`.
- Stars/Premium resale via the **split.tg** partner API; VPN via a partner API; domains via Dynadot.

## Payment webhook receiver — the two rules you can't skip
Non-Stars gateways call your HTTP endpoint. Signature verification + idempotency, or the flow
breaks:

1. **Read the RAW body once**, compute HMAC over it, compare with `hmac.compare_digest` /
   `hmac.Equal` (not `==` — timing leak). A framework helper that re-parses/re-serialises the
   body invalidates the signature.
2. **Idempotent UPDATE with `RETURNING`:**
   `UPDATE transactions SET status='paid' WHERE invoice_id=$1 AND status <> 'paid' RETURNING …`.
   If nothing returned → duplicate, ack 200 OK, do nothing else. This is the whole idempotency
   contract in one query — no locks needed.
3. **Return 200 even for duplicates.** Non-2xx makes gateways retry; a duplicate is not a
   failure, you already fulfilled it. Only 401/400 for bad signature or malformed body.
4. **DB commit first, notifications after.** `bot.send_message` inside the DB tx holds row
   locks on Telegram-side latency; a raise on the notify rolls back the payment. Commit,
   then best-effort notify.

Per-gateway details (which header, what's signed, what secret): CryptoBot →
`Crypto-Pay-API-Signature` over raw body, secret = Bot API token; xRocket → `rocket-pay-signature`
over raw body, secret = app-specific from dashboard; OxaPay → `HMAC` over raw body, secret =
merchant API key; YooKassa → **IP allowlist (5 `/24` ranges) + HTTP Basic** with
`shopId:secretKey`; platega → `X-Signature-Sha256` over `body+secret` concat. Nginx in front
with `proxy_pass http://127.0.0.1:8080`; app binds `127.0.0.1` only. See
`reference/webhook-server.md` for aiohttp + Go templates and local testing via cloudflared.

## In-memory FSM for text-input flows
When a callback opens "expects free-form text next" (amounts, usernames, promo codes), you need
FSM — but not Redis. aiogram ships **`MemoryStorage` + `FSMContext`** which is enough for
single-process bots; Go you hand-roll a 15-line `map[int64]State` + `sync.RWMutex`. Rules:

- **`state.clear()` on every exit path** — Back button, errors, successful completion. A stale
  state eats the user's next unrelated message a week later.
- **`state.update_data(...)` merges**, not replaces — write only new fields per step.
- **State-scoped handler registered BEFORE the generic `F.text` handler**, or the generic one
  wins. A fallback text handler should `return` when `await state.get_state() is not None`.
- **FSM timeout middleware** (15 min default): the built-in `MemoryStorage` has no expiry, so
  add a middleware that clears state after inactivity.
- Bot restart wipes state — that's fine, users just retap. Move to `RedisStorage` only when you
  actually scale to multiple worker processes.

See `reference/fsm.md` for full aiogram + Go templates and the mistake table.

## Closed-channel subscription flow
When the product is "pay for access to a private Telegram channel" instead of one-shot items,
the shape widens: balance top-up via a gateway → subscription purchased from balance →
`ApproveChatJoinRequest` (or a single-use `CreateChatInviteLink`) → scheduler cron kicks stale
subscribers on expiry. Non-obvious bits worth internalising:

- **Every step is a row in `transactions` with a `type` enum** (`deposit`, `subscription`,
  `referral_days`, `referral_milestone`, …) — this drives the user's history screen and admin
  audit without a second table.
- **Idempotent webhooks:** `UPDATE transactions SET status='paid' WHERE invoice_id=$1 AND status
  <> 'paid'` and gate the balance-add on `rows_affected > 0`. Duplicate webhook = 200 OK, no-op.
- **Expiry warnings use flags** (`notified_3d`, `notified_1d`, `notified_2h`) so a scheduler
  restart / flood-wait doesn't spam. Never reset a flag on renewal — insert a new subscription
  row; treat prior rows as history.
- **Kick is `banChatMember` + `unbanChatMember`.** Bare ban permanently bars them; ban+unban is
  Telegram's "remove for now" idiom.
- **`OnChatJoinRequest` after a kick:** don't auto-approve — require a fresh purchase, otherwise
  the "Join channel" button rewards a kicked user with free access.
- **Referrals**: 10% of plan days on subscription, milestone bonus every N referrals; 30% of
  top-up amount to the referrer's balance only if their subscription is currently active.
- **Promo codes** in two flavours (`days` = instant grant, `percent` = discount for the next
  purchase). `(user_id, promo_id) UNIQUE` — one code per user. Increment `promo_codes.uses` in
  the same transaction as inserting into `promo_uses`, never separately.
- **Text-input FSM is in-memory** (`{uid: state}` map). Process restart wipes it — that's fine,
  users just retap. Don't persist FSM state unless a step is expensive to redo.

See `reference/subscriptions.md` for the full data model, purchase flow, scheduler pseudocode,
promo validation ladder, referral bonus formulas, and admin-panel screens.

## Media caching (file_id) and the 50 MB upload cap
Bot API caps a single-file upload at **50 MB** and re-uploading the same asset on every send is
wasteful. On first send, capture the `file_id` returned by Telegram, keep it in a `meta(key,
value)` table keyed by `fileid:<local_rel_path>`, always send by `file_id` after. `file_id` is
bot-scoped and stable across chats; if the bot token rotates, clear the cache.

`sendRichMessage` with a `photo` / `slideshow` block also requires a `file_id` for the `media`
field in practice — URL fallback re-fetches every render. Warm up new content packs with a
one-shot upload → capture → delete script before shipping.

See `reference/media-and-deploy.md` for the warm-up recipe plus the deploy hazards below.

## Deploy hazards (both stacks)
- **macOS `tar` bundles AppleDouble `._*` sidecars** next to your media. Uploaders pick them up
  and Telegram rejects them with `IMAGE_PROCESS_FAILED`. Always
  `find … -name '._*' -delete` (or `COPYFILE_DISABLE=1 tar`) before packing.
- **`rsync` without an `.env` exclude overwrites the production `.env`** with your local dev
  file, silently losing server-only secrets. Minimum safe form:
  `rsync -az --delete --exclude '.env' --exclude 'data/' --exclude '.git' …`. Prefer `git pull`
  on the server if the repo is cloned there — never touches `.env`.
- **SSH heredocs mangle escaping** — write the driver to a local file, `scp`, run as a file.
- **Two bot processes fighting for `getUpdates`** (a stray `nohup ./bot &` plus systemd) cause
  intermittent button-style loss and dropped clicks. `ps auxf | grep bot | grep -v systemd`
  before every deploy; only systemd should be alive.
- **`ffmpeg` one-liner to fit 50 MB:** `-c:v libx264 -preset veryfast -crf 28 -vf "scale='min(1280,iw)':-2" -c:a aac -b:a 96k -movflags +faststart`.

## Mass broadcasts to your userbase
Telegram's approximate limits: **~30 msg/s globally** to different users, **~1 msg/s** to the
same chat, **~20 msg/min per group**. Defensive default: 20 msg/s in code, not 30. A production
broadcast is not a `for u in users: send(u)` loop — the failure surface is too wide.

Table `broadcasts(id, audience, text, media, status, sent, blocked, failed, total, started_at)`
and `broadcast_sends(broadcast_id, user_id, status, error) UNIQUE(broadcast_id, user_id)` —
the UNIQUE constraint is what makes resume-safe. Loop pulls in batches of ~25 users, uses
`asyncio.gather` inside the batch for concurrency, sleeps to hit the rate cap, checks
`broadcasts.status` between batches so a UI-cancellation flag stops the run within one batch.

Error classification is the killer: `403 bot was blocked / 400 user is deactivated / 400 chat
not found / peer_id_invalid` → mark `users.is_blocked=true` (never try again); `429
TelegramRetryAfter` → sleep `retry_after`, don't record (retry next cycle);
`TelegramNetworkError` → same. Progress reporter edits one message to the admin every 5 s;
guard against `400 message is not modified` by comparing to `last_text`. See
`reference/broadcast.md`.

## Groups, supergroups, forum topics
Adds three concerns that DM bots skip: privacy mode (bots in groups see only commands/mentions
by default — toggle in @BotFather, then **re-add** the bot to refresh the cache), admin
permissions matrix (`administrator` status alone isn't enough — check
`can_delete_messages`/`can_restrict_members`/`can_manage_topics` per action), and forum topics
(supergroups with threads — every message carries `message_thread_id`).

Track membership with `chat_member` + `my_chat_member` (whitelist explicitly in
`allowed_updates`); handle joins with a captcha-then-restrict pattern for anti-spam. Kick is
`banChatMember` + immediate `unbanChatMember` — bare ban permanently bars. Anonymous admins
have `from_user=None`; use `sender_chat` + `banChatSenderChat`. See `reference/groups-and-topics.md`.

## Moderation and anti-spam (community bots)
Layered defense: (1) join-time captcha with `restrictChatMember` for M minutes + a callback
button + a timeout task that kicks non-clickers, (2) `trust_level` ramp — new members get link/
forward/attachment restrictions for the first 24 h with a cron promotion job, (3) regex content
filters for scam patterns (invite-link floods, zero-width character obfuscation), (4) `/report`
command that forwards to an admin chat with delete/mute/kick/ban buttons, (5) shared `bans`
ledger across chats. See `reference/moderation-and-antispam.md`.

## Deep links, start payloads, and BotFather sync
`t.me/<bot>?start=<payload>` (chat) and `t.me/<bot>/<webapp>?startapp=<payload>` (Mini App) —
**payload is 64 chars max, `[A-Za-z0-9_-]` only**. Longer or non-matching = Telegram silently
drops it. Three encoding strategies: plain identifiers (`r-ABCDE`), base64url'd JSON for
structured data up to ~48 bytes, short-hash + DB lookup for anything bigger.

`setMyCommands` supports 7 scopes (`default`/`all_private_chats`/`all_group_chats`/
`all_chat_administrators`/`chat`/`chat_administrators`/`chat_member`) and per-language variants
via `language_code`. Sync from code on every startup — Telegram is idempotent; a diff-first
check via `getMyCommands` avoids unnecessary calls. Same pattern for `setMyName` /
`setMyDescription` / `setMyShortDescription`. See `reference/deep-links-and-commands.md`.

## Media groups (albums)
`sendMediaGroup` sends 2..10 items delivered as one visually-grouped message that is
technically **N separate messages** with the same `media_group_id`. Caption on the first item
only. **`reply_markup` is not supported** — no inline buttons on albums; send the album, then a
follow-up text message with buttons if needed. Types can mix `photo+video` freely; document
albums must be all-documents; audio albums must be all-audio.

Receiving: incoming album delivered as N separate updates — buffer by `media_group_id`,
debounce ~1 s, then process. Forward/copy: use plural `forwardMessages`/`copyMessages` (Bot
API 7.1+) — singular `forwardMessage` × N breaks the album. See `reference/media-groups.md`.

## Webhook vs long-polling
Long-polling is the default; switch to webhook only when you have a specific reason
(multi-worker load balancing, serverless runtime, webhook-URL multi-tenancy). Two ordering
guarantees differ: long-polling delivers in strict `update_id` order; webhook guarantees
per-chat order but interleaves between chats.

Common footguns: two pollers racing for `getUpdates` (409 Conflict, or duplicate handlers
firing — `ps auxf | grep bot`), `drop_pending_updates=True` silently discarding legit user
messages on restart, forgetting `secret_token` on `setWebhook` (letting anyone inject fake
updates through your endpoint URL), not alerting on `getWebhookInfo.pending_update_count`.
`allowed_updates` acts as a whitelist — Telegram caches your list, adding a new update type
requires re-registering. See `reference/webhook-vs-polling.md`.

## Observability
Baseline metrics that catch most incidents: `tg_updates_total{type}` counter,
`tg_handler_seconds{handler}` histogram, `tg_handler_errors_total{handler,exc_type}`,
`tg_api_seconds{method}`, `tg_api_errors_total{method,error_code}`,
`tg_webhook_pending_updates` gauge polled from `getWebhookInfo`. Plus business counters:
`bot_new_users_total`, `bot_paid_total{gateway,plan}`, `bot_paid_amount_total{gateway,plan}`.

**Never use `user_id` as a metric label** — high-cardinality kills Prometheus. Put user_id in
logs, not metrics. Structured logs (JSON or logfmt) with `update_id`/`user_id`/`chat_id`
labels via a `contextvars`-based middleware make "trace this user's session" a `grep` /
Loki query. Bind `/metrics` on `127.0.0.1` — never expose it publicly. Alert on
`pending_update_count > 100 for 2m`, 429 spikes, business-metric silence during business
hours. See `reference/observability.md`.

## Self-hosted Bot API server — when the 50 MB cap hurts
The public `api.telegram.org` caps upload at 50 MB, download at 20 MB. Run the official
open-source `telegram-bot-api` daemon locally and those become 2 GB / unlimited. Migration
gate: `logOut` on the public server → point client at `http://localhost:8081` (`is_local=True`
in aiogram, `local_mode=True` in python-telegram-bot, `URL:` in telebot). In `--local` mode
`getFile.file_path` returns a filesystem path, not a URL — read files directly from disk.
Cleanup is your responsibility: the server never deletes stored media, disk fills up in a week
without a cron. Point the bot and the local server at the same host or share storage via NFS.
See `reference/local-bot-api.md`.

## Localization (RU/EN/UA) without touching call sites
`import texts as T` and keep `render(T.KEY, **kw)`. Make `texts.py` a dispatcher: a `ContextVar`
`current_lang` + `def __getattr__(name)` that returns from `texts_ru`/`texts_en`/`texts_ua`
(fallback to RU). An aiogram outer-middleware sets
`texts.current_lang.set(db.get_lang(uid) or "ru")` per update. The language screen shown before a
choice is multilingual (buttons in all three languages at once). See `reference/localization.md`.

## Deploy
`scp *.py server:/root/app/` → `ssh server 'systemctl restart <svc>'` → commit+push. Secrets live
ONLY in server `.env` (git-ignored); never commit tokens. Some servers drop SSH — wrap ssh/scp in a
retry loop with `-o ConnectTimeout`. Verify: `journalctl -u <svc> -n 40 --no-pager`.

## Gotchas cheat-sheet
- Toggle visibility with `el.hidden`, never inline display, in any web artifact you build for it.
- `KeyboardButtonRow` is not iterable — use `row.buttons`.
- `b.data` is already bytes — don't `.encode()`.
- A second nohup bot instance fighting systemd for `getUpdates` strips button styles intermittently —
  kill duplicates.
- telegra.ph API: `createPage`/`editPage` with `return_content=false`; handle `FLOOD_WAIT_N` (retry+sleep);
  `editPage` to fixed paths is idempotent (URLs never change → links in-bot stay valid).

## Session for verification / QA
The same Telethon user session is your **QA/verification tool**: point `get_entity` at *your own*
bot to drive its screens after a deploy (confirm styles + custom emoji actually reached Telegram),
`get_me()` for your telegram id / Premium flag, or call an upstream API from the bot's env to reconcile
code ↔ `.env` ↔ upstream. See `reference/session-qa.md`.

## E2E testing in CI with a real Telethon session
The tests that catch actual Bot API bugs (empty callback_data, wrong emoji ID,
`RICH_MESSAGE_EMPTY`, stripped button styles) live at the wire level — not at aiogram/telebot
mocks. Drive a **staging bot** (separate token, separate DB) from a **dedicated QA Telegram
account** via Telethon.

Setup: create the session once (`TelegramClient("qa", API_ID, API_HASH).start()` prompts for
phone/code/2FA and writes `qa.session`), then store base64-encoded in CI secrets. **One process
per `.session` file** — if a userbot service also uses that account, copy the file
(`cp qa.session qa.tests.session`) so both hold distinct auth keys and don't fight for the
SQLite lock.

Fixture shape: `client` (session-scope Telethon), `bot_peer` (`get_entity(BOT_USERNAME)`),
`wait_for_reply(client, peer, after_id, timeout)` that polls `get_messages(limit=1)` until a
newer message arrives. Callback data on Telethon buttons is **already bytes** — pass to
`msg.click(data=b"...")` without `.encode()`. `DataInvalidError: Encrypted data invalid` means
you clicked a stale message — always click the freshest one.

**Rich content assertions:** MTProto does NOT render rich messages — `text=""`, `media=None`,
no `.blocks`. Assert that `edit_date` changed instead. For OG-preview inline results, sleep
~7 s after clicking (Telegram fetches OG async), then check `MessageMediaWebPage.webpage.photo`.

Rate limits — `flood_sleep_threshold=90` on the client, `sleep(1.5)` between clicks, serial
test execution (`--maxfail=1`, no parallelism). See `reference/testing.md` for a full pytest
fixture set, GitHub Actions workflow, and the reset-DB-between-tests pattern that avoids
nuking the wrong database.

## Second stack: Go + telebot.v3

Same tricks, different language. telebot.v3 knows **nothing** newer than Bot API 9.3, so
`style`, `icon_custom_emoji_id` and `rich_message` all go through `b.Raw(...)`.

Two traps that cost a deploy each, both when hand-marshalling the keyboard:

- `json.Marshal(tele.ReplyMarkup)` turns buttons into **switch-inline** — telebot declares
  `switch_inline_query_current_chat` without `omitempty`, so an empty string ships.
- `kb.Data(text, unique)` stores the value in **`Unique`**, not `Data`; the wire format is
  `"\f" + Unique`. Read `b.Data` when building by hand and the payload ships empty —
  the handler never fires and the screen goes silent.

**Rich Messages docs describe the receive schema, not the send schema.** Send-side (`InputRichBlock`)
differs — `section_heading` doesn't exist, it's `heading` + numeric `size`; `block_quotation`
becomes `blockquote` + `blocks`; a bare string in a text array is literal text, not `{"text":"x"}`.
Full verified schema + Go-specific traps: `reference/go-telebot.md` and `reference/rich-messages.md`.

## Reference files

**Emoji & rich content**
- `reference/premium-emoji.md` — `premiumize()`, `GLYPH_TO_ID`, button factory, id-finding.
- `reference/emoji-pack.md` — copy emoji into your own @Stickers pack, get new ids.
- `reference/rich-messages.md` — Bot API 10.1 Rich Messages: verified block schema, silent
  schema-ignore trap, `details` header trick, `slideshow` carousel, media block double-nesting,
  edit-in-place recipe.
- `reference/inline-and-webapp.md` — inline mode with an OG-preview big photo; Mini App loader
  that bypasses Telegram-webview cookie partitioning via top-level redirect; server-side
  `initData` HMAC verification.
- `reference/media-groups.md` — classic albums: 2..10 items, caption-on-first rules, no
  `reply_markup`, buffered receive by `media_group_id`, plural forward/copy/delete methods.

**Payments**
- `reference/stars-payments.md` — Telegram Stars (XTR): `sendInvoice` shape (no
  `provider_token`), `pre_checkout_query` (10 s timeout), `successful_payment` with
  `telegram_payment_charge_id` idempotency, `refundStarPayment`, gift + star-balance APIs.
- `reference/webhook-server.md` — aiohttp + Go net/http templates for gateway webhooks;
  per-gateway signature table (CryptoBot / xRocket / OxaPay / YooKassa / platega), idempotent
  UPDATE with `RETURNING`, DB-commit-before-notify, cloudflared local testing.
- `reference/subscriptions.md` — closed-channel subscription flow: schema, purchase flow,
  webhook idempotency, scheduler for expiry warnings and kick+unban, referral bonuses, promo
  codes, in-memory FSM, admin panel.

**Bot mechanics**
- `reference/fsm.md` — in-memory FSM: aiogram `MemoryStorage` + `FSMContext`, Go
  `map[int64]State` with `sync.RWMutex`, timeout middleware, ordering trap with generic text
  handlers.
- `reference/webhook-vs-polling.md` — long-polling vs webhook trade-off, `allowed_updates`,
  `drop_pending_updates`, `secret_token`, migration between modes, `getWebhookInfo` alerting.
- `reference/deep-links-and-commands.md` — `?start=<payload>` and `?startapp=<payload>`
  parsing, 64-char limit and payload encodings, `setMyCommands` scopes, `setMyName` /
  `setMyDescription` / `setMyShortDescription` sync-from-code pattern.
- `reference/broadcast.md` — mass messaging without breaking: rate limits (~20 msg/s safe),
  chunking, error classification (blocked/deactivated/RetryAfter/network), resume-safe
  `broadcast_sends` UNIQUE, live progress reporter, pause/cancel, groups vs users rates.
- `reference/groups-and-topics.md` — bot in groups/supergroups: privacy mode, admin rights
  matrix, `chat_member` + `my_chat_member`, forum topics (`message_thread_id`,
  `create_forum_topic`), support-desk-as-topics pattern, ban+unban idiom.
- `reference/moderation-and-antispam.md` — layered defense: join captcha with timeout task,
  new-member `trust_level` ramp, regex content filters + zero-width-char handling, `/report`
  → admin chat with action buttons, cross-chat ban ledger.

**Media & ops**
- `reference/media-and-deploy.md` — `file_id` caching pattern, ffmpeg fit-under-50MB
  one-liner, macOS AppleDouble trap, safe `rsync` deploy form, SSH heredoc escape hell,
  session-file locking.
- `reference/local-bot-api.md` — self-hosted Bot API server for >50MB uploads / >20MB
  downloads, migration via `logOut`/`close`, `--local` filesystem mode, storage cleanup.
- `reference/observability.md` — Prometheus metrics (Python + Go middlewares),
  structured JSON/logfmt logs with `update_id`/`user_id`/`chat_id` context via
  `contextvars`, trace-id propagation, dashboard starter panels, alerting rules.

**Testing & recon**
- `reference/recon.md` — full Telethon recon driver + gotchas.
- `reference/session-qa.md` — using the session to verify/QA your own bot and check live data.
- `reference/userbot-forwarder.md` — long-running MTProto mirrors and screeners: events +
  pull-loop delivery, restart flood guards (age ceiling, offset bootstrap), dedup keys,
  read-side flood limits, one process-wide limiter for external APIs, staleness alerting.
- `reference/testing.md` — E2E testing via Telethon user session in CI: session file
  creation, `my.telegram.org` fallbacks, login geography, QR login, pytest fixtures, GitHub
  Actions workflow, DB reset per test.

**Localization & stacks**
- `reference/localization.md` — the language dispatcher + middleware (RU/EN/UA).
- `reference/go-telebot.md` — the Go + telebot.v3 stack: Raw-API pattern, Rich Messages send
  schema vs. docs, keyboard-marshalling traps (`switch_inline_query_current_chat` /
  `Unique` vs `Data`), known-working default premium emoji IDs with a full send/edit example,
  verification via a user session. **Also the UI playbook**: button colour semantics (one
  `success` per screen, `danger` reserved for Back), row layout, premium-emoji composition
  rules, Rich-Messages screen structure, collapsing long text (expandable blockquote vs
  details), and a symptom→cause table of common Bot API mistakes.
