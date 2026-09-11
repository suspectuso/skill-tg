# Testing bots with a Telethon user session (locally and in CI)

## Contents
- Two kinds of tests, keep them separate
- One-time: create a session file
- When `my.telegram.org` is unavailable
- Login geography
- Code delivery
- Session file — the locking rule
- Test-user pattern for E2E
- Clicking buttons — the exact wire behaviour
- Asserting rich features
- Running the bot under test
- Running in CI (GitHub Actions example)
- Rate-limits — what CI has to do to survive
- Fixture: reset DB between tests
- Session for one-off verification (not tests)
- Common mistakes

The bot's own logs show what it *tried* to do. Only a real client-side view — a user session
against the same Telegram servers — shows what actually shipped: button styles, custom emoji,
rich blocks, link previews. This file covers how to run that view for local dev and in CI.

## Two kinds of tests, keep them separate

- **Unit tests** — pure logic (parse an amount, apply a promo, format a text). No network, no
  session, no Telegram. Fast, run on every commit.
- **E2E tests with a session** — spin up (or reuse) a running bot instance and drive it from a
  user account via Telethon. Slow, need creds, one instance per session file, separate CI
  stage.

Don't try to write "unit tests" that mock aiogram/telebot at the layer under `bot.send_message`.
The mocks drift from real Bot API behaviour, silently miss the exact bugs you'd catch (empty
callback_data, wrong emoji ID, `RICH_MESSAGE_EMPTY`) — because those bugs live in JSON on the
wire, not in Python objects.

## One-time: create a session file

Do this once, on a real dedicated Telegram account you use for QA (not your personal one, and
not a burner younger than 30 days — Telegram flags new accounts and blocks bot interactions
from them).

```python
# scripts/make_session.py
import os
from telethon.sync import TelegramClient
API_ID   = int(os.environ["TELETHON_API_ID"])
API_HASH = os.environ["TELETHON_API_HASH"]
with TelegramClient("qa", API_ID, API_HASH) as c:
    print("me:", c.get_me().username)
```

Run interactively once — it prompts for phone / code / 2FA and writes `qa.session` (a SQLite
file). That file IS the auth; keep it out of git, never share it, never open it from two
processes at once.

`API_ID` / `API_HASH` from https://my.telegram.org/apps (one pair per account, forever).

## When `my.telegram.org` is unavailable

Registering an app at https://my.telegram.org/apps is the documented way to get
`API_ID`/`API_HASH`, but the page is not always reachable: it is blocked in some regions,
rejects some accounts outright, and the "Create application" form silently errors for
accounts flagged as new.

Official Telegram clients ship their credentials in open source, so those pairs are public
and usable. The Telegram Desktop pair:

```python
API_ID   = 2040
API_HASH = "b18441a1ff607e10a989891a5462e627"
```

**A public pair only works when the client identifies itself consistently with it.** Telethon
defaults to reporting itself as `Telethon`, which contradicts a desktop-client `api_id` and
is a common reason for a login being refused:

```python
client = TelegramClient(
    "qa", API_ID, API_HASH,
    device_model="Desktop",
    system_version="Windows 11 x64",
    app_version="6.0.2 x64",
    lang_code="en",
    system_lang_code="en-US",
)
```

Keep these parameters identical for the life of the session file. Changing them between runs
looks like a device change and can trigger re-authorisation.

Trade-offs, in order of how likely they are to bite:

- **Shared rate limits.** Thousands of clients use the same public `api_id`; flood limits are
  partly accounted per app. Expect `FLOOD_WAIT_N` sooner than on a private pair.
- **No control.** A public pair can be restricted by Telegram at any time, and every user of
  it is affected at once.
- **Automation is still governed by the ToS** regardless of which credentials are used.

Prefer a private pair from `my.telegram.org` when it is obtainable; treat the public one as
the fallback for QA sessions, not as the default for a production userbot service.

## Login geography

Telegram correlates the phone number's country with the IP the login comes from. A number
issued in one country authorising from an IP in another is a routine fraud signal and shows up as:

- the SMS/app code never arriving,
- `PHONE_NUMBER_BANNED` or a generic error on `sign_in`,
- the session authorising and then being killed minutes later.

The login must originate from an IP in the number's country. Once the session file exists it
travels: MTProto tolerates the IP changing afterwards, so a session created locally can be
copied to a server abroad and keep working. Only the initial authorisation is geo-sensitive.

