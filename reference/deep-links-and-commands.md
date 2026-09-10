# Deep-links, start payloads, and BotFather command sync

Two adjacent boundaries that every bot has: how users enter (`/start` with parameters, deep
links) and how the bot advertises what it does (`/setcommands`, description, name, short
description in @BotFather).

## Deep-link anatomy

Two forms Telegram supports on both mobile and desktop clients:

```
https://t.me/<bot_username>?start=<payload>          → opens chat, fires /start <payload>
https://t.me/<bot_username>/<webapp_short_name>?startapp=<payload>
                                                     → opens Mini App with startapp param
```

- **`payload` is at most 64 characters** and restricted to `[A-Za-z0-9_-]`. Longer or
  non-matching = Telegram silently drops the param and the user gets a bare `/start`.
- The `<bot_username>` is case-insensitive on Telegram's side but keep it as the user knows it
  in your own copy.
- Alternate scheme `tg://resolve?domain=<bot>&start=<payload>` works identically and skips the
  browser hop on installed clients.

## Building payloads that fit 64 chars

Common encodings, from simplest to densest:

**Plain identifiers:**
```
r-ABCDE                     -- referral code
p-<product_id>              -- product page
sub-1m                      -- subscription plan
```
Human-readable, self-documenting, easy to grep in logs. Prefer this.

**base64url for structured data:**
```python
import base64, json
raw     = {"kind": "ref", "user": 12345, "utm": "yt"}
payload = base64.urlsafe_b64encode(
    json.dumps(raw, separators=(",", ":")).encode()
).rstrip(b"=").decode()
# max input len that fits after b64: ~48 bytes JSON → 64 chars payload
```

**Short-hash + DB lookup for anything bigger:**
```python
import secrets
short = secrets.token_urlsafe(9)                      # 12 chars, plenty of entropy
db.deep_links.insert(short=short, data=full_payload, expires_at=now()+1d)
url   = f"https://t.me/{bot}?start=l-{short}"
```

Never rely on "the payload will grow slightly later" — 64 is a hard cap. If it might, use the
short-hash pattern from the start.

## Parsing on `/start`

```python
# aiogram
from aiogram import F
from aiogram.filters import CommandStart, CommandObject
from aiogram.types import Message


@dp.message(CommandStart(deep_link=True))
async def start_with_payload(m: Message, command: CommandObject):
    payload = command.args or ""                       # "" if the user typed /start alone
    if payload.startswith("r-"):
        await register_referral(m.from_user.id, code=payload[2:])
    elif payload.startswith("p-"):
        await open_product(m, product_id=payload[2:])
    elif payload.startswith("l-"):
        data = await db.deep_links.fetch(short=payload[2:])
        if data: await dispatch(m, data)
        else:    await m.answer("This link has expired.")
    else:
        await m.answer("Unknown link.")
    await show_main_menu(m)                            # always land the user somewhere

@dp.message(CommandStart())
async def start_bare(m: Message):
    await show_main_menu(m)
```

Go / telebot:
```go
b.Handle("/start", func(c tele.Context) error {
    payload := c.Message().Payload            // everything after "/start "
    if payload == "" { return sendMainMenu(c) }
    switch {
    case strings.HasPrefix(payload, "r-"):
        _ = registerReferral(c.Sender().ID, payload[2:])
    case strings.HasPrefix(payload, "p-"):
        _ = openProduct(c, payload[2:])
    // …
    }
    return sendMainMenu(c)
})
```

**Rule: always land the user in the main menu after handling.** If the deep link's action
succeeded, tell them so *and* show the menu — otherwise they're staring at a bot that seems
to have done nothing.

## Mini App deep links (`startapp`)

`?startapp=<payload>` opens the bot's registered Mini App directly, skipping the chat. The
payload arrives in the Mini App as `Telegram.WebApp.initDataUnsafe.start_param`.

**The same 64-char limit applies.** Same encoding strategies as above.

Registering the Mini App: in @BotFather, `/mybots → <bot> → Bot Settings → Configure Mini App
→ Add`, then a `short_name` (used in the URL). Set the URL to your loader host; see
`reference/inline-and-webapp.md`.

## Generating links from the bot for sharing

