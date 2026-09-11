# In-memory FSM for text inputs (aiogram + Go/telebot.v3)

## Contents
- aiogram 3 — built-in FSMContext with `MemoryStorage`
- The generic-text handler trap
- Timeout / abandonment
- Go / telebot.v3 — a hand-rolled equivalent
- When to reach for persistent state (Redis / DB) instead
- Common mistakes

Bots have flows where the user taps a button, then the bot expects a free-form message next
(amount, username, promo code, custom text). That "next message" gate is FSM. For 90% of bots
you don't need Redis / a BoltDB — a per-process map keyed by telegram id is enough.

## aiogram 3 — built-in FSMContext with `MemoryStorage`

The framework's own solution. Free, thread-safe, lives in-process.

```python
# main.py
from aiogram import Bot, Dispatcher, F
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import StatesGroup, State
from aiogram.types import Message, CallbackQuery

bot = Bot(BOT_TOKEN)
dp  = Dispatcher(storage=MemoryStorage())     # persist state in-process


class Deposit(StatesGroup):
    choosing_gateway = State()
    entering_amount  = State()
    confirming       = State()


@dp.callback_query(F.data == "deposit")
async def deposit_start(cb: CallbackQuery, state: FSMContext):
    await state.set_state(Deposit.choosing_gateway)
    await cb.message.edit_text("Choose gateway", reply_markup=GATEWAYS_KB)
    await cb.answer()


@dp.callback_query(Deposit.choosing_gateway, F.data.startswith("gw:"))
async def deposit_pick_gw(cb: CallbackQuery, state: FSMContext):
    gw = cb.data.split(":")[1]
    await state.update_data(gateway=gw)                   # remember for later steps
    await state.set_state(Deposit.entering_amount)
    await cb.message.edit_text("Enter amount (min $1):", reply_markup=BACK_KB)
    await cb.answer()


@dp.message(Deposit.entering_amount, F.text)
async def deposit_amount(m: Message, state: FSMContext):
    try:
        amount = round(float(m.text.replace(",", ".").strip()), 2)
    except ValueError:
        return await m.answer("Amount must be a number. Try again:")
    if amount < 1:
        return await m.answer("Minimum is $1. Try again:")

    data = await state.get_data()                          # gateway from earlier step
    await state.update_data(amount=amount)
    await state.set_state(Deposit.confirming)
    await m.answer(
        f"Confirm deposit *${amount}* via *{data['gateway']}*?",
        reply_markup=confirm_kb(amount, data["gateway"]),
        parse_mode="Markdown",
    )


@dp.callback_query(Deposit.confirming, F.data.startswith("dep:confirm:"))
async def deposit_confirm(cb: CallbackQuery, state: FSMContext):
    data = await state.get_data()
    invoice = await create_invoice(cb.from_user.id, data["amount"], data["gateway"])
    await state.clear()                                    # ← ALWAYS clear on happy path
    await cb.message.edit_text(f"Invoice created:\n{invoice.url}")
    await cb.answer()


@dp.callback_query(F.data == "back")
async def any_back(cb: CallbackQuery, state: FSMContext):
    await state.clear()                                    # ← ALWAYS clear on Back
    await cb.message.edit_text("Main menu", reply_markup=MAIN_MENU_KB)
    await cb.answer()
```

Rules from painful experience:

- **`state.clear()` on every exit**, including the Back button and errors — otherwise the next
  unrelated text the user sends gets picked up by a stale FSM handler.
- **`state.update_data(...)` accumulates** — later calls merge, they don't replace. Don't write
  a full dict every step, just the new fields.
- **State filter goes first in `@dp.message(Deposit.foo, F.text)`** — order matters for handler
  resolution; state-filtered handlers must beat generic ones.
- **`MemoryStorage` is per-process.** A restart wipes it. That's fine for these flows — users
  just re-tap the button. If you scale to multiple worker processes, switch to `RedisStorage`
  with the same interface.

## The generic-text handler trap

If you have both a state-scoped `@dp.message(SomeState.entering_x, F.text)` AND a fallback
`@dp.message(F.text)` for `/start`-style responses, the state handler *must* be registered
first, and the fallback should short-circuit when a state is active:

```python
@dp.message(F.text)
async def fallback(m: Message, state: FSMContext):
    if await state.get_state() is not None:
        return   # a state-scoped handler will handle it
    await m.answer("Use /start to open the menu.")
```

Otherwise you end up with two handlers firing on the same message.

## Timeout / abandonment

`MemoryStorage` has no expiry — a user who taps `Enter amount` then walks away leaves state
pinned forever, so their next unrelated message a week later gets swallowed by the amount
handler. Add a middleware:

```python
# fsm_timeout_middleware.py
import time
from aiogram import BaseMiddleware
from aiogram.types import TelegramObject

TIMEOUT_SEC = 15 * 60


class FSMTimeoutMiddleware(BaseMiddleware):
    async def __call__(self, handler, event: TelegramObject, data):
        state = data.get("state")
        if state:
            d = await state.get_data()
            now = time.time()
            if d.get("_ts") and now - d["_ts"] > TIMEOUT_SEC:
                await state.clear()
            else:
                await state.update_data(_ts=now)
        return await handler(event, data)


dp.message.middleware(FSMTimeoutMiddleware())
dp.callback_query.middleware(FSMTimeoutMiddleware())
```

15 min is a decent default; tune per flow.

## Go / telebot.v3 — a hand-rolled equivalent

telebot has no FSM out of the box. Ten lines of state map + a middleware are enough:

```go
// internal/bot/state.go
package bot

import "sync"

type StateKind string
const (
    StNone           StateKind = ""
    StDepositAmount  StateKind = "deposit_amount"
    StWithdrawAmount StateKind = "withdraw_amount"
    StWithdrawUser   StateKind = "withdraw_user"
    StEnterPromo     StateKind = "enter_promo"
    StAdminAddBal    StateKind = "admin_add_bal"
    StAdminAddDays   StateKind = "admin_add_days"
)

type State struct {
    Kind StateKind
    Data map[string]any
}

type Store struct {
    mu sync.RWMutex
    m  map[int64]State     // key = telegram user id
}

func NewStore() *Store { return &Store{m: map[int64]State{}} }

func (s *Store) Set(uid int64, kind StateKind, data map[string]any) {
    s.mu.Lock(); defer s.mu.Unlock()
    s.m[uid] = State{Kind: kind, Data: data}
}
func (s *Store) Get(uid int64) State {
    s.mu.RLock(); defer s.mu.RUnlock()
    return s.m[uid]
}
func (s *Store) Clear(uid int64) {
    s.mu.Lock(); defer s.mu.Unlock()
    delete(s.m, uid)
}
```

Wire it into the text handler as a switch:

```go
b.Handle(tele.OnText, func(c tele.Context) error {
    uid := c.Sender().ID
    st  := store.Get(uid)
    defer store.Clear(uid)               // clear on every consumed input

    switch st.Kind {
    case StDepositAmount:
        amount, err := parseAmount(c.Text())
        if err != nil {
            store.Set(uid, StDepositAmount, st.Data)   // put it back to keep waiting
            return c.Send("Invalid amount, try again:")
        }
        gw := st.Data["gateway"].(string)
        return startDepositConfirm(c, gw, amount)

    case StEnterPromo:
        return applyPromo(c, c.Text())

    case StNone:
        return c.Send("Use /start to open the menu")
    }
    return nil
})
```

And set the state from callback handlers:

```go
b.Handle(&btnDeposit, func(c tele.Context) error {
    _ = c.Respond()
    store.Set(c.Sender().ID, StDepositAmount, map[string]any{"gateway": "cryptobot"})
    return c.Edit("Enter amount:", backKB)
})
```

Same rules as aiogram: clear on Back, clear on errors, `defer store.Clear` in the text handler
so a raised error still leaves clean state.

## When to reach for persistent state (Redis / DB) instead

Rare. Do the switch only when one of these is true:

- Multi-process bot (horizontally scaled workers) — in-memory doesn't share.
- Step involves external I/O whose loss is expensive (e.g. a webhook you're waiting for that
  might arrive after a bot restart).
- Regulatory / audit — every state transition must be persisted.

Otherwise the trade-off (extra dep, extra failure mode, TTL bugs) isn't worth it.

## Common mistakes

| Symptom | Cause |
|---|---|
| Unrelated user message triggers the amount handler | `state.clear()` missed on Back / error path |
| State handler doesn't fire, generic one does | Generic `F.text` registered before state-scoped `Deposit.foo` — reorder |
| Data from step 1 disappears at step 3 | Used `set_data(...)` (replace) instead of `update_data(...)` (merge) |
| Bot restart drops flows mid-way | Expected — either accept it (users re-tap) or move to `RedisStorage`; don't add DB persistence "just in case" |
| User walks away, next week's greeting eaten by FSM | No FSM timeout — add the middleware above |
| Concurrent updates from same user race | aiogram's default is serial per-user; if you dispatched to workers, add a per-user lock |
| Two workers both fulfil the same purchase | You scaled polling — switch to webhooks OR move state to Redis with `set NX` guard |
