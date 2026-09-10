---
name: tg-bot-kit
description: >
  Building production Telegram bots the way this codebase does it — aiogram 3, premium
  (custom animated) emoji via Bot API 9.4, colored inline buttons, rich HTML text
  (expandable quotes, code), a unified invoice + payment-webhook model, RU/EN localization,
  and cloning a competitor bot's UI 1-to-1 through a Telethon user session. Invoke when building, extending, or debugging a
  Telegram shop/service bot, when a task mentions custom/premium emoji or colored buttons, or when you need to recon another bot's screens.
---

# tg-bot-kit — Telegram bot building kit

Distilled from building a multi-product Telegram shop (aiogram 3, SQLite, systemd). The sanitized
reference implementation is open-sourced as **tg-shop-kit**; concrete patterns are in `reference/`.

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

## Payments & fulfillment (one model for everything)
Single `invoices` table with a `kind` column; one `create_split_invoice(uid, kind, recipient, units, total)`.
`fulfill_invoice(inv)` sets status=paid once and dispatches by kind → `fulfill_stars/premium/vpn/domain/...`.
- Direct **pay-per-order** (no stored balance) avoids holding customer funds / unused-balance refunds.
- Gateways: Telegram Stars (native), CryptoBot / xRocket / platega / OxaPay. Non-Stars confirm via an
  aiohttp **webhook** (verify HMAC signature) that calls `fulfill_invoice`.
- Surcharge per method: `config.with_surcharge(base, method_code)`.
- Stars/Premium resale via the **split.tg** partner API; VPN via a partner API; domains via Dynadot.

## Localization (RU/EN) without touching call sites
`import texts as T` and keep `render(T.KEY, **kw)`. Make `texts.py` a dispatcher: a `ContextVar`
`current_lang` + `def __getattr__(name)` that returns from `texts_ru`/`texts_en` (fallback to RU).
An aiogram outer-middleware sets `texts.current_lang.set(db.get_lang(uid) or "ru")` per update.
The language screen shown before a choice is bilingual. See `reference/localization.md`.

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


## Reference files
- `reference/recon.md` — full Telethon recon driver + gotchas.
- `reference/session-qa.md` — using the session to verify/QA your own bot and check live data.
- `reference/premium-emoji.md` — `premiumize()`, `GLYPH_TO_ID`, button factory, id-finding.
- `reference/emoji-pack.md` — copy emoji into your own @Stickers pack, get new ids.
- `reference/localization.md` — the language dispatcher + middleware.