Two flavours:

```python
def share_link(bot_username: str, product_id: str) -> str:
    return f"https://t.me/{bot_username}?start=p-{product_id}"

def share_webapp(bot_username: str, app_short: str, param: str) -> str:
    return f"https://t.me/{bot_username}/{app_short}?startapp={param}"
```

For the "share this to a friend" flow, use `switch_inline_query` on an inline button — it opens
the client's share sheet with the message text pre-filled:

```python
InlineKeyboardButton(text="Share with a friend",
                     switch_inline_query=f"come use this bot — https://t.me/{BOT}?start=r-{code}")
```

## BotFather sync — commands, name, description

Every bot has four pieces of prose+commands that @BotFather owns. Duplicating them in code and
keeping them synced beats manual /setcommands after each release.

| API method | What it sets |
|---|---|
| `setMyCommands` | The `/` menu shown when the user taps the Menu button in a chat |
| `setMyName` | The bot's display name (also the tab title) |
| `setMyDescription` | Full description on the bot's profile page (before "Start") |
| `setMyShortDescription` | The one-liner shown in @BotFather share cards and search |

Each supports `language_code` for per-language variants (falls back to no-lang if not set).
`setMyCommands` additionally supports `scope`:

- `default` — everyone.
- `all_private_chats` — DMs only.
- `all_group_chats` — group chats.
- `all_chat_administrators` — admins in every chat the bot is in.
- `chat` (with `chat_id`) — one specific chat.
- `chat_administrators` — admins in one specific chat.
- `chat_member` — one user in one chat (per-user commands).

Common scope pattern: one command list for everyone, an admin-only extension for the admin
group.

### The sync function to run on bot startup

```python
# scripts/sync_botfather.py — run on every deploy
from aiogram import Bot
from aiogram.types import BotCommand, BotCommandScopeAllPrivateChats, \
    BotCommandScopeChat

COMMANDS_RU = [
    BotCommand(command="start",  description="Открыть главное меню"),
    BotCommand(command="menu",   description="Главное меню"),
    BotCommand(command="help",   description="Помощь"),
]
COMMANDS_EN = [
    BotCommand(command="start",  description="Open the main menu"),
    BotCommand(command="menu",   description="Main menu"),
    BotCommand(command="help",   description="Help"),
]
ADMIN_COMMANDS = COMMANDS_RU + [
    BotCommand(command="admin",  description="Админ-панель"),
    BotCommand(command="stats",  description="Статистика"),
    BotCommand(command="broadcast", description="Рассылка"),
]

async def sync(bot: Bot, admin_chat_id: int | None = None):
    await bot.set_my_commands(COMMANDS_RU, scope=BotCommandScopeAllPrivateChats(),
                              language_code="ru")
    await bot.set_my_commands(COMMANDS_EN, scope=BotCommandScopeAllPrivateChats(),
                              language_code="en")
    if admin_chat_id:
        await bot.set_my_commands(ADMIN_COMMANDS,
                                  scope=BotCommandScopeChat(chat_id=admin_chat_id))

    await bot.set_my_name("MyBot",                     language_code="en")
    await bot.set_my_name("Мой бот",                   language_code="ru")

    await bot.set_my_short_description(
        "Description for search and share cards, up to 120 chars.",
        language_code="en",
    )
    await bot.set_my_description(
        "Full description shown on the bot's profile page. Up to 512 chars. Explain what "
        "the bot does, who it's for, and how to start.",
        language_code="en",
    )
```

Call `sync(bot)` from your app startup (aiogram `on_startup`) — Telegram is idempotent, so
running it on every deploy is fine. Rate-limit is generous (~30/min per bot for these
metadata calls), so unless you sync in a tight loop you're safe.

### Diff-first sync (avoid rate limits when nothing changed)

Cheap check before update:

```python
current = await bot.get_my_commands(scope=BotCommandScopeAllPrivateChats(), language_code="ru")
if [(c.command, c.description) for c in current] != \
   [(c.command, c.description) for c in COMMANDS_RU]:
    await bot.set_my_commands(COMMANDS_RU, scope=..., language_code="ru")
```

