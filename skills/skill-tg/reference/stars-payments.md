# Telegram Stars — native in-app payments

Stars (XTR) is Telegram's native currency for digital goods. It's the only gateway that doesn't
need a third-party webhook: Telegram itself carries the whole flow through the Bot API. Since
2024 Telegram's policy requires Stars for **digital** goods and services (subscriptions, media
access, in-bot features) — third-party PSPs (CryptoBot/xRocket/YooKassa) are for **physical**
goods and services delivered outside Telegram.

## Wire-level shape

```
sendInvoice        →  message with "Pay" button, price shown in ⭐
   ↓ user taps Pay, confirms
pre_checkout_query →  bot must answer within 10s: ok=true or error message
   ↓ Telegram charges
successful_payment →  arrives inside a Message update; contains total_amount + payload
                       and a telegram_payment_charge_id for refunds
```

There is no webhook to verify a signature on — the update comes through `getUpdates` /
`setWebhook` like any other. Signature is implicit (Telegram's own transport).

## Building the invoice

```python
# aiogram 3
from aiogram.types import LabeledPrice

await bot.send_invoice(
    chat_id=user_id,
    title="Monthly access",
    description="One month of channel access",
    payload=f"sub:1m:{user_id}",              # your idempotency key, ≤128 bytes
    currency="XTR",                            # ← Stars
    prices=[LabeledPrice(label="Subscription", amount=100)],   # 100 stars
    # NO provider_token when currency="XTR" — omit it
    # NO need_email / need_phone_number for Stars
    start_parameter="sub_1m",                  # optional deep-link handle
)
```

- **`payload`** is critical: your bot receives it back on both `pre_checkout_query` and
  `successful_payment`. Encode enough to fulfill the order without re-querying: kind + ids.
- **`currency="XTR"`** and **omit `provider_token`** entirely — providing one makes Telegram treat
  the invoice as a legacy fiat invoice and reject it.
- Stars amounts are integers of **whole stars**, not subunits.

Go / telebot.v3:

```go
inv := &tele.Invoice{
    Title:       "Monthly access",
    Description: "One month of channel access",
    Payload:     fmt.Sprintf("sub:1m:%d", userID),
    Currency:    "XTR",
    Prices:      []tele.Price{{Label: "Subscription", Amount: 100}},
}
_, err := b.Send(&tele.User{ID: userID}, inv)
```

## Handling `pre_checkout_query`

Telegram gives you **10 seconds** to answer. Answering `ok=false` cancels the charge and shows
the user your error message. Answering `ok=true` locks the charge in.

```python
from aiogram import F
from aiogram.types import PreCheckoutQuery

@dp.pre_checkout_query()
async def pre_checkout(q: PreCheckoutQuery):
    # decode your own payload; verify the order is still valid
    kind, *rest = q.invoice_payload.split(":")
    if kind not in ("sub", "topup", "product"):
        return await q.answer(ok=False, error_message="Invalid order")
    # optionally: check the product is still purchasable (stock, plan still active)
    await q.answer(ok=True)
```

Rules:
- Do NOT run slow work here (DB writes, external calls with unbounded latency). Answer `ok=true`
  fast; do the real fulfillment on `successful_payment` where you can afford time.
- On any doubt, **answer `ok=false`** — Telegram has NOT charged the user yet, so a cancel is
  free. A silent timeout auto-cancels and leaves the user staring at a stuck spinner.

Go/telebot:

```go
b.Handle(tele.OnCheckout, func(c tele.Context) error {
    q := c.PreCheckoutQuery()
    if !isValidPayload(q.Payload) {
        return c.Accept("Invalid order")   // ok=false with error message
    }
    return c.Accept()                       // ok=true
})
```

## Handling `successful_payment` — the fulfillment

This is where you actually deliver the goods. It arrives as a normal Message with
`successful_payment` populated.

```python
from aiogram.types import Message

@dp.message(F.successful_payment)
async def on_paid(m: Message):
    sp = m.successful_payment
    # sp.total_amount = 100  (stars, integer)
    # sp.invoice_payload = "sub:1m:12345"
    # sp.telegram_payment_charge_id = "..."  (needed for refunds)
    kind, plan, uid_str = sp.invoice_payload.split(":")
    uid = int(uid_str)

    # IDEMPOTENCY: guard on charge_id, not on user+time
    if db.stars_charge_exists(sp.telegram_payment_charge_id):
        return   # duplicate delivery from Telegram
    db.stars_charge_record(
        charge_id=sp.telegram_payment_charge_id,
        user_id=uid, kind=kind, plan=plan,
        stars=sp.total_amount,
    )

    # deliver — same fulfill_invoice(kind, …) you use for other gateways
    await fulfill(kind, plan, uid)
    await m.answer("✅ Payment received")
```

**Idempotency key: `telegram_payment_charge_id`.** Store it in a UNIQUE column; Telegram may
retry `successful_payment` if your bot didn't ack the update. A second delivery with the same
charge_id is a duplicate — no-op.

## Refunds

Stars supports **refundStarPayment** — the bot can refund a Stars payment programmatically
within Telegram's window (currently 21 days).

```python
await bot.refund_star_payment(
    user_id=uid,
    telegram_payment_charge_id=charge_id,
)
```

- Refunds do NOT reverse your fulfillment automatically — void the subscription / access on
  your side in the same transaction.
- Failure mode: `TelegramBadRequest: CHARGE_ALREADY_REFUNDED` — treat as success (idempotent).

Go via Raw:

```go
_, err := b.Raw("refundStarPayment", map[string]any{
    "user_id":                     uid,
    "telegram_payment_charge_id":  chargeID,
})
```

## Balance top-up vs direct purchase

Two shapes:

- **Direct pay-per-order** — `sendInvoice(payload="product:42:42stars")` → on payment, deliver
  product 42. No stored balance. Preferred for one-shot items; sidesteps "hold customer funds"
  regulatory surface.
- **Stars-topup → balance → subscription** — `sendInvoice(payload="topup:100")` → on payment,
  credit +100 to `users.balance`. Subscription purchase spends balance. Useful when users buy
  multiple things or you want promo codes to reduce cost.

Same fulfillment table, just a different `kind` in `payload`.

## Star gifts / paid reactions (Bot API 8.x)

- **`getMyStarBalance`**: your bot's own Star balance (users can gift Stars to bots).
- **`sendGift` / `giftPremiumSubscription`**: send digital gifts. Useful for referral rewards
  paid in Stars.
- **`getStarTransactions`**: full ledger of Stars in/out for the bot; use it for reconciliation
  rather than reconstructing from `successful_payment`s alone (missed updates happen).

## Common mistakes

| Symptom | Cause |
|---|---|
| `PAYMENT_PROVIDER_INVALID` | Set `provider_token` while `currency="XTR"` — omit it entirely for Stars |
| `CURRENCY_TOTAL_AMOUNT_INVALID` | Non-integer amount or wrong minimum (Stars minimum is 1 XTR) |
| User sees no "Pay" button | Bot has no Payments enabled in @BotFather → `/mybots → Payments`. For Stars this is automatic in current Telegram, but old bots may need re-enabling |
| Duplicate fulfillment | You keyed idempotency off user+time, not `telegram_payment_charge_id` |
| Bot times out on `pre_checkout_query` | Slow work in the handler → move fulfillment to `successful_payment` |
| Refund succeeds but access remains | Fulfillment reversal isn't hooked to refunds — do it in the same transaction as `refundStarPayment` |
