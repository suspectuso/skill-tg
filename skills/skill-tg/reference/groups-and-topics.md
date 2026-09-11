# Bots in groups, supergroups, and forum topics

## Contents
- Chat types you'll deal with
- Privacy mode — the setting that hides half the updates
- Getting the bot in
- Tracking membership: `ChatMemberUpdated`
- The old `new_chat_members` event still fires
- Admin permissions matrix
- Sending into a specific topic (forum groups)
- Chat action / typing indicator
- Slow-mode and moderation basics
- Sending as the anonymous admin
- Linked channel + discussion group
- Common mistakes

Almost every group/community bot has three concerns: getting the bot in, tracking who's in
the group, and posting into the right sub-place (a topic, a thread, a specific admin channel).
This file covers the primitives that don't map cleanly to what a DM bot looks like.

## Chat types you'll deal with

- **`private`** — a DM. What most bots are built for by default.
- **`group`** — a "basic group" (small, no username, up to 200 members). Legacy — Telegram
  auto-upgrades many to supergroups. Bots have almost no admin capabilities in basic groups.
- **`supergroup`** — the real thing (up to 200 000 members, admin-manageable, message deletion,
  slow-mode, permissions, invite links, discussion linked to a channel). *All* group-related
  bot features live here. Numeric id is negative and starts with `-100`.
- **`channel`** — broadcast-only. Bot can post as an admin, can't `banChatMember` from a
  channel via the same API (uses `banChatMember` targeting a supergroup id linked to the
  channel for the discussion group).
- **Forum groups** (supergroup with topics enabled) — sub-threads within the group. Adds
  `message_thread_id` on every message.

Check with `bot.get_chat(chat_id).type`.

## Privacy mode — the setting that hides half the updates

Bots in groups have a **privacy setting** in @BotFather (`/setprivacy`):

- **Enabled (default):** the bot receives only:
  - messages that start with `/command`
  - messages that mention `@your_bot`
  - messages that are replies to the bot's own messages
  - service events (new members, left members, etc.)
- **Disabled:** the bot receives every message in the group.

Consequences:

- **You must disable privacy** if the bot moderates content (spam detection, keyword filters,
  captcha for arbitrary messages).
- **Restart the bot in the group after toggling.** Telegram caches the privacy state
  per-bot-per-chat; the bot must be re-added or the group has to send a message that triggers
  cache refresh. `bot.leave_chat(chat_id)` then add it back with the new setting works.
- Even with privacy disabled, the bot only receives messages sent **after it joined**. It
  can't retroactively read history — for that you need a userbot (see `reference/session-qa.md`).

## Getting the bot in

Three flows:

**Add-to-group deep link** — Telegram-native; user picks the target group:
```
https://t.me/<bot_username>?startgroup=<optional_payload>
https://t.me/<bot_username>?startgroup=<payload>&admin=<perm1>+<perm2>
```
`admin=` promotes the bot on add. Permissions: `manage_chat`, `delete_messages`,
`restrict_members`, `promote_members`, `manage_video_chats`, `invite_users`, `pin_messages`,
`post_messages`, `edit_messages`, `manage_topics`, `post_stories`, `edit_stories`,
`delete_stories`, `anonymous`.

**Programmatic add** — only via a user session (Telethon), not from a bot. Bots cannot add
themselves.

**Manual add** — user goes to group settings → add member → search for the bot.

Verify after add:
```python
member = await bot.get_chat_member(chat_id, bot.id)
# member.status is one of: 'creator', 'administrator', 'member', 'restricted', 'left', 'kicked'
if member.status != "administrator":
    await bot.send_message(chat_id, "Please promote me — I need admin rights to work.")
```

## Tracking membership: `ChatMemberUpdated`

