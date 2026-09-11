# Minimal shop skeleton — `/start` → catalog → product → Stars invoice

## Contents
- `config.py` — token, PREMIUM_EMOJI flag, catalog with Stars prices
- `emoji_map.py` — `premiumize()` (never escapes)
- `keyboards.py` — `cb()` button factory with `style`/`icon`, home/catalog/product keyboards
- `bot.py` — `render()` pipeline, handlers, stepper, Stars invoice, pre_checkout, successful_payment
- `db.py` — SQLite orders table with idempotent `record_order`
- Notes — Stars needs no provider_token, stateless stepper, idempotency, premium-emoji default

The smallest end-to-end wiring, so you scaffold in one read instead of composing 3 references.
aiogram 3. Deeper pieces link out: buttons/emoji → `premium-emoji.md`, Stars → `stars-payments.md`,
custom-quantity text step → `fsm.md`.

```python
# config.py
import os
BOT_TOKEN = os.environ["BOT_TOKEN"]
PREMIUM_EMOJI = os.getenv("PREMIUM_EMOJI", "off") == "on"   # off → plain unicode fallback
CATALOG = {                                                 # price in Stars (XTR), integer
    "coffee":  {"title": "☕ Coffee",  "price": 100},
    "sticker": {"title": "✨ Sticker", "price": 50},
}
```

```python
# emoji_map.py  — see premium-emoji.md for the full pattern
GLYPH_TO_ID = {}                     # {"⭐": 5848259999763011021, ...} real ids only; empty = none yet
def premiumize(text, enabled):       # input is already-safe HTML — do NOT html.escape here
    if not enabled: return text
    for g, i in GLYPH_TO_ID.items():
        text = text.replace(g, f'<tg-emoji emoji-id="{i}">{g}</tg-emoji>')
    return text
```

```python
# keyboards.py  — see premium-emoji.md for cb()/url() + style + icon
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
def cb(text, data, style=None, icon=None):
    kw = {"text": text, "callback_data": data}
    if style: kw["style"] = style                 # primary | success | danger
    if icon:  kw["icon_custom_emoji_id"] = str(icon)
    return InlineKeyboardButton(**kw)
def kb(rows): return InlineKeyboardMarkup(inline_keyboard=rows)

def home():    return kb([[cb("🛍 Каталог", "catalog", "success")]])
def catalog(): return kb([[cb(p["title"], f"p:{k}", "primary")] for k, p in __import__("config").CATALOG.items()]
                         + [[cb("⬅️", "home")]])
def product(key, qty):
    return kb([
        [cb("−", f"q:{key}:{qty-1}"), cb(f"{qty} шт.", "noop"), cb("+", f"q:{key}:{qty+1}")],
        [cb("Купить ⭐", f"buy:{key}:{qty}", "success")],
        [cb("⬅️", "catalog")],
    ])
```

```python
# bot.py
import asyncio
from aiogram import Bot, Dispatcher, F
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.filters import CommandStart
from aiogram.types import (CallbackQuery, Message, LabeledPrice,
                           PreCheckoutQuery)
import html
import config, keyboards as k, db
from emoji_map import premiumize

bot = Bot(config.BOT_TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
dp = Dispatcher()
def render(tmpl, **v):                     # template = trusted HTML; escape only interpolated values
    return premiumize(tmpl.format(**{k: html.escape(str(x)) for k, x in v.items()}), config.PREMIUM_EMOJI)

@dp.message(CommandStart())
async def start(m: Message):
    await m.answer(render("🛒 <b>Магазин</b>\n\nВыберите раздел."), reply_markup=k.home())

@dp.callback_query(F.data == "home")
async def home(c): await c.message.edit_text(render("🛒 <b>Магазин</b>\n\nВыберите раздел."), reply_markup=k.home()); await c.answer()

@dp.callback_query(F.data == "catalog")
async def catalog(c): await c.message.edit_text(render("🛍 <b>Каталог</b>"), reply_markup=k.catalog()); await c.answer()

@dp.callback_query(F.data.startswith("p:"))
async def open_product(c):
    key = c.data.split(":")[1]; p = config.CATALOG[key]
    await c.message.edit_text(render("🛍 <b>{title}</b>\n\nЦена: <b>{price}</b> ⭐", title=p['title'], price=p['price']),
                              reply_markup=k.product(key, 1)); await c.answer()

@dp.callback_query(F.data.startswith("q:"))
async def qty(c):
    _, key, q = c.data.split(":"); q = max(1, int(q)); p = config.CATALOG[key]
    # edit_text, not edit_reply_markup: the card's body shows qty/total too, and editing only
    # the keyboard leaves the text saying "1 шт." while the button says 3 — a visible desync.
    await c.message.edit_text(render("🛍 <b>{title}</b>\n\nЦена: <b>{price}</b> ⭐\nК оплате: <b>{total}</b> ⭐",
                                     title=p['title'], price=p['price'], total=p['price'] * q),
                              reply_markup=k.product(key, q)); await c.answer()

@dp.callback_query(F.data == "noop")
async def noop(c): await c.answer()

@dp.callback_query(F.data.startswith("buy:"))
async def buy(c: CallbackQuery):
    _, key, q = c.data.split(":"); q = int(q); p = config.CATALOG[key]
    await bot.send_invoice(
        chat_id=c.from_user.id, title=p["title"], description=f"{q} × {p['title']}",
        currency="XTR", prices=[LabeledPrice(label=p["title"], amount=p["price"] * q)],
        payload=f"product:{key}:{q}",           # ≤128 bytes; your idempotency/order key
    )                                            # NO provider_token for Stars
    await c.answer()

@dp.pre_checkout_query()
async def precheck(q: PreCheckoutQuery):
    await q.answer(ok=True)                      # answer within 10s — validation only, no slow work

@dp.message(F.successful_payment)
async def paid(m: Message):
    sp = m.successful_payment
    if db.record_order(m.from_user.id, sp.invoice_payload,
                       sp.telegram_payment_charge_id, sp.total_amount):   # UNIQUE charge_id → idempotent
        await m.answer(render("✅ <b>Оплата получена</b> — заказ выдан!"))   # deliver here

async def main():
    db.init()
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
```

```python
# db.py
import sqlite3
_c = None
def init():
    global _c
    _c = sqlite3.connect("shop.db"); _c.row_factory = sqlite3.Row
    _c.execute("CREATE TABLE IF NOT EXISTS orders(charge_id TEXT UNIQUE, user_id INT, payload TEXT, amount INT)")
    _c.commit()
def record_order(uid, payload, charge_id, amount) -> bool:
    try:
        _c.execute("INSERT INTO orders(charge_id,user_id,payload,amount) VALUES(?,?,?,?)",
                   (charge_id, uid, payload, amount)); _c.commit(); return True
    except sqlite3.IntegrityError:               # duplicate successful_payment retry → already fulfilled
        return False
```

## Notes
- **Stars needs no `provider_token`** and no external webhook — Telegram carries the flow (`stars-payments.md`).
- The `+/−` stepper is **stateless** (qty in callback data) — no FSM. Use FSM only for a *typed* custom
  quantity (`fsm.md`): a state-scoped `Message` handler that runs before the generic `F.text` fallback.
- Idempotency lives on the **`telegram_payment_charge_id` UNIQUE** column — Telegram retries
  `successful_payment` until acked, so `record_order` returning `False` means "already delivered".
- Keep `PREMIUM_EMOJI=off` until the owner account has Premium and you have real `GLYPH_TO_ID` ids.
</content>
