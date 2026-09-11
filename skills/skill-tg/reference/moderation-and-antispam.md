# Moderation and anti-spam for group / community bots

## Contents
- The layers, in order of catch-rate
- Layer 1: join-time captcha
- Layer 2: new-member restrictions (trust-level ramp)
- Layer 3: content filters (regex + heuristics)
- Layer 4: user reports
- Layer 5: ban ledger
- Trap: bots joining as bots
- Traps that eat your delete privilege
- The report chat pattern (support desk in reverse)
- Rate-limit yourself, or Telegram will
- Common mistakes

The spam problem in Telegram groups: bots trying to sell scams, forwarded ads, invite-link
floods from throw-away accounts. Effective moderation is layered — nothing single blocks
everything, but the layers compound.

## The layers, in order of catch-rate

1. **Join-time captcha** — blocks 80-95% of botnet joiners.
2. **New-member restrictions** — the first N minutes with tight permissions (no links, no
   forwards) blocks most of what a botnet does even if the captcha is passed.
3. **Content filters** — regex/pattern scan on messages from users below a trust threshold.
4. **User reports** — humans in the loop for anything you missed.
5. **Ban ledger** — remember bad actors across restarts, share across your groups if you run
   multiple.

Skipping the first layer to over-invest in the last three is the usual mistake.

## Layer 1: join-time captcha

The pattern: on `chat_member` (or the legacy `new_chat_members`), immediately restrict the user
to `can_send_messages=false` for M minutes, and send an inline-keyboard message with a "Prove
you're human" button. On click → lift the restriction. On timeout → ban+unban (kick).

```python
# services/captcha.py
import asyncio
from datetime import datetime, timedelta, timezone
from aiogram.types import ChatMemberUpdated, ChatPermissions, \
    InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery
from aiogram import F

CAPTCHA_TIMEOUT_MIN = 3


@dp.chat_member()
async def new_member(u: ChatMemberUpdated):
    if not (u.old_chat_member.status in ("left", "kicked") and
            u.new_chat_member.status == "member"):
        return
    if u.new_chat_member.user.is_bot:
        return                                           # bots you deliberately added

    user = u.new_chat_member.user
    chat = u.chat

    # 1) mute immediately
    await bot.restrict_chat_member(
        chat.id, user.id,
        permissions=ChatPermissions(can_send_messages=False),
        until_date=datetime.now(timezone.utc) + timedelta(minutes=CAPTCHA_TIMEOUT_MIN + 1),
    )

    # 2) prompt
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(
            text="🤖 I'm human",
            callback_data=f"captcha:{user.id}",
        )
    ]])
    msg = await bot.send_message(
        chat.id,
        f"Welcome, <a href='tg://user?id={user.id}'>{user.full_name}</a>!\n"
        f"Please tap the button below within {CAPTCHA_TIMEOUT_MIN} minutes.",
        reply_markup=kb, parse_mode="HTML",
    )

    # 3) timeout task
    asyncio.create_task(_captcha_timeout(chat.id, user.id, msg.message_id))


async def _captcha_timeout(chat_id: int, user_id: int, prompt_msg_id: int):
    await asyncio.sleep(CAPTCHA_TIMEOUT_MIN * 60)
    m = await bot.get_chat_member(chat_id, user_id)
    if m.status == "restricted" and not m.can_send_messages:
        # never clicked the button — kick
        await bot.ban_chat_member(chat_id, user_id)
        await bot.unban_chat_member(chat_id, user_id)
    # regardless: clean up the prompt
    try:
        await bot.delete_message(chat_id, prompt_msg_id)
    except Exception:
        pass


@dp.callback_query(F.data.startswith("captcha:"))
async def captcha_click(cb: CallbackQuery):
    expected_uid = int(cb.data.split(":")[1])
    if cb.from_user.id != expected_uid:
        return await cb.answer(
            "This button isn't for you.", show_alert=True,
        )
    # lift restrictions
    await bot.restrict_chat_member(
        cb.message.chat.id, expected_uid,
        permissions=ChatPermissions(
            can_send_messages=True, can_send_photos=True, can_send_videos=True,
            can_send_video_notes=True, can_send_voice_notes=True,
            can_send_polls=True, can_send_other_messages=True,
            can_add_web_page_previews=True, can_invite_users=True,
        ),
    )
    await cb.answer("Welcome!")
    try:
        await bot.delete_message(cb.message.chat.id, cb.message.message_id)
    except Exception:
        pass
```

Variations:

- **Random-emoji captcha:** show 6 emojis, one is the "target"; user must tap the matching
  one. Blocks trivial "click first button" bots. Downside: friction for humans.
- **Slow-mode substitute:** for very high-signup rate groups, add `slowmode_delay=10` for the
  first N users — legit users don't notice, bots that spam instantly stall.