Same for name and descriptions with `get_my_name`, `get_my_description`, `get_my_short_description`.

## Menu button — the alternative to `/commands`

`setChatMenuButton` replaces the `/`-menu icon with either a text button or a WebApp launcher.

```python
await bot.set_chat_menu_button(
    menu_button=MenuButtonWebApp(text="Open app", web_app=WebAppInfo(url=WEBAPP_URL))
)
```

Global (no `chat_id`) or per-chat. Popular pattern: WebApp button for the whole audience, plus
a set of slash commands for accessibility.

## Command handlers vs. text handlers — ordering

```python
@dp.message(Command("start"))
async def start(m: Message): ...

@dp.message(F.text)             # generic text fallback
async def text_fallback(m: Message): ...
```

aiogram resolves handlers in registration order; a `Command()` filter checks for the leading
`/` before matching. Two mistakes:

1. Registering `F.text` before `Command("start")` — the text handler swallows every message
   *including* `/start` because "starts with `/`" is still text. Register `Command` first.
2. Deep-links in group chats — Telegram delivers `/start@your_bot payload` in groups, not
   `/start payload`. aiogram's `CommandStart` strips the `@<bot>` suffix automatically; a
   hand-rolled `.startswith("/start ")` check does not — use the filter, not the substring.

## Referral links — the piece that ties this to `subscriptions.md`

Deep-links are how referral codes propagate. The pattern:

1. On user registration, generate `users.ref_code = secrets.token_urlsafe(6)`.
2. On the user's referral screen, show `t.me/<bot>?start=r-{ref_code}`.
3. On `/start r-<code>`: find `users` where `ref_code = <code>`, set the new user's
   `referrer_id` **exactly once** (`WHERE referrer_id IS NULL`), never overwrite.
4. Deliver the bonus only after the invitee completes a qualifying action (profile completion,
   first purchase) — see `reference/subscriptions.md`. Don't reward on register-only, or the
   loop is farming.

## Copy-links inside messages (monospace deep-link)

For a deep link the user should copy, not tap:

```html
<code>t.me/mybot?start=r-ABCDE</code>
```

Telegram makes `<code>` blocks tap-to-copy on both mobile and desktop. Wrap the whole URL in
`<code>` so the entire string is copied cleanly.

For a *tap-to-open* deep link, use a regular `<a href>` — Telegram renders both fine, but
copyable vs. openable is a UX choice; make it deliberately.

## Common mistakes

| Symptom | Cause |
|---|---|
| Deep-link works on mobile, opens Telegram web on desktop, silently drops payload | Payload had characters outside `[A-Za-z0-9_-]` — Telegram dropped it. Base64url + rstrip `=` fixes this |
| `/start`-with-payload handler never fires | Registered `F.text` fallback before `Command`; or `@dp.message(F.text.startswith("/start "))` doesn't work in groups (missing `@bot` suffix) |
| BotFather commands stale after deploy | `set_my_commands` not called, or called only once at bot creation. Call on every startup |
| Deep-link goes to Mini App instead of chat | Used `?startapp=` instead of `?start=`. `startapp` opens the registered Mini App; `start` opens the chat |
| Payload gets truncated | Exceeded 64 chars. Switch to short-hash + DB lookup pattern |
| Multiple `set_my_commands` calls with different scopes overwrite each other | They don't — scopes are independent. But `set_my_commands(scope=default)` overrides only the default scope; be explicit which scope you're editing |
| `switch_inline_query` share button opens empty share sheet | The `switch_inline_query` text was `None` / empty. Pass a non-empty string, even if just the bot handle |
| Referral loop / self-referral | Not checking `referrer_id IS NULL` before writing; not checking `referrer_id != user.id` explicitly. See `reference/subscriptions.md` |
| Old Bot API version silently ignores `set_my_short_description` | `setMyShortDescription` is Bot API 6.6+; using an older `python-telegram-bot` / `telebot` build → method missing. Update the lib or use `bot.session.request("setMyShortDescription", …)` |
| Deep-link generates an "unsupported link" popup in Telegram Desktop | Username is wrong or bot doesn't exist. Also: Telegram Desktop occasionally caches "no such bot"; restart Desktop after registering a brand-new bot |
