# Payment webhook receiver — aiohttp / net/http

The counterpart to every non-Stars gateway: your bot exposes an HTTP endpoint that the payment
processor calls once the user pays. Signature verification and idempotency are the two rules
you can't skip.

## The generic shape (works for CryptoBot, xRocket, YooKassa, OxaPay, platega, etc.)

```
POST /webhook/<gateway>
  headers: <gateway-specific signature header>
  body:    JSON with { status, invoice_id/order_id, amount, currency, meta? }

    │
    ▼
1. Verify signature over the raw body (or the vendor-specific canonicalisation)
2. Parse body (only AFTER signature check — never trust unverified data)
3. Load transaction by invoice_id; guard on status transition
4. Idempotent UPDATE: WHERE status <> 'paid'; check rows_affected
5. If rows_affected == 1: apply side effects (credit balance / grant access)
6. Return 200 OK  ← always, even for duplicates
```

**Return 200 for duplicates too.** Gateways retry on non-2xx, and a duplicate is not a failure —
you already fulfilled it. Only return 4xx/5xx if the request itself is malformed or the
signature is invalid.

## aiohttp template (Python)

```python
# webhook_server.py
import hashlib, hmac, json, logging
from aiohttp import web
from db import DB              # your DB layer
from bot import bot            # aiogram Bot instance (for user notifications)

log = logging.getLogger("webhook")
routes = web.RouteTableDef()


def _hmac_sha256_hex(body_bytes: bytes, secret: str) -> str:
    return hmac.new(secret.encode(), body_bytes, hashlib.sha256).hexdigest()


@routes.post("/webhook/cryptobot")
async def cryptobot(request: web.Request):
    raw = await request.read()                   # RAW body — signature is over this
    sig = request.headers.get("Crypto-Pay-API-Signature", "")
    expected = _hmac_sha256_hex(raw, CFG.CRYPTOBOT_TOKEN)
    if not hmac.compare_digest(sig, expected):
        log.warning("cryptobot: bad signature")
        return web.Response(status=401, text="bad signature")

    payload = json.loads(raw)
    if payload.get("update_type") != "invoice_paid":
        return web.Response(text="ok")           # other updates: ack, no work

    inv = payload["payload"]                     # actual invoice object
    invoice_id = str(inv["invoice_id"])
    amount     = float(inv["amount"])
    # asset — the coin the user paid in ("USDT", "TON" …), useful for reconciliation

    async with DB.transaction() as tx:
        row = await tx.fetchrow(
            "UPDATE transactions "
            "SET status='paid', paid_at=NOW() "
            "WHERE invoice_id=$1 AND status <> 'paid' "
            "RETURNING user_id, amount, currency, kind",
            invoice_id,
        )
        if row is None:
            log.info("cryptobot: duplicate for %s — ack", invoice_id)
            return web.Response(text="ok")

        await tx.execute(
            "UPDATE users SET balance = balance + $1 WHERE id = $2",
            row["amount"], row["user_id"],
        )
        # if referrer bonus policy applies:
        await apply_referrer_bonus(tx, row["user_id"], row["amount"])

    # side effects OUTSIDE the DB tx (they can fail without corrupting DB state)
    try:
        await bot.send_message(row["user_id"], f"✅ +{row['amount']} credited")
    except Exception as e:
        log.warning("cryptobot: notify failed for %s: %s", row["user_id"], e)

    return web.Response(text="ok")


async def start_webhook_server(host="0.0.0.0", port=8080):
    app = web.Application()
    app.add_routes(routes)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, host, port).start()
    log.info("webhook server on %s:%s", host, port)
```

Wire the server as a coroutine that runs alongside the bot's dispatcher — no separate process:

```python
async def main():
    task = asyncio.create_task(start_webhook_server())
    try:
        await dp.start_polling(bot)              # blocks
    finally:
        task.cancel()
```

## Go net/http template