Two update types you must whitelist in `allowed_updates` (they're not sent by default):

- **`chat_member`** — every membership change of every user in every chat the bot admins.
  Rich firehose; handle only if you moderate.
- **`my_chat_member`** — membership changes **of the bot itself**. Fires when the bot is added,
  promoted, restricted, kicked, or the group upgrades from basic to supergroup. Every bot in
  groups should handle this.

```python
# aiogram
from aiogram.types import ChatMemberUpdated
from aiogram import F

@dp.my_chat_member()
async def bot_membership_changed(u: ChatMemberUpdated):
    chat, old, new = u.chat, u.old_chat_member, u.new_chat_member
    if new.status == "member":
        await bot.send_message(chat.id, "Thanks for adding me. Promote me to admin to enable full features.")
    elif new.status == "administrator":
        await refresh_admin_capabilities(chat)
    elif new.status == "left":
        await db.chats.set(chat.id, is_active=False)
    elif new.status == "kicked":
        await db.chats.set(chat.id, is_banned=True)


@dp.chat_member()
async def user_membership_changed(u: ChatMemberUpdated):
    if u.old_chat_member.status in ("left", "kicked") and \
       u.new_chat_member.status in ("member", "restricted"):
        # user just joined
        await on_user_joined(u.chat.id, u.new_chat_member.user)
    elif u.new_chat_member.status in ("left", "kicked"):
        await on_user_left(u.chat.id, u.old_chat_member.user)
```

Wire it into `Dispatcher.start_polling(allowed_updates=…)` explicitly, or use aiogram's
`dp.resolve_used_update_types()`.

## The old `new_chat_members` event still fires

Legacy — a message with `.new_chat_members` populated. It's sent to all bots regardless of the
`chat_member` whitelist, but only for **members visible to the bot** (e.g. added by direct
click). For a full picture of joins, prefer `chat_member`, not `new_chat_members`.

## Admin permissions matrix

`getChatMember(chat_id, bot.id).status == "administrator"` alone isn't enough — admin without
the right specific rights can't do what you want:

| Action | Right required |
|---|---|
| Delete any message | `can_delete_messages` |
| Restrict / kick members | `can_restrict_members` |
| Promote other admins | `can_promote_members` |
| Pin messages | `can_pin_messages` |
| Manage topics (create/close/edit) | `can_manage_topics` |
| Post in a linked channel via the group | `can_post_messages` on the channel, not the group |
| Post stories | `can_post_stories` |

`getChatAdministrators(chat_id)` returns each admin with their specific rights, so you can
render a "your bot is missing these rights" message that's actually helpful.

## Sending into a specific topic (forum groups)

Forum groups (Telegram Forums / topics) split a supergroup into threads. Every message carries
`message_thread_id`; without one, messages go to the "General" topic.

```python
# post into a specific topic
await bot.send_message(
    chat_id=forum_chat_id,
    message_thread_id=317,                            # topic id
    text="Hello topic",
)
```

Handling incoming: `message.message_thread_id` is set. `message.is_topic_message` is `True`
except in the General topic (which is `False` even though technically it *is* a topic).

Create / manage topics:
```python
topic = await bot.create_forum_topic(
    chat_id=forum_chat_id,
    name="Support",
    icon_color=0x6FB9F0,                              # 6 fixed colours
    icon_custom_emoji_id="5379748062124056162",       # optional
)
# topic.message_thread_id is the id you'll use for send_message

await bot.edit_forum_topic(chat_id, topic.message_thread_id, name="Renamed")
await bot.close_forum_topic(chat_id, topic.message_thread_id)
await bot.reopen_forum_topic(chat_id, topic.message_thread_id)
await bot.delete_forum_topic(chat_id, topic.message_thread_id)   # irreversible
```

**Bot must have `can_manage_topics` for any of the above.**

### Support-desk pattern using topics

Each customer conversation is its own topic in a supergroup:

```
Support group
├── Topic: "General" (system, staff coordination)
├── Topic: "Customer 12345" (all messages from/to user 12345)
├── Topic: "Customer 67890"
└── …
```

- When user first messages bot → bot creates a topic in the support group named after them,
  stores `(user_id, message_thread_id)` map.
- User messages → forwarded to that topic.
- Staff replies in the topic → bot mirrors back to the user's DM.

Advantages over the classic "everything in one channel" pattern: each conversation is
scrollable in isolation, closing a topic archives it, staff can subscribe to specific customer
topics. Cost: managing the map, cleaning up topics when a customer leaves.

## Chat action / typing indicator

`sendChatAction` shows a "typing…" / "uploading photo…" indicator for ~5 seconds. Use before a
slow reply:

```python
async with ChatActionSender.typing(bot=bot, chat_id=chat_id):
    result = await slow_api_call()
    await bot.send_message(chat_id, result)
```

Actions: `typing`, `upload_photo`, `record_video`, `upload_video`, `record_voice`,
`upload_voice`, `upload_document`, `choose_sticker`, `find_location`, `record_video_note`,
`upload_video_note`. In a topic: pass `message_thread_id`.

Overuse feels spammy. Rule of thumb: only for handlers slower than ~1 second.

## Slow-mode and moderation basics

`setChatPermissions` (chat-wide) and `restrictChatMember` (per user) let a bot mute / rate-limit.
Common patterns:

```python
# 60-second slow-mode
await bot.set_chat_slow_mode_delay(chat_id, 60)

# mute one user for 10 minutes
from aiogram.types import ChatPermissions
from datetime import datetime, timedelta, timezone

await bot.restrict_chat_member(
    chat_id=chat_id,
    user_id=user_id,
    permissions=ChatPermissions(can_send_messages=False),
    until_date=datetime.now(timezone.utc) + timedelta(minutes=10),
)
```

- **`until_date < 30 seconds` or `> 366 days` from now = permanent restriction.** Between = as
  specified. Common gotcha: `until_date=0` means "forever", not "unrestricted" — read the
  changelog.
- To fully lift: call `restrict_chat_member` with all `ChatPermissions(True)`, no `until_date`.
- **Bot needs `can_restrict_members`** even to mute — plain admin isn't enough.

## Sending as the anonymous admin

If the bot is an admin with `anonymous=True`, its messages appear signed as the group name, not
the bot name. `promoteChatMember(user_id=bot.id, is_anonymous=True)`. Anonymous admins can't
be @mentioned or reported, useful for automated moderation.

## Linked channel + discussion group

A channel can be linked to a discussion supergroup — every channel post auto-forwards into the
group's General topic and users comment in the group. Bot patterns:

- Bot in both, receives the same content twice (as a channel `channel_post`, then as a group
  `message` with `sender_chat` = the channel). Filter one out or you double-handle.
- `bot.get_chat(channel_id).linked_chat_id` returns the group id.
- To post a message into the channel that starts a discussion in the group: `send_message`
  to the channel. Users comment in the group; the bot receives their comments as `message`
  updates with `reply_to_message.sender_chat` = the channel.

## Common mistakes

| Symptom | Cause |
|---|---|
| Bot doesn't see regular messages in the group | Privacy mode is on by default; disable in @BotFather, then re-add the bot to the group to refresh the cache |
| Bot receives group messages twice | Same content arrived as `channel_post` (from linked channel) and `message` (auto-forward into group). Filter by `message.sender_chat` |
| `chat_member` updates never arrive | Not in `allowed_updates`. Use `dp.resolve_used_update_types()` |
| `banChatMember` succeeds but the user rejoins | `banChatMember` is a permanent ban unless `until_date` is set; but the user joined via an invite link that isn't revoked. Ban + revoke the link |
| "Kick for now" but user can't come back | Used bare `banChatMember`. Do `banChatMember` + immediate `unbanChatMember` — that's Telegram's "remove for now" idiom |
| `set_chat_slow_mode_delay` silently ignored | Bot lacks `can_restrict_members` right |
| Message sent to forum group appears in General instead of the intended topic | Missing `message_thread_id` on `send_message` — General topic is the default |
| `create_forum_topic` returns 400 | Group isn't a forum (topics disabled). Enable via @BotFather → `/mybots → …` isn't it — group owner enables in Telegram client settings |
| Old-style `new_chat_members` fires but no `chat_member` | `chat_member` not whitelisted; `new_chat_members` is on the plain `message` update which is always delivered |
| Anonymous admin messages arrive but bot can't reply to the sender | Anonymous admins have no `user.id` accessible — `message.from_user` is `None`. Use `sender_chat` or `via_bot` to identify the source |
| Bot posted a message but can't delete it later | `can_delete_messages` right missing, or message is older than 48 h in a group without full admin rights |
| Group has 200k members and the join-event handler is slow | You're doing per-user DB work synchronously on `chat_member` — queue the work into a background task instead |