- **Question-based:** free-text answer to a group-specific question. Highest catch-rate, worst
  UX; only for tight communities.

## Layer 2: new-member restrictions (trust-level ramp)

Even a captcha-passing account might be a spammer with mechanical Turk labour. Restrict *new*
users' capabilities for the first 24 h:

```sql
CREATE TABLE members (
  chat_id      BIGINT NOT NULL,
  user_id      BIGINT NOT NULL,
  joined_at    TIMESTAMPTZ NOT NULL,
  trust_level  INT DEFAULT 0,        -- 0 = new, 1 = mature (>24h), 2 = trusted
  PRIMARY KEY (chat_id, user_id)
);
```

Rule: for `trust_level = 0`, drop:

- messages with `entities` of type `url` / `text_link` / `mention` / `hashtag`.
- messages that are forwarded (`forward_origin` is set).
- messages containing invite links (`t.me/joinchat/…`, `t.me/+…`).
- attachments (photos, videos, documents) — spam vector, uncommon for legit newcomers.

Delete-on-match, notify once in the chat ("New members can't send links until they've been
here 24 h"), don't ban. Cron every hour: `UPDATE members SET trust_level=1 WHERE joined_at <
now()-'24h' AND trust_level=0`.

## Layer 3: content filters (regex + heuristics)

Regexes for common scam patterns — keep them in code, not DB, so a scam wave is a one-line PR
not a UI dance:

```python
import re

SCAM_PATTERNS = [
    re.compile(r"t\.me/joinchat/\S+", re.I),
    re.compile(r"t\.me/\+[\w-]{10,}", re.I),
    re.compile(r"(?:invest|earn|profit|bitcoin|crypto)\s+\d+[%$]", re.I),
    re.compile(r"\b(?:USDT|BTC|ETH)\s+giveaway\b", re.I),
    re.compile(r"@\w+_?bot\b.*\b(?:free|profit|earn)\b", re.I),
    re.compile(r"[​‌‍]{3,}"),          # zero-width chars = obfuscation
]


def looks_like_spam(text: str) -> bool:
    if not text: return False
    return any(p.search(text) for p in SCAM_PATTERNS)


@dp.message(F.chat.type.in_({"group", "supergroup"}))
async def moderate(m: Message):
    text = m.text or m.caption or ""
    trust = await db.trust_level(m.chat.id, m.from_user.id)
    if trust == 0 and looks_like_spam(text):
        try:
            await bot.delete_message(m.chat.id, m.message_id)
        except Exception:
            pass
        # first offence: warn, second: mute 1h, third: kick
        offences = await db.record_offence(m.chat.id, m.from_user.id)
        if   offences == 1: await bot.send_message(m.chat.id, "Message removed — please don't post links as a new member.")
        elif offences == 2: await _mute(m.chat.id, m.from_user.id, 60)
        elif offences >= 3: await _kick(m.chat.id, m.from_user.id)
```

`bot.get_chat_member(chat_id, bot.id)` must have `can_delete_messages` **and**
`can_restrict_members` for this to work.

### Zero-width character trick

Spammers hide invisible characters (`​`, `‌`, `‍`) inside otherwise-normal text
to break naive substring matches on `t.me`. The regex `[​‌‍]{3,}` catches
purposeful use; normal text almost never has three in a row.

Also strip them before running your other regexes:
```python
text_norm = re.sub(r"[​‌‍﻿]", "", text)
```

## Layer 4: user reports

`/report` command that any group member can reply to a suspicious message with. Forward the
message to an admin channel, add "Delete", "Mute 1 h", "Kick", "Ban" buttons.

```python
@dp.message(Command("report"), F.reply_to_message)
async def report(m: Message):
    if not m.reply_to_message:
        return await m.answer("Reply to a message with /report.")

    target  = m.reply_to_message.from_user
    reporter = m.from_user

    # forward the offending message to admin group
    forwarded = await bot.forward_message(
        chat_id=ADMIN_CHAT_ID,
        from_chat_id=m.chat.id,
        message_id=m.reply_to_message.message_id,
    )
    await bot.send_message(
        ADMIN_CHAT_ID,
        f"Reported by {reporter.full_name} (id {reporter.id})\n"
        f"Target: {target.full_name} (id {target.id}) in {m.chat.title}",
        reply_markup=_report_actions_kb(m.chat.id, target.id, m.reply_to_message.message_id),
        reply_to_message_id=forwarded.message_id,
    )
    await m.reply("Reported. An admin will review.")
```

Admin buttons: callback_data encodes the action; handler executes the delete/mute/kick against
the original chat, not the admin chat.

**Rate-limit `/report` per reporter** — abuse potential is high. `db.report_recent(reporter,
target, within=1h)` returns the count; refuse above N.

## Layer 5: ban ledger

`banChatMember` on Telegram's side prevents the user from rejoining that chat (until you
`unbanChatMember`), but if they joined via an invite link that another admin created, the ban
must be paired with a link revocation.

```sql
CREATE TABLE bans (
  chat_id     BIGINT NOT NULL,
  user_id     BIGINT NOT NULL,
  reason      TEXT,
  banned_by   BIGINT,
  banned_at   TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (chat_id, user_id)
);
```

Cross-chat: if you run multiple related groups, share the `bans` table. On `chat_member`
insert (user joined some chat you moderate), check the ledger — kick pre-emptively if they're
on it.

## Trap: bots joining as bots

Users add friends' bots to your group. They can spam even before responding to captcha (a bot
never taps a button). Two defenses:

- **`allowed_updates` includes `chat_member`; on join with `is_bot=True` from a non-admin,
  ban immediately** unless you have a whitelist.
- **Restrict "add members" permission** in the group settings so only admins can invite —
  won't stop admins' own mistakes, will stop casual "add my friend's bot" cases.

## Traps that eat your delete privilege

- **Users can delete their own messages for up to 48 h.** Race between your delete and theirs
  is fine (both are silent) but if you rely on `on_message_deleted` you won't see users
  cleaning up after themselves; use `chat_member` and full ban ledger, not deletion tracking.
- **Bots can delete any message for up to 48 h** in a group with `can_delete_messages`.
  Older than 48 h — bots can delete only their own messages. Design retro-moderation around
  that limit.
- **Anonymous admins' messages have `from_user=None`** — you can't ban `None`. Check
  `sender_chat` instead; ban `sender_chat.id` (the channel) via `banChatSenderChat`.

## The report chat pattern (support desk in reverse)

Instead of admins scattered across the group, funnel everything into one chat:

```
Users' group ────report / auto-moderation event──▶ Admin group
                                                    ├── Reported msg 1 [Delete] [Mute] [Kick] [Ban]
                                                    ├── Reported msg 2 [Delete] …
                                                    └── Captcha timeouts (auto-kicks)
```

Admins can silence the users' group and still see moderation traffic. Callback buttons on the
forwarded messages let a single admin act without leaving Telegram. See
`reference/groups-and-topics.md` for the topic-per-conversation variant.

## Rate-limit yourself, or Telegram will

Delete storms trigger `429 Too Many Requests` and the bot gets throttled. When cleaning up a
spam raid:

```python
for m in messages_to_delete:
    try:
        await bot.delete_message(m.chat.id, m.message_id)
    except TelegramRetryAfter as e:
        await asyncio.sleep(e.retry_after + 1)
        await bot.delete_message(m.chat.id, m.message_id)
    await asyncio.sleep(0.05)                           # 20/s max
```

For batch cleanup post-raid: `delete_messages` (plural) — one API call for up to 100 messages.

## Common mistakes

| Symptom | Cause |
|---|---|
| Captcha message stays after user solves it | Missing `delete_message` in the success handler; wrap in try/except (users can delete it themselves) |
| Captcha "not you" leaks who's captchaing | You called `cb.answer()` without `show_alert=True`; use alert so the reveal is only to the clicker |
| New member never gets prompted | Missing `chat_member` in `allowed_updates`; also privacy mode caches unless you re-add the bot to the group |
| Legit user gets kicked mid-conversation | Filter fires on `trust_level=0`, but user has been in the group for months — never populated `members` row. Backfill on bot deploy: `INSERT INTO members SELECT chat_id, user_id, now()-'30d' FROM …` |
| Spam regex catches legit links | Constrain to `trust_level = 0` only; senior members shouldn't be filtered |
| `ban_chat_member` succeeds but user returns instantly | Old invite link is still valid. `revokeChatInviteLink` on every admin-generated link; use `createChatInviteLink(member_limit=1)` for one-shot invites |
| `delete_message` fails silently | Missing `can_delete_messages` right; catch `TelegramBadRequest` and log — don't rely on the delete happening |
| Anonymous admin can't be banned via `banChatMember` | `from_user is None`; use `banChatSenderChat(chat_id, sender_chat.id)` |
| `/report` gets abused | No rate-limit on `/report` per reporter; add `report_recent(user, within=1h) < 3` guard |
| Delete storm during a raid triggers 429 | No `sleep` between deletes; batch with `delete_messages` and add a per-second cap |
| Zero-width chars bypass regex | Normalise text: `re.sub(r"[​-‏﻿]", "", text)` before matching |
| New-member restriction lifted by another admin's client | Telegram's restriction UI overwrites the bot's `restrict_chat_member`; keep bot-side flag in DB and re-apply on next message if state diverges |
