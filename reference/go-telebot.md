# Go + telebot.v3 — the second stack

Everything the main `SKILL.md` describes for aiogram/Python also has a Go implementation using
**`gopkg.in/telebot.v3`**. Same tricks (premium emoji, coloured buttons, recon via Telethon),
different mechanics: **telebot doesn't know a single Bot API feature newer than 9.3**, so every
modern surface goes through `b.Raw(...)`.

Suggested layout for a Go bot:

```
cmd/bot/main.go
internal/
  config/config.go            — env loader
  bot/
    bot.go                    — telebot instance
    middleware.go              — user upsert; filter non-private chats
    keyboards.go              — every keyboard, one place
    styled_kb.go              — Bot API 9.4 coloured buttons + custom emoji via Raw
    rich.go                   — Rich Messages helpers (send/edit + fallback)
    state.go                  — in-memory FSM
    i18n.go                   — RU/EN/UA translations
    gifs.go                   — random GIF pool + file_id cache
    handlers/                 — start, settings, balance, subscriptions, admin, …
  db/
    db.go                     — pgx pool, migrations
    users.go, subs.go, txns.go, promos.go
    migrations/*.sql
  payments/                   — one client per gateway
  webhook/server.go           — HTTP webhook receiver
  scheduler/scheduler.go      — expiry warnings, kicks
```

Entry point:

```go
func main() {
    cfg  := config.Load()
    pool := db.MustConnect(cfg.DatabaseURL); db.Migrate(pool)
    b    := bot.New(cfg)          // telebot with LongPoller{Timeout: 10 * time.Second}
    bot.RegisterHandlers(b, pool, cfg)
    go scheduler.Start(b, pool)
    go webhook.StartServer(b, pool, cfg.WebhookPort)
    b.Start()                     // blocks
}
```

---

## Raw API on top of telebot — the general recipe

telebot.v3 doesn't support `style`, `icon_custom_emoji_id`, `rich_message`. The workaround is
the same everywhere:

1. Send the plain message/keyboard via telebot (this is your fallback if Raw fails).
2. Immediately call `b.Raw("editMessageReplyMarkup" | "editMessageText", params)` with a JSON
   body that has the modern fields.

```go
params := map[string]string{
    "chat_id":      strconv.FormatInt(chatID, 10),
    "message_id":   strconv.Itoa(msgID),
    "reply_markup": string(markupJSON),
}
if _, err := b.Raw("editMessageReplyMarkup", params); err != nil {
    log.Warn("style edit failed, keeping plain markup", "err", err)
}
```

The Telegram error `message is not modified` is harmless — Telegram returns it when the markup
matches what's already on the message. Log at debug, not warn.

---

## Coloured buttons + premium emoji via Raw

Assemble the button JSON by hand and ship it:

```go
btn := map[string]any{
    "text":                 "Referrals",
    "callback_data":        "referrals",
    "style":                "primary",              // success | primary | danger
    "icon_custom_emoji_id": "5960860100800287659",
}
```

`icon_custom_emoji_id` is the ID pulled from a real message (see `reference/premium-emoji.md`).
**Never invent an ID** — a wrong ID silently breaks the button, no API error.

Requirement (same as the Python stack): the **bot-owner account must have Telegram Premium** for
custom emoji to actually send.

### Known-working IDs from the default free Telegram pack

These come from the built-in Telegram premium emoji pack (available to any Premium user), so
they're safe to reuse across bots without owning a custom pack. Pull your own with the recipes
in `reference/premium-emoji.md` if you need something specific to your product.

| ID | Glyph | Common use |
|---|---|---|
| `5192994616281941813` | ✔ | positive state indicator (member / verified / subscribed) |
| `5193129164722423382` | ❌ | negative state indicator (not member / rejected / expired) |
| `5960860100800287659` | 👥-style | "Referrals" / "People" navigation button |
| `5900041572887567336` | 👋 | welcome / greeting screens |

Keep them in one place (`internal/bot/styled_kb.go` or an `emoji_map.go`) so a swap to your own
pack is a single-file edit:

```go
// internal/bot/emoji_ids.go
const (
    EmojiCheck    = "5192994616281941813"   // ✔
    EmojiCross    = "5193129164722423382"   // ❌
    EmojiPeople   = "5960860100800287659"   // 👥
    EmojiWaveHand = "5900041572887567336"   // 👋
)
```

### Example: coloured + premium-emoji button, end-to-end

Send a plain button first (that's your fallback if Raw fails), then upgrade it via
`editMessageReplyMarkup`:

```go
// 1) send an ordinary message with the plain telebot keyboard as the fallback
kb := &tele.ReplyMarkup{}
btnRefs := kb.Data("Referrals", "referrals")
kb.Inline(kb.Row(btnRefs))
msg, err := b.Send(chat, "Menu", kb)
if err != nil { return err }

// 2) upgrade in-place via Raw with style + icon
row := []map[string]any{{
    "text":                 "Referrals",
    "callback_data":        "referrals",
    "style":                "primary",
    "icon_custom_emoji_id": EmojiPeople,
}}
mk, _ := json.Marshal(map[string]any{"inline_keyboard": [][]map[string]any{row}})

params := map[string]string{
    "chat_id":      strconv.FormatInt(chat.ID, 10),
    "message_id":   strconv.Itoa(msg.ID),
    "reply_markup": string(mk),
}
if _, err := b.Raw("editMessageReplyMarkup", params); err != nil {
    // fallback stays: plain telebot keyboard is already on the message — do not delete it
    log.Warn("styled edit failed, keeping plain markup", "err", err)
}
```

Same pattern for premium emoji **inside message text**: send with HTML parse mode, wrap the
glyph in a `<tg-emoji>` tag *after* `html.escape` on the surrounding text so the tag survives
escaping:

```go
text := html.EscapeString(userInput)
text  = fmt.Sprintf(
    `<tg-emoji emoji-id="%s">👋</tg-emoji> %s`,
    EmojiWaveHand, text,
)
b.Send(chat, text, &tele.SendOptions{ParseMode: tele.ModeHTML})
```

For a member-state indicator that changes per row (e.g. a channel list), pick the ID at build
time based on your state check:

```go
icon := EmojiCross
if inChannel {
    icon = EmojiCheck
}
row := []map[string]any{{
    "text":                 channelName,
    "callback_data":        "channel:" + channelID,
    "style":                "primary",
    "icon_custom_emoji_id": icon,
}}
```

---

## Rich Messages (Bot API 10.1) via Raw

The `SKILL.md` overview and `reference/rich-messages.md` cover the verified schema. Two Go-specific
points:

**The Telegram docs describe `RichBlock` (what you receive). You send `InputRichBlock`, and the
schemas differ:**

| Docs / RichBlock | Actually InputRichBlock |
|---|---|
| `section_heading` | `heading` + numeric `size` 1..3 |
| `block_quotation` + `text` | `blockquote` + `blocks` |
| list item `{text}` | list item `{blocks}` |
| `preformatted` | `pre` |
| a text object `{"text":"x"}` | plain text is a **bare string**, not an object |

**API error responses read unambiguously**, once you know them:

| Response | Meaning |
|---|---|
| `type "X" is unsupported` | block type doesn't exist — check spelling |
| `Can't find field "Y"` | block name is right, required field missing |
| `RICH_MESSAGE_EMPTY` | **block accepted**, but there's no visible content |
| `Unsupported rich text type` | a text run's `type` is wrong |

`RICH_MESSAGE_EMPTY` is a schema-accepted confirmation, not a failure — it just means every
block was recognised but they added up to nothing renderable.

**Editing works.** `editMessageText` takes a `rich_message` parameter — one-message navigation
that swaps in-place is preserved. There is no separate `editRichMessage`.

**Always keep a markdown fallback.** Have `EditRichOrFallback` / `SendRichOrFallback` helpers
that catch the rich error, log the reason, and render a plain-HTML equivalent. Without a
fallback the screen goes silently blank the first time the API changes or a field turns invalid.
Do not deploy a rich screen without a fallback.

Full schema (with every trap): `reference/rich-messages.md`.

---

## Two traps that cost a deploy each

Both hit when you hand-marshal keyboards to satisfy Raw.

### 1. `json.Marshal(tele.ReplyMarkup)` mangles buttons

The marshalled JSON turns each button into a **switch-inline** one — the button gains a "↗"
arrow, and clicking it opens the inline-query input instead of firing the callback.

Root cause: telebot declares

```go
InlineQueryChat string `json:"switch_inline_query_current_chat"`
```

**without `omitempty`**, so the empty string ships. telebot does have a custom `MarshalJSON` for
its markup types, but it's defined on a pointer receiver — a `[][]InlineButton` slice-of-values
never invokes it.

**Fix:** never `json.Marshal` a `tele.ReplyMarkup` directly. Build the markup structure yourself
as `map[string]any` / a purpose-built struct with only the fields you set, then marshal that.
The one-liner:

```go
row := []map[string]any{{"text": "…", "callback_data": "…", "style": "primary"}}
mk  := map[string]any{"inline_keyboard": [][]map[string]any{row}}
b, _ := json.Marshal(mk)
```

### 2. `kb.Data(text, unique, …)` stores the value in `Unique`, not `Data`

```go
kb := &tele.ReplyMarkup{}
b  := kb.Data("← Back", "admin")   // b.Unique == "admin", b.Data == ""
```

On the wire telebot sends `"\f" + Unique` (+ `"|" + Data` if `Data` is non-empty), and on receive
`c.Callback().Data` strips the leading `\f`. So if you build the wire payload by hand and read
`b.Data`, you ship an empty callback — the handler never fires and the screen stays silent.
Read `b.Unique` (or your own struct field) when marshalling by hand.

Helper:

```go
func callbackPayload(b tele.Btn) string {
    if b.Unique == "" { return b.Data }
    if b.Data   == "" { return b.Unique }
    return b.Unique + "|" + b.Data
}
```

---

## Migrations list is not auto-discovered

The common pattern is a hardcoded slice of migration paths in `internal/db/db.go`:

```go
var migrations = []string{
    "001_init.sql",
    "002_promos_and_tgid.sql",
    "003_notified_2h.sql",
}
```

Dropping a new file into `migrations/` **is not enough** — append it to that slice explicitly.
Silent skip otherwise: the schema is missing on prod and half your handlers 500. Alternative is
an `embed.FS` walk, but the hardcoded list makes the applied order painfully obvious in a diff.

---

## Verifying live via a user session

The bot's own logs don't show what Telegram actually rendered. A user session (Telethon) shows
what a real client received and lets you click buttons on behalf of a test user. Copy the
session file first — the running process holds a SQLite lock on it (`database is locked`).

```python
# what button types actually shipped
async for m in c.iter_messages(bot_username, limit=5):
    for row in m.reply_markup.rows:
        for b in row.buttons:
            print(b.text, type(b).__name__)   # want KeyboardButtonCallback

# click a button as the user
from telethon import functions
await c(functions.messages.GetBotCallbackAnswerRequest(
    peer=bot, msg_id=m.id, data=b'\fadmin'))
```

This is exactly how trap #2 above was caught — the recon dump showed the callback shipping as
`b'noop'` instead of `b'\fadmin'`.

### Quick schema probe via curl

When it's unclear which field the API wants for a rich block, probe with the real bot token —
the error message names the missing field precisely:

```bash
TOKEN=$(grep -E '^BOT_TOKEN=' .env | cut -d= -f2-)
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendRichMessage" \
  -H 'Content-Type: application/json' \
  -d '{"chat_id":<your_id>,"rich_message":{"blocks":[
        {"type":"heading","size":1,"text":["probe"]}]}}' | python3 -m json.tool
```

---

## Retrying a rate-limited call

telebot surfaces the wait through `tele.FloodError`. Sleep the value it carries and repeat the
same call; retry **only** on flood and 5xx — `400`/`403` are permanent and retrying them burns
the global send budget.

```go
for attempt := 0; attempt < 3; attempt++ {
    _, err := b.Send(recipient, text)
    if err == nil {
        return nil
    }
    var flood *tele.FloodError
    if errors.As(err, &flood) {
        time.Sleep(time.Duration(flood.RetryAfter+1) * time.Second)
        continue        // +1s of slack: sleeping the exact value often re-trips
    }
    return err          // blocked, chat not found, bad request — don't retry
}
```

For the concrete per-chat and global ceilings, and for sending to many users at once, see
`reference/broadcast.md`.

## Throttling edits

Editing one message repeatedly hits the per-chat ceiling before any global limit. Two rules:

- Coalesce updates and edit at most about once per second per message. A progress indicator
  that redraws on every event will be throttled.
- `editMessageReplyMarkup` with unchanged markup returns `400: message is not modified`. It is
  harmless, but the request was still spent — compare against the current markup and skip the
  call instead of catching the error.

## Deploy

```bash
rsync -az \
  --exclude '.env' --exclude '.git' --exclude 'bin/' --exclude 'backups/' \
  ./ user@server:/root/app/
ssh user@server '/usr/local/go/bin/go build -o /root/app/bin/bot ./cmd/bot \
  && systemctl restart app'
```

- Go on the server usually lives at `/usr/local/go/bin/go` and is **not on PATH** — use the
  absolute path in deploy scripts.
- Exclude `.env` — see `reference/media-and-deploy.md` for the full rsync hazard.
- Verify: `journalctl -u app -n 20 --no-pager`.

---

# UI patterns for coloured-button screens

## Button colour semantics — pick one and hold it

A convention that keeps colour meaningful across a bot:

| Style | Meaning | Where |
|---|---|---|
| `success` (green) | the **one** primary action per screen | "Purchase", "Top up", "Continue" |
| `primary` (blue) | ordinary navigation | balance, history, promo, settings, links |
| `danger` (red) | leaving the screen | "← Back" |

Non-obvious rule: **one `success` per screen.** Two greens and the eye has nothing to prioritise.

`danger` on "Back" is unusual (red usually reads as delete), but keeping it consistent across
every screen teaches the user in one session and Back becomes findable at a glance.

## Layout — one button per row by default

Put two buttons in a row only when:

- They're semantically paired and their labels are short (e.g. `➕ Balance` / `📅 Days`).
- You're listing homogeneous items and density matters (a channel list).

Always full-width for:

- The primary action (`success`).
- `← Back`.
- An item you want to visually distinguish from a group of equals (e.g. the main channel above a
  paired list of secondary ones).

Telegram splits row width evenly between buttons — a long label in a pair gets truncated with an
ellipsis. Preview on a narrow screen, not just desktop.

## Premium emoji — two different mechanisms

**1. Inside text** (HTML parse mode only):

```html
<tg-emoji emoji-id="5900041572887567336">👋</tg-emoji>
```

The bare glyph inside is the fallback for anyone without Premium — they see the plain emoji.

Order of operations: `html.escape(text)` **first**, then insert `<tg-emoji>` wrappers.
Reversed order and the user sees literal `&lt;tg-emoji&gt;`.

**2. On buttons** — a separate field, not text:

```go
btn["icon_custom_emoji_id"] = "5192994616281941813"
```

The icon draws to the left of the label. Don't also put the emoji in the label — it duplicates.

**Never invent an ID.** Wrong ID silently breaks the button, no API error surfaces. Pull real
IDs via a user session (`reference/premium-emoji.md`).

## Regular emoji — composition rules

- **Emoji at the start of a label, one space then text.** Trailing emoji looks random.
- **One emoji per label.** Two turns the button into a rebus.
- **One meaning → one emoji across the whole bot.** 💰 always money, 👥 always people. Mixing
  weakens the affordance.
- **Arrows are symbols, not emoji:** `←`, `◀️`/`▶️` for pagination. They render the same
  everywhere; emoji-font arrows don't.
- **Status → colour or button icon, not text emoji.** For "member of channel / not member" use
  `icon_custom_emoji_id` (✔/❌) together with `style`, not a glyph inside the label.

## Rich Messages screen layout

An order that reads well across a stats or activity screen:

```
H1 title              ← one, may include one emoji
one-line summary       ← the single most important number
H2 section + table    ← details, repeatable 2-3 times
Details "more"        ← things needed rarely
Divider + total       ← if there's a final figure
Footer                ← legend, small
```

Rules:

- **Numbers in tables — `text_align: right`.** Left-aligned numbers can't be scanned as a column.
- **First table row = header** and needs `bold` — Telegram doesn't infer it.
- **Long-tail content → `details`.** Inactive rows, bulk-operation preconditions, changelog —
  keep them collapsed. The screen doesn't grow with data but the data is one tap away.
- **`is_compact: true`** for 2–4-row summary tables, otherwise they spread out.
- **Footer for legends** (`🆕 = X · 💰 = Y · 💳 = Z`) — pulling the legend into the body eats
  attention.

## Common errors

### Bot API

| Symptom | Cause |
|---|---|
| Button gets a "↗" arrow, opens inline input | `switch_inline_query*` shipped as empty string in JSON |
| Button click does nothing | Empty `callback_data` (read `b.Data`, should have been `Unique`) |
| `RICH_MESSAGE_EMPTY` | Only a `divider` block, or a block with no visible content |
| `Field "size" must be a valid Number` | `size` shipped as `"1"` (string), needs `1` (int) |
| Emoji doesn't animate | Owner has no Premium, or the ID is wrong |
| Message shows `&lt;tg-emoji&gt;` literally | Escape happened after the tag insert, not before |
| `message is not modified` | Markup matches current — harmless, log at debug |
| Button styles disappear intermittently | Two bot processes racing on `getUpdates` — kill the duplicate |

### Screen logic

- **Losing `reply_markup` on edit.** `editMessageText` without `reply_markup` keeps the
  keyboard from the previous screen — users see buttons that don't belong. Pass markup every time.
- **Callback without `c.Respond()`.** The button stays in a spinning "loading" state.
  `_ = c.Respond()` is the first line of every callback handler.
- **Pagination without a `noop` handler.** The centre "3 / 12" indicator is also a button and
  needs a callback — Telegram rejects the markup if any button has an empty callback. Register a
  no-op handler for it.
- **Screen without a Back button.** Dead end — users close the bot instead of navigating up.

### Verification

- **Don't trust that "the deploy shipped".** A fallback silently replaces `rich` with plain
  markdown — the screen visually "works" but isn't what you meant. Grep bot logs for `rich edit
  failed`; verify with a user session.
- **Verify screens by clicking, not by looking.** A visually-correct button might not fire (this
  is exactly how the empty-callback trap was caught).

## Long text — collapse, don't cut

A screen you have to scroll, users don't read. But you can't drop the data — someone will ask
for it. Show the essentials, hide the rest under a fold.

**Three tools, different jobs:**

| Tool | Where | When |
|---|---|---|
| `<blockquote expandable>` | HTML parse mode | Long continuous text: description, terms, log |
| `blockquote` + `expandable` | Rich Messages | Same, but inside blockful layout |
| `details` | Rich Messages | You have a **heading** that describes what's inside |

### HTML

```html
<blockquote expandable>First lines visible, rest under "Show more".</blockquote>
```

Build the tag **after** `html.escape`, otherwise it's escaped into literal text.

### Rich Messages

```json
{"type":"blockquote","expandable":true,"blocks":[
  {"type":"paragraph","text":"long text"}]}

{"type":"details","summary":"What the columns mean","title":"What the columns mean","header":"What the columns mean","blocks":[
  {"type":"list","items":[{"blocks":[{"type":"paragraph","text":"…"}]}]}]}
```

Semantic difference: `blockquote` shows the start of the text and users decide by seeing the
first line whether to expand. `details` shows only the heading; content is fully hidden, so the
heading must explain what's inside.

Bad: `details` titled "More" — no reason to tap.
Good: "Who is affected", "What the columns mean", "❌ Inactive (12)" — a number helps.

### Rules

- **Collapsed ≠ hidden from yourself.** If a number is required to make a decision right now
  (e.g. how many rows a bulk operation will affect), it stays visible on the screen. Only
  detailed lines go into `details`.
- **Don't nest collapsible blocks.** Users lose track of which fold they opened.
- **Rule of thumb: one screen-height.** Shorter → don't collapse, you just add a click.
- **Lists inside `details` beat paragraphs.** Three bullets read better than the same items in a
  comma-separated sentence.