```go
// webhook/server.go
package webhook

import (
    "crypto/hmac"; "crypto/sha256"; "encoding/hex"; "encoding/json";
    "io"; "net/http"
)

type Server struct {
    db     *DB
    secret string
}

func (s *Server) verifyHMAC(body []byte, header string) bool {
    mac := hmac.New(sha256.New, []byte(s.secret))
    mac.Write(body)
    expected := hex.EncodeToString(mac.Sum(nil))
    return hmac.Equal([]byte(expected), []byte(header))
}

func (s *Server) handleCryptobot(w http.ResponseWriter, r *http.Request) {
    body, err := io.ReadAll(r.Body)
    if err != nil { http.Error(w, "read", 400); return }

    if !s.verifyHMAC(body, r.Header.Get("Crypto-Pay-API-Signature")) {
        http.Error(w, "bad signature", 401); return
    }

    var payload struct {
        UpdateType string `json:"update_type"`
        Payload    struct {
            InvoiceID int64  `json:"invoice_id"`
            Amount    string `json:"amount"`
        } `json:"payload"`
    }
    if err := json.Unmarshal(body, &payload); err != nil {
        http.Error(w, "json", 400); return
    }
    if payload.UpdateType != "invoice_paid" {
        w.Write([]byte("ok")); return
    }

    tag, err := s.db.exec(r.Context(),
        `UPDATE transactions SET status='paid', paid_at=NOW()
         WHERE invoice_id=$1 AND status <> 'paid'`,
        payload.Payload.InvoiceID,
    )
    if err != nil { http.Error(w, "db", 500); return }
    if tag.RowsAffected() == 0 {
        w.Write([]byte("ok")); return          // duplicate, ack
    }

    // credit balance + notify (own tx / async)
    _ = s.creditBalance(r.Context(), payload.Payload.InvoiceID)
    w.Write([]byte("ok"))
}

func (s *Server) Start(addr string) error {
    mux := http.NewServeMux()
    mux.HandleFunc("/webhook/cryptobot", s.handleCryptobot)
    return http.ListenAndServe(addr, mux)
}
```

## Signature verification — cheat-sheet

Different gateways sign different things. Pin these details in a comment at the top of each
handler so nobody normalises the check "helpfully".

| Gateway | Header | Signed over | Secret |
|---|---|---|---|
| CryptoBot | `Crypto-Pay-API-Signature` | **raw request body** | Bot API token (same as `Authorization`) |
| xRocket | `rocket-pay-signature` | raw request body | app-specific secret from dashboard |
| OxaPay | `HMAC` | raw request body | merchant API key |
| YooKassa | none (uses **IP allowlist** + HTTP Basic + optional signature) | body (if signature enabled) | shop-specific |
| platega | `X-Signature-Sha256` | `body + secret` concat, then SHA-256 | merchant secret |

**Read the RAW body once, then verify.** After `await request.read()` in aiohttp / `io.ReadAll`
in Go, do NOT re-parse with a framework helper that re-reads: some helpers strip whitespace and
your HMAC no longer matches. Use `hmac.compare_digest` (Python) / `hmac.Equal` (Go) — plain `==`
leaks timing.

Two YooKassa specifics you cannot skip:

- **IP allowlist** on nginx (or in the handler): YooKassa publishes 5 `/24` ranges; requests
  from anywhere else are attempts.
- **HTTP Basic** with `shopId:secretKey`: nginx `auth_basic_user_file` or handler-side check.

## Idempotency — the two patterns that actually work

**Pattern A: guard by status in a conditional UPDATE.**

```sql
UPDATE transactions
SET    status = 'paid', paid_at = NOW()
WHERE  invoice_id = $1
   AND status <> 'paid'
RETURNING user_id, amount, kind;
```

`RETURNING` gives you the row iff the UPDATE fired. If it returns nothing → duplicate.
This is the whole idempotency contract in one query — no locks, no `SELECT … FOR UPDATE`.

**Pattern B: unique key on the vendor's ledger id.**

