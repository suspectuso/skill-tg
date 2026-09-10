# Subscription bots — the full closed-channel flow

Model: Go + telebot.v3 + PostgreSQL bot that gates access to a private Telegram channel, with
paid plans (monthly / yearly), balance top-up via CryptoBot / xRocket / other Bot-API-compatible
gateways, referral bonuses, promo codes, and a scheduler for expiry warnings and auto-kick.

Same shape works for aiogram + SQLite (the drip / notifications subset is portable).

## Data model (Postgres)

```sql
users(
  id PK, telegram_id UNIQUE, username, first_name,
  language TEXT DEFAULT 'ru',
  balance NUMERIC DEFAULT 0,
  referrer_id FK -> users.id,
  ref_code TEXT UNIQUE,        -- 10 chars, used in ?start=r-<code>
  created_at
)

subscriptions(
  id PK, user_id FK, telegram_id,
  plan TEXT,                    -- '1m' | '1y' | 'free'
  price NUMERIC, expires_at TIMESTAMPTZ,
  kicked BOOL DEFAULT FALSE,
  notified_3d BOOL, notified_1d BOOL, notified_2h BOOL,
  created_at
)

transactions(
  id PK, user_id FK,
  type TEXT,   -- deposit | withdraw | subscription | referral_days | referral_milestone | referral_bonus
  amount NUMERIC, status TEXT,   -- pending | paid | failed
  payment_system TEXT,           -- cryptobot | xrocket | balance
  invoice_id TEXT,               -- vendor id, for webhook matching
  created_at
)

promo_codes(
  id PK, code TEXT UNIQUE,
  type TEXT,          -- 'percent' | 'days'
  value NUMERIC,      -- percent 0..100 or days count
  max_uses INT, uses INT DEFAULT 0,
  expires_at TIMESTAMPTZ NULL,
  created_at
)

promo_uses(
  user_id FK, promo_id FK,
  UNIQUE(user_id, promo_id)     -- one code per user
)
```

Three migrations, monotonically numbered. Never modify a landed migration; append a new one.

## Purchase flow

1. User taps `Оформить подписку` → picks a plan → confirms.
2. `SubBuy` handler:
   - Load user in one tx; assert `balance >= price`.
   - `UPDATE users SET balance = balance - price WHERE id = $1`.
   - `INSERT INTO transactions (..., type='subscription', status='paid', payment_system='balance')`.
   - `INSERT INTO subscriptions (..., plan, price, expires_at = now() + plan_duration, kicked=false)`.
   - If `users.referrer_id`: apply referral bonus (see below), in the same tx.
3. Grant channel access — `ApproveChatJoinRequest(chat_id, user_id)` if there's a pending
   request, else `CreateChatInviteLink(member_limit=1, expire_date=now()+1h)` and send it.
4. Reply with two `URL` buttons ("Войти в …") — one per channel.

Two channel ids in `.env` (`CHANNEL_ID`, `CHANNEL_ID_2`); the bot enforces that the user has an
approved join request in both before checkout (this is a business rule for gated communities;
skip it for single-channel bots).

## Balance top-up + payment webhooks

- Handler `Deposit` → choose gateway → FSM state `StateDepositEnterAmount` → user types amount.
- On confirm, create a vendor invoice via API (CryptoBot / xRocket / OxaPay / platega / Stars).
- Save `transactions(invoice_id, status='pending')`.
- Reply with the vendor's `pay_url` as a `URL` button.

Webhook side:

```
POST /webhook/cryptobot   →  aiohttp / net/http server on :8080
POST /webhook/xrocket
```

Every webhook handler must:
- **Verify signature** (`Crypto-Pay-API-Signature` HMAC-SHA256 for CryptoBot,
  `rocket-pay-signature` for xRocket).
- **Load the transaction by `invoice_id`** — if not found, 200 OK + log (Telegram-side may retry).
- **Idempotency:** update `transactions SET status='paid' WHERE invoice_id=$1 AND status <> 'paid'`
  and check `rows_affected`. If 0, this webhook is a duplicate — ack, do nothing else.
- Only then: `UPDATE users SET balance = balance + amount`, send success message to user,
  apply referral 30% bonus to the referrer (if any).

## Scheduler — expiry warnings and auto-kick

Runs every 15 min (goroutine on start; systemd-unit for standalone), single query per stage:

- **`3d` warning**: subscriptions where `expires_at BETWEEN now()+2d+22h AND now()+3d+2h AND
  notified_3d=false` → send GIF + text + `[🔄 Продлить]` → set `notified_3d=true`.
