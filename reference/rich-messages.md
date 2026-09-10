# Rich Messages — Bot API 10.1

Empirically verified against the live API. Language-agnostic:
the wire format is JSON, send it via aiogram `bot.session.request` / telebot `b.Raw` / net/http
directly. **The public docs are wrong or incomplete about several block fields** — trust this file
before the changelog.

Methods:
- `sendRichMessage` → new message with `rich_message: {"blocks": [...]}`.
- `sendRichMessageDraft` → streaming (chunked) rich messages, for AI-style progressive output.
- `editMessageText` now accepts `rich_message` → **converts a plain text message into a rich
  message in-place**. `reply_markup` (including coloured buttons via `editMessageReplyMarkup`)
  survives. Text↔rich and rich↔rich edits both work.
- Rich content is also a valid `InputMessageContent` in inline / WebApp results
  (`InputRichMessageContent`).

## Block types (verified `type` values)

| type | required fields | notes |
|---|---|---|
| `heading` | `size` (int, 1 or 2), `text` | `text` is a string OR an array of runs |
| `paragraph` | `text` | string OR array of runs |
| `table` | `cells` | `[[cell, cell, …], …]`; cell = `{"type":"header"\|"cell","text":"…","align"?}` |
| `divider` | — | horizontal rule |
| `list` | items | bulleted list |
| `blockquote` | `blocks` (array of blocks) | flags: `collapsed`, `expandable` |
| `collage` | `blocks` | grid of media |
| `slideshow` | `blocks` | **swipeable carousel** of media |
| `details` | `blocks`, header | collapsible section |
| `photo` | `photo: {"type":"photo","media":"<file_id>"}` | double-nested; also `caption` |
| `video`/`audio` | analogous | same shape as `photo` |

**Unsupported (`type: …` returns error):** `collapsible`, `expandable`, `spoiler`, `carousel`, `gallery`, `plain`.

## Text runs (inside heading/paragraph text arrays)

A plain string in the array is literal text. An object is a formatted run:
- `{"type":"bold","text":"…"}`, `italic`, `underline`, `strikethrough`, `spoiler`, `code`, `url`.
- **Custom emoji inside rich text:** `{"type":"custom_emoji","custom_emoji_id":"<id>","alternative_text":"⬜"}` —
  note the key is `alternative_text`, NOT `text`. This is how multi-tile logo strips or inline
  brand marks live inside a `heading` text array instead of as a separate row.

`{"type":"plain","text":"…"}` is **invalid** — use a bare string.

## Media blocks — the double-nested photo shape

```json
{"type":"photo", "photo": {"type":"photo","media":"<file_id_or_url>","caption":"opt"}}
```

- Outer object's `photo` field is an `InputMedia`-shaped object (yes, `type:"photo"` twice).
- `media` = a Telegram `file_id` (fastest) or a public URL. **For Raw you must have a file_id** —
  see `reference/media-and-deploy.md` for the `file_id` cache.
- Same double-nested shape for `video` and `audio`.

## Slideshow (swipeable carousel)

```json
{"type":"slideshow",
 "blocks": [
   {"type":"photo","photo":{"type":"photo","media":"<file_id_1>"}},
   {"type":"photo","photo":{"type":"photo","media":"<file_id_2>"}}
 ]}
```

- Field is **strictly `blocks`** — `items`/`media`/`photos` all return `RICH_MESSAGE_EMPTY`.
- Works with 1..N photos.
- Coexists in one message with `heading`, `blockquote`, `paragraph`, and coloured `reply_markup`.
- `editMessageText + rich_message` **preserves in-place edits** for `text→slideshow` and
  `slideshow→slideshow` (swapping which item is shown). This is the whole reason to use rich —
  otherwise media forces a fresh message.
- **Sanity gotcha:** in MTProto/Telethon a rich-slideshow message appears as normal text with
  `media=None, text=""`. Photos are NOT in `.media`. Verify by "no fallback in bot logs" +
  `edited=True`, not by dumping the message from a user session. See "Verifying rich" below.

## `details` — the collapsible section

```json
{"type":"details",
 "summary":"How to get there",
 "title":  "How to get there",
 "header": "How to get there",
 "blocks": [
   {"type":"paragraph","text":"Directions…"}
 ]}
```

- **Set `summary` + `title` + `header` to the same string.** A single `title` renders the arrow
  but **no text** — the header appears blank. Which of the three is canonical is unclear (all
  three render the same thing); setting all three is the safe recipe.

## `blockquote` — wraps other blocks

```json
{"type":"blockquote", "collapsed":true, "expandable":true,
 "blocks": [
   {"type":"paragraph","text":"Long quote…"}
 ]}
```

- Field is `blocks`, NOT `text`.
- Flags: `collapsed` (initial state), `expandable` (user can expand).

## Centring text — only via table cells

- `paragraph` with `align:"center"` is **silently ignored** — text stays left-aligned.
- To centre a single line, use a 1×1 table with a cell that has `align:"center"`:

```json
{"type":"table","cells":[[{"type":"header","text":"How can we help?","align":"center"}]]}
```

## The silent-schema-ignore trap

**`ok:true` does NOT prove that a field works.**

The API validates **block `type` strictly** (unknown type → error) but **silently swallows
unknown fields inside a known block**. So the API returned `ok:true` for all of `align:"center"`,
`align:"centered"`, `alignment:"center"`, `title`/`summary`/`header` mixed together, etc. The
only ground truth is the live Telegram client on a real device. **Ask the user to look**; do not
declare a field "working" because the API accepted it.

## Verifying rich

- MTProto/Telethon does NOT render rich — `text` and `media` come back empty. Use it only for
  "the edit happened" (compare `edited_at`), not for content verification.
- If the API rejects a block, the bot's fallback path fires — a plain HTML version replaces the
  rich one. Grep for `rich edit failed` in bot logs; if quiet → Telegram accepted every file_id
  and block type.
- Screenshot verification of a client render belongs to the user. Never claim "the rich message
  is correct" from a Telethon dump alone.

## Minimal recipe: an edit-in-place item card

```
1. Send a plain text placeholder message (any HTML).
2. editMessageText with rich_message = { blocks: [
     heading (size:2, item name),
     slideshow (N photos as file_ids),
     paragraph (description),
   ] }
3. editMessageReplyMarkup with the coloured "Buy / Back" keyboard (Bot API 9.4 style).
4. On "Back" or "Next item": another editMessageText with rich_message → slideshow swap in place.
```

Result: one message, live rich content, no extra sends, coloured buttons — the whole UX in a
single chat cell.