```sql
CREATE TABLE gateway_events (
  gateway         TEXT   NOT NULL,
  external_id     TEXT   NOT NULL,
  received_at     TIMESTAMPTZ DEFAULT NOW(),
  raw_body        JSONB  NOT NULL,
  UNIQUE(gateway, external_id)
);
```

`INSERT … ON CONFLICT DO NOTHING RETURNING id` — if you got an id back, this event is new.
Useful when the vendor doesn't map 1:1 to your `transactions` table (some gateways send both
"paid" and later "chargeback" events).

Prefer A for direct invoice-to-transaction mapping. Add B only when you also want an audit log
of every raw event.

## Async side effects — the "user got no notification" trap

Doing `bot.send_message(...)` inside the DB transaction is a two-fold hazard:

- The transaction holds row locks while you await Telegram; a bad Telegram response ties up DB.
- If `send_message` raises, your transaction rolls back — the payment silently un-happens.

Rule: DB transaction commits **first**, notifications are best-effort **after**:

```python
async with DB.transaction() as tx:
    fulfill(tx, …)
# DB is committed here — even if the next line explodes, the payment stands
try:
    await bot.send_message(uid, "✅")
except Exception:
    log.warning(...)
```

Same trap in the other direction: don't send a "payment received" message BEFORE the DB commit —
users occasionally see the message, refresh, and see no balance change because the tx rolled back.

## Local testing without a public URL

```bash
# ngrok / cloudflared / your own reverse tunnel
cloudflared tunnel --url http://localhost:8080
# → https://<random>.trycloudflare.com/webhook/cryptobot

# then poke the endpoint with a fake payload + correct HMAC:
BODY='{"update_type":"invoice_paid","payload":{"invoice_id":1,"amount":"1.00"}}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$CRYPTOBOT_TOKEN" | awk '{print $2}')
curl -X POST https://<tunnel>/webhook/cryptobot \
  -H "Crypto-Pay-API-Signature: $SIG" \
  -H "Content-Type: application/json" \
  --data-binary "$BODY"
```

If the vendor lets you configure the webhook URL to a staging environment (CryptoBot does,
YooKassa test shop does), use that instead of tunnelling — you get real vendor signatures.

## Deployment shape

- nginx in front, HTTPS via Let's Encrypt, `proxy_pass http://127.0.0.1:8080`.
- Never expose the app port (`8080`) to the public internet — bind on `127.0.0.1` in the app.
- Rate-limit at nginx (`limit_req_zone` + `limit_req` on the webhook location) to blunt
  garbage traffic if the URL leaks.
- Log every webhook: `logger.info("webhook %s status=%s invoice=%s dup=%s", gateway, status,
  invoice_id, was_dup)`. Reconciliation later needs it.

## Common mistakes

| Symptom | Cause |
|---|---|
| Duplicate fulfilment (balance grew twice) | Idempotency guard checks `status='paid'` too early (before the UPDATE), letting two concurrent webhooks pass the check |
| "Signature invalid" for legit callbacks | Body re-parsed / re-serialised before HMAC check — recompute over the RAW body only |
| 401 leaks that endpoint exists to attackers | Return a generic `200 OK ok` even for bad signatures? **No** — signatures MUST 401 or attackers can brute-force. Instead don't expose the endpoint via public paths that fingerprint (`/webhook/cryptobot` is fine; `/api/admin/…` next to it is not) |
| Bot sends notification before DB commits | Notification inside the transaction; move it after commit |
| DB tx rolls back and user sees "paid" | Same bug, other direction — never message the user before commit |
| YooKassa "payment succeeded but bot didn't get it" | IP allowlist blocks legitimate retries from a new YooKassa IP — check nginx access log for `403` from YooKassa ranges, update the allowlist |
| CryptoBot always returns bad signature | Token used for signature is the **Bot API token** for CryptoBot, not the `@CryptoBot` login token from `pay.crypt.bot` |
| Concurrent webhook + polling status check double-fulfill | The bot's own "check status" call and the webhook race — always route both through the same `UPDATE … WHERE status <> 'paid'` guard |
