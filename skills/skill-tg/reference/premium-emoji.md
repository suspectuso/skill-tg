# Premium (custom) emoji + colored buttons + the escaping rule

## ⚠️ The #1 formatting trap (read first)
Bot uses `parse_mode=HTML`. If you run `html.escape()` over a string that contains your own
`<b>`/`<code>`/`<blockquote>` formatting, those tags become `&lt;b&gt;` and Telegram renders
them as **literal `<b>` text, not bold**. Do **NOT** escape the whole message.

**The rule:** your *templates are trusted HTML* (keep their `<b>`, `<code>`, `<tg-emoji>` tags).
Escape **only the dynamic values you interpolate** (usernames, titles, user input). Premium-emoji
wrapping runs on the already-safe HTML and does **not** escape.

```python
# emoji_map.py
GLYPH_TO_ID = {                       # real document_ids only (pull via recon.md); NEVER invent
    "🤖": 6030400221232501136,
    "⭐": 5848259999763011021,
    # ...
}

def premiumize(text: str, enabled: bool) -> str:
    """Wrap known glyphs in <tg-emoji>. Input is already-safe HTML — do NOT html.escape here."""
    if not enabled:                   # PREMIUM_EMOJI=off → plain unicode, unchanged
        return text
    for glyph, eid in GLYPH_TO_ID.items():
        text = text.replace(glyph, f'<tg-emoji emoji-id="{eid}">{glyph}</tg-emoji>')
    return text
```

```python
# bot.py — the render pipeline that keeps formatting AND stays injection-safe
import html
def render(template: str, **values) -> str:
    safe = {k: html.escape(str(v)) for k, v in values.items()}   # escape ONLY interpolated values
    return premiumize(template.format(**safe), config.PREMIUM_EMOJI)   # template keeps its own tags
```

```python
# texts.py — templates ARE trusted HTML: bold, code, blockquote all render
HOME = "🛒 <b>Shop</b>\n\nPick a product, set quantity, pay with ⭐ right in chat."
PRODUCT = "{emoji} <b>{title}</b>\n\n{desc}\n\nPrice: <b>{price}</b> ⭐"   # {title}/{desc} get escaped
```
`render(T.PRODUCT, emoji="☕", title=user_title, price=100)` → `<b>` renders bold, `user_title`
is escaped (safe), `⭐` becomes a premium emoji when enabled. No literal tags, no injection.

## keyboards.py — button factory (color + icon)
```python
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
def cb(text, data, style=None, icon=None):
    kw = {"text": text, "callback_data": data}
    if style: kw["style"] = style            # "primary" | "success" | "danger"
    if icon:  kw["icon_custom_emoji_id"] = str(icon)
    return InlineKeyboardButton(**kw)
def url(text, link, style=None, icon=None):
    kw = {"text": text, "url": link}
    if style: kw["style"] = style
    if icon:  kw["icon_custom_emoji_id"] = str(icon)
    return InlineKeyboardButton(**kw)
def _kb(rows): return InlineKeyboardMarkup(inline_keyboard=rows)
```
Keep button icons as `IC_* = <document_id>` constants with the glyph in a comment.

## Rules
- Custom emoji (`<tg-emoji>` in text, `icon_custom_emoji_id` on buttons) send **only if the
  bot-owner account has Telegram Premium**. No Premium → the message with `<tg-emoji>` is
  rejected, and a button `icon_custom_emoji_id` is silently accepted by aiogram but the icon
  just won't render (the `style` color still shows). Keep `PREMIUM_EMOJI=off` until the owner
  has Premium and you have real ids — then unicode is shown, nothing breaks.
- `style` and `icon` are independent Bot API 9.4 fields; either alone is valid, they combine.
- New glyph → pull its real `document_id` first (from a message's `MessageEntityCustomEmoji`
  or `SearchCustomEmojiRequest`). A wrong id silently breaks the emoji. Never invent one.
- Own an emoji pack so you don't leak the source pack's name — see `emoji-pack.md`.
</content>