Corollary for CI: **create the session file on a machine in the right country and commit it to
the secret store** — do not attempt an interactive login from a CI runner.

## Code delivery

Telegram stopped sending login codes by SMS to third-party clients in Feb 2023. A code now
arrives **in the Telegram app itself**, on a device already logged into that account. For an
account with no other active session, use QR login instead:

```python
qr = await client.qr_login()
print(qr.url)                 # render as a QR code, scan from a logged-in device
await qr.wait()               # blocks until confirmed
```

`qr_login()` needs an already-authorised device to scan it, so keep at least one live session
per QA account or the account becomes unrecoverable.

## Session file — the locking rule

Telethon holds an exclusive SQLite lock on the `.session` file for as long as the client is
connected. A second process gets:

- `database is locked` at the Python level, and/or
- `AUTH_KEY_DUPLICATED` from Telegram if both processes actually connect (the server sees two
  authorised clients on the same key and forces logouts).

**Rules:**

- **One process per session file.** Ever.
- If you use the same session for a userbot service (e.g. a mirror / poster) AND for tests,
  copy the file:

  ```bash
  cp qa.session qa.tests.session
  ```

  Both are separately-authorised keys after first connect; treat them as independent from
  then on.
- Before running any test locally, `systemctl stop <session-consuming-svc>` (or whatever is
  holding it), and start it back **only if** it was running before.

## Test-user pattern for E2E

```python
# tests/e2e/conftest.py
import os, asyncio, pytest_asyncio
from telethon import TelegramClient
from telethon.tl.custom import Message

BOT_USERNAME = os.environ["BOT_USERNAME"]     # your bot's @, e.g. @mytest_bot


@pytest_asyncio.fixture(scope="session")
async def client():
    c = TelegramClient(
        "qa.tests",                            # separate session copy for tests
        int(os.environ["TELETHON_API_ID"]),
        os.environ["TELETHON_API_HASH"],
        flood_sleep_threshold=90,
    )
    await c.start()
    try:
        yield c
    finally:
        await c.disconnect()


@pytest_asyncio.fixture
async def bot_peer(client):
    return await client.get_entity(BOT_USERNAME)


async def wait_for_reply(client, peer, after_id: int, timeout: float = 10.0) -> Message:
    """Poll until the bot replies with a message newer than after_id."""
    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        msgs = await client.get_messages(peer, limit=1)
        if msgs and msgs[0].id > after_id:
            return msgs[0]
        await asyncio.sleep(0.4)
    raise TimeoutError("bot did not reply in time")
```

Then write test bodies that drive real screens:

```python
# tests/e2e/test_menu.py
import pytest


@pytest.mark.asyncio
async def test_start_shows_main_menu(client, bot_peer):
    baseline = (await client.get_messages(bot_peer, limit=1))[0].id
    await client.send_message(bot_peer, "/start")
    m = await wait_for_reply(client, bot_peer, baseline)

    # 1) text
    assert "Welcome" in m.raw_text

    # 2) keyboard shape
    assert m.reply_markup is not None
    labels = [b.text for row in m.reply_markup.rows for b in row.buttons]
    assert "Balance" in labels
    assert "Referrals" in labels


@pytest.mark.asyncio
async def test_deposit_flow_reaches_invoice(client, bot_peer):
    baseline = (await client.get_messages(bot_peer, limit=1))[0].id
    await client.send_message(bot_peer, "/start")
    menu = await wait_for_reply(client, bot_peer, baseline)

    # tap "Balance" by its callback data (already bytes — don't .encode())
    await menu.click(data=b"balance")
    balance = await wait_for_reply(client, bot_peer, menu.id)

    await balance.click(data=b"deposit")
    deposit = await wait_for_reply(client, bot_peer, balance.id)

    # pick a gateway, then type an amount
    await deposit.click(data=b"gw:cryptobot")
    prompt = await wait_for_reply(client, bot_peer, deposit.id)

    await client.send_message(bot_peer, "1")
    confirm = await wait_for_reply(client, bot_peer, prompt.id)

    assert "Confirm" in confirm.raw_text
```

## Clicking buttons — the exact wire behaviour

- Callback data on Telethon `Message.reply_markup.rows[].buttons[]` is **already bytes**. Pass
  it straight to `msg.click(data=b"...")`. Don't `.encode()` — you'll double-encode.
- Some libraries prefix the payload with `\f` (`b"\fadmin"`). This is telebot.v3's on-wire
  format for `kb.Data(text, unique)` where the value lives in `Unique`. See
  `reference/go-telebot.md` for details; test-side you copy the bytes you observe on the button,
  not what you *think* they should be.