- **`1d`** and **`2h`** warnings: analogous with their own flags.
- **Kick**: `expires_at < now() AND kicked=false` → `banChatMember(chat_id, user_id)` then
  **`unbanChatMember(chat_id, user_id)`** (unban is critical — a plain ban permanently bars them;
  ban+unban is Telegram's idiom for "remove for now"). Set `kicked=true`. Send message with a
  `[🔄 Продлить подписку]` button (callback `renew_sub`).

Flags exist so a Telegram flood-wait / restart doesn't spam the same user twice. Never reset a
flag on renewal — instead, create a NEW row in `subscriptions` for the new period; treat prior
rows as history.

## Referral system

- On registration, if `?start=r-<code>` — resolve to `users.ref_code`, set
  `users.referrer_id = referrer.id`. Once, never overwrite.
- **On subscription purchase**: award referrer `10%` of plan days (e.g. 3 days per 30d plan).
  `INSERT INTO transactions (type='referral_days', amount = ceil(days*0.1))`, then extend the
  referrer's active subscription `expires_at` by that many days. Notify referrer.
- **Milestones**: every 5 referrals who bought a subscription → +30 days bonus. Track by counting
  referral_days transactions or a dedicated counter — either way, a milestone must fire at most
  once per threshold.
- **On balance top-up**: award referrer `30%` of the top-up amount to their balance (only if the
  referrer has an active subscription; otherwise skip — do not accumulate for later).

All bonuses go through `transactions` with distinct `type` values so the admin can audit and
the user's `history` screen renders them.

## Promo codes

Two types:

- **`days`** — instant: extends the user's active subscription (or creates a `free` sub with
  `expires_at = now() + value days` if none). One transaction row of `type='promo_days'`.
- **`percent`** — a **discount for the next purchase**. Store the pending discount in memory
  (FSM) or as a session field; apply on the plan-selection screen (strikethrough old price, show
  new). Do not touch balance.

Validation ladder in order (first match wins):
- code not in table → "Промокод не найден".
- `expires_at < now()` → "Срок действия истёк".
- `uses >= max_uses` (0 = unlimited) → "Промокод исчерпан".
- `(user_id, promo_id) EXISTS in promo_uses` → "Вы уже использовали этот промокод".
- Success → `INSERT INTO promo_uses (user_id, promo_id)` then `UPDATE promo_codes SET uses = uses + 1`.
  Do both in one transaction so a crash doesn't burn a use without recording who used it.

## In-memory FSM for text inputs

Users type free-form text (amounts, usernames, promo codes) after a callback. A tiny map is
enough — no need for Redis/BoltDB.

```go
// internal/bot/state.go
type state struct {
    kind string // "deposit_amount" | "withdraw_amount" | "withdraw_user" | "enter_promo" | ...
    ctx  map[string]any // e.g. {"system":"xrocket"}
}
var states = struct {
    sync.RWMutex
    m map[int64]state // key: telegram id
}{m: map[int64]state{}}
```

- `OnText` handler: look up `states[uid]`. If empty, ignore (or send `/start`).
- If matched: consume the input, delete the state, run the next step.
- Reset on `/start` and on any `←Назад` button.
- State is process-local — bot restart wipes it. That's fine for these flows (user just re-taps
  the button). Do NOT persist state to DB unless a step is expensive to redo.

## Admin panel

`ADMIN_IDS=123,456` in `.env`. `/admin` shows a menu; every callback checked against the list.

Screens:
- **Stats**: totals, active subs, balance sum, revenue — 4 queries.
- **User search**: FSM `StateAdminSearchUser` → accept @username or numeric id → user card
  with 2 buttons: `+баланс`, `+дни`. Each is its own FSM step that accepts a number.
- **Broadcast**: pick audience (all / active subs) → type text → preview with `[✅ Отправить (N чел)]`
  button carrying the count → on click, iterate through recipients with `time.Sleep(30ms)` between
  sends and swallow FloodWaitError with exponential backoff.
- **Create promo**: 5-step FSM (code → type → value → max_uses → expiry). Confirm and insert.
- **Run scheduler now**: manual trigger for the same job the scheduler goroutine runs.

Broadcast is the only place that needs care: rate-limit yourself (Telegram sends ~30 msgs/s to
different users but a burst spikes flood-waits). Log per-user failures but don't stop the run.

## Kick + rejoin logic — the two subtle bugs

1. **`banChatMember` without `unbanChatMember` makes the user permanently unable to rejoin.**
   Always chain them for a "boot for now" semantic.
2. **`OnChatJoinRequest` fires for every request**, including ones from users you just kicked.
   Don't auto-approve — require the user to buy a fresh subscription first. Otherwise a kicked
   user can rejoin free by hitting the "Join channel" button again.

## Deploy notes

- Bot process (`getUpdates`) and payment webhook server can live in the same process (one
  `bot.Start()` goroutine + one `http.ListenAndServe` goroutine). Separate them only if you need
  to scale differently or use a webhook for the bot itself.
- Payment webhook port must be reachable from CryptoBot / xRocket IPs — put nginx in front with
  Let's Encrypt; don't expose 8080 directly.
- `LongPoller{Timeout: 10 * time.Second}` for telebot, aiohttp `web.AppRunner` for aiogram. Both
  survive stop-the-world updates; systemd `Restart=always` covers the rest.

## RU/EN/UA (three languages, not two)

Same dispatcher pattern as `reference/localization.md`, but `texts_ua.py` exists too. The
language screen shows three buttons before the user picks. Default when unset: RU.

## Not covered here

- Webhook signature verification per gateway — see the vendor docs, one HMAC per file
  (`internal/payments/cryptobot/verify.go`, `internal/payments/xrocket/verify.go`).
- GIF cycling on subscription-related messages — pool of file_ids per event
  (`kick`, `success`, `warning`), pick random, cache the file_id after the first upload.
