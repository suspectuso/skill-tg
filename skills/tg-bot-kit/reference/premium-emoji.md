# Premium (custom) emoji + colored buttons

## emoji_map.py
```python
import html

# реальные document_id кастом-эмодзи (достаются из сессии, см. recon.md). Не выдумывать.
GLYPH_TO_ID = {
    "🤖": 6030400221232501136,
    "⭐": 5848259999763011021,
    "💳": 5778421276024509124,
    "🎁": 5773677501825945508,
    # ... своя карта
}

def premiumize(text: str, enabled: bool, sparkle_id: int | None = None) -> str:
    """html.escape, затем обернуть известные глифы в <tg-emoji>. enabled=False → обычный юникод."""
    out = html.escape(text)
    if not enabled:
        return out
    for glyph, eid in GLYPH_TO_ID.items():
        if glyph in out:
            out = out.replace(glyph, f'<tg-emoji emoji-id="{eid}">{glyph}</tg-emoji>')
    return out
```
`render(template, **kw)` в bot.py = `premiumize(template.format(**kw), config.PREMIUM_EMOJI, sparkle_id)`.

## keyboards.py — фабрика кнопок (цвет + иконка)
```python
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup

def cb(text, data, style=None, icon=None):
    kw = {"text": text, "callback_data": data}
    if style: kw["style"] = style            # "success" | "primary" | "danger"
    if icon:  kw["icon_custom_emoji_id"] = str(icon)
    return InlineKeyboardButton(**kw)

def url(text, link, style=None, icon=None):
    kw = {"text": text, "url": link}
    if style: kw["style"] = style
    if icon:  kw["icon_custom_emoji_id"] = str(icon)
    return InlineKeyboardButton(**kw)

def _kb(rows): return InlineKeyboardMarkup(inline_keyboard=rows)
```
Держи иконки кнопок как константы `IC_* = <document_id>` рядом с их глифом в комментарии.

## Правила
- Бот шлёт кастом-эмодзи только если у **аккаунта-владельца бота есть Telegram Premium**.
- `parse_mode=HTML`. `<tg-emoji>` добавляется ПОСЛЕ `html.escape`, иначе теги экранируются.
- Новый глиф → сперва достать реальный `document_id` (из сообщения или `SearchCustomEmojiRequest`),
  только потом вписывать. Выдуманный id молча ломает эмодзи/кнопку.
- `style` без иконки и иконка без `style` — обе валидны и комбинируются.
</content>