- **`DataInvalidError: Encrypted data invalid`** = you clicked a stale message. Callback data is
  bound to the specific `(chat_id, message_id)` it was rendered on. Always click the freshest
  message — the one you just fetched with `get_messages(limit=1)` or the one returned by
  `wait_for_reply`.

## Asserting rich features

Beware: MTProto (Telethon) **does not render Bot API 10.1 rich messages**. A rich message shows
up with `text=""`, `media=None`, and no `.blocks` field to inspect. So you cannot assert
content of a rich message from Telethon — assert **that the edit happened** instead:

```python
# baseline the message that will be edited (or wait for the initial placeholder)
placeholder = await wait_for_reply(client, bot_peer, baseline_id)
first_edit_at = placeholder.edit_date

# trigger the flow, then poll the same message for a NEW edit
await placeholder.click(data=b"open:item_42")
for _ in range(20):
    await asyncio.sleep(0.5)
    fresh = (await client.get_messages(bot_peer, ids=placeholder.id))
    if fresh.edit_date and (first_edit_at is None or fresh.edit_date > first_edit_at):
        break
else:
    raise AssertionError("no edit observed")

# now assert the KEYBOARD (that Telethon can see) — colours & icons come from Bot API 9.4
labels = [b.text for row in fresh.reply_markup.rows for b in row.buttons]
assert "← Back" in labels
```

For OG-preview inline results, wait ~7 s after clicking the inline result in Saved Messages
(Telegram fetches the OG page async), then re-fetch and assert `MessageMediaWebPage` with a
non-empty `.webpage.photo`. See `reference/inline-and-webapp.md` for the full recipe.

## Running the bot under test

Two patterns; pick one and stick with it.

**A) Test against a dedicated staging bot.** Keep a second bot token in `.env.test`, point the
QA session at that bot's `@username`. Both bots share the same code, different DB. Simplest,
zero mocking. Downside: you need a second token from @BotFather and a second Postgres
instance / schema.

**B) Test against the running dev bot.** Only works if your dev DB tolerates test data. Handy
for quick iterations, dangerous for CI (concurrent runs collide on the same user account).

For CI, always pattern A.

## Running in CI (GitHub Actions example)

```yaml
# .github/workflows/e2e.yml
name: e2e
on: [pull_request]

jobs:
  e2e:
    runs-on: ubuntu-latest
    services:
      db:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready --health-interval 5s --health-timeout 5s --health-retries 5
        ports: ["5432:5432"]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }

      - name: Install deps
        run: pip install -r requirements-test.txt

      - name: Restore Telethon session
        env:
          QA_SESSION_B64: ${{ secrets.QA_SESSION_B64 }}    # base64-encoded qa.tests.session
        run: |
          echo "$QA_SESSION_B64" | base64 -d > qa.tests.session

      - name: Migrate
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/postgres
        run: alembic upgrade head

      - name: Start bot in background
        env:
          BOT_TOKEN:     ${{ secrets.STAGING_BOT_TOKEN }}
          DATABASE_URL:  postgres://postgres:postgres@localhost:5432/postgres
        run: |
          nohup python -m app.main > bot.log 2>&1 &
          sleep 3
          # sanity — is it responding?
          curl -sf https://api.telegram.org/bot${BOT_TOKEN}/getMe

      - name: Run e2e
        env:
          TELETHON_API_ID:   ${{ secrets.TELETHON_API_ID }}
          TELETHON_API_HASH: ${{ secrets.TELETHON_API_HASH }}
          BOT_USERNAME:      ${{ vars.STAGING_BOT_USERNAME }}   # @yourstaging_bot
        run: pytest tests/e2e -v --maxfail=1

      - name: Bot logs on failure
        if: failure()
        run: tail -200 bot.log
```

Secrets checklist:

- `QA_SESSION_B64` — `base64 -w0 qa.tests.session` on your workstation, paste as an
  actions secret. Rotate if leaked; regenerate by re-running `make_session.py`.
- `TELETHON_API_ID`, `TELETHON_API_HASH` — from my.telegram.org, per QA account.
- `STAGING_BOT_TOKEN` — dedicated staging bot from @BotFather.
- `STAGING_BOT_USERNAME` — the `@username` of that bot (not the token).

## Rate-limits — what CI has to do to survive

- **`flood_sleep_threshold=90`** on `TelegramClient(...)` — auto-sleep up to 90 s on flood
  waits instead of raising. Longer floods still raise (`FloodWaitError`), catch and re-raise
  after the sleep, or the test framework will mark them as fatal.
- **Space clicks ~2 s apart.** Don't hammer callbacks; add a `await asyncio.sleep(1.5)` between
  actions in a long test.
- **Cap test parallelism at 1** for E2E runs — one test-session, one running bot, don't split.

## Fixture: reset DB between tests

```python
# conftest.py — for the bot under test, not the QA session
import pytest_asyncio, asyncpg


@pytest_asyncio.fixture(autouse=True)
async def reset_bot_db():
    """Truncate the QA user's rows between tests so state doesn't leak."""
    conn = await asyncpg.connect(os.environ["DATABASE_URL"])
    try:
        qa_tg_id = int(os.environ["QA_TG_ID"])
        await conn.execute("DELETE FROM transactions WHERE user_id IN (SELECT id FROM users WHERE telegram_id = $1)", qa_tg_id)
        await conn.execute("DELETE FROM subscriptions WHERE telegram_id = $1", qa_tg_id)
        await conn.execute("DELETE FROM users WHERE telegram_id = $1", qa_tg_id)
    finally:
        await conn.close()
```

Truncate only the QA account's rows, not the whole table — you don't want CI to nuke real dev
users if `DATABASE_URL` gets pointed at the wrong DB by accident.

## Session for one-off verification (not tests)

The same session file is a great debugging tool without a test framework:

```bash
./venv/bin/python - <<'PY'
import asyncio, os
from telethon import TelegramClient, functions

async def main():
    c = TelegramClient("qa", int(os.environ["TELETHON_API_ID"]),
                       os.environ["TELETHON_API_HASH"])
    await c.start()
    bot = await c.get_entity("@yourbot")
    async for m in c.iter_messages(bot, limit=3):
        print(m.id, m.date, m.raw_text[:80])
        if m.reply_markup:
            for row in m.reply_markup.rows:
                for b in row.buttons:
                    print("  ", type(b).__name__, b.text,
                          getattr(b, "data", None),
                          getattr(getattr(b, "style", None), "bg_success", None))
    await c.disconnect()

asyncio.run(main())
PY
```

Same one-process-per-session rule applies — stop any long-running services on that session
first, or copy the file.

## Common mistakes

| Symptom | Cause |
|---|---|
| `database is locked` | Two processes on one `.session` — stop one or copy the file |
| `AUTH_KEY_DUPLICATED` | Same, but Telegram noticed — both processes get force-logged-out; regenerate `qa.session` |
| `DataInvalidError: Encrypted data invalid` | Clicked a stale message (older than the freshest one) — always click the newest |
| Test asserts wrong bytes on callback | Read `b.data` — it's already bytes; don't `.encode()`, and don't strip `\f` (that's the wire format) |
| Rich content assertions always fail | MTProto doesn't render rich — assert `edit_date` changed, not the text/media |
| Flood-wait shreds CI | `flood_sleep_threshold=90` + sleep between clicks + serial test execution |
| Test bot behaves differently than prod | You're testing against the dev DB but a prod-tokened bot — misalign token / DB in `.env.test` |
| Session file leaked into git | Add `*.session` and `*.session-journal` to `.gitignore` from day one; if it leaked, revoke via my.telegram.org and regenerate |
| CI is green but the deploy is broken | Something the bot does at startup (registers commands, sets webhook) failed silently — add a "healthcheck" test that calls `getMe` after start and asserts the intended commands are registered |
| Login refused with a public `api_id` | Client identifies as `Telethon` while the `api_id` belongs to a desktop client — pass matching `device_model` / `system_version` / `app_version` |
| Login code never arrives | Codes are not sent by SMS to third-party clients since Feb 2023 — read it in an app already signed in, or use `qr_login()` |
| `PHONE_NUMBER_BANNED` / session dies minutes after login | Number's country and login IP disagree — authorise from an IP in the number's country; only the first login is geo-sensitive |
| Account unrecoverable, `qr_login()` impossible | QR needs an already-authorised device to scan it — always keep one live session per QA account |
| Session re-asks for authorisation each run | `device_model`/`app_version` differ between runs — they are part of the session identity, keep them fixed |
| `FLOOD_WAIT_N` far sooner than expected | Public `api_id` shares its quota with every other user of that pair — move to a private pair for anything long-running |
