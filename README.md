# skill-tg

An **Agent Skill** for building **production Telegram bots** — works with Claude Code, Codex CLI,
Cursor, and any agent supporting the [Agent Skills standard](https://agentskills.io).

Teaches an agent the whole stack: **aiogram 3** and **Go/telebot**, premium (custom animated)
**emoji** via Bot API 9.4, **colored inline buttons**, rich HTML + **Rich Messages** (10.1+),
**Telegram Stars + webhook payments**, closed-channel **subscriptions**, broadcasts, **FSM**,
**moderation/antispam**, groups & forum topics, **RU/EN/UA localization**, **Telethon recon/QA**,
observability, testing, self-hosted Bot API — with a reference implementation and battle-tested
gotchas ("symptom → cause → fix").

Reference implementation: **[TelegramShop](https://github.com/suspectuso/TelegramShop)** (aiogram shop bot).

## Install

**Universal**
```bash
npx skills add suspectuso/skill-tg
```

**Claude Code (marketplace)**
```bash
/plugin marketplace add suspectuso/skill-tg
/plugin install tg-bot-kit@skill-tg
```

**Manual copy**
```bash
# Claude Code
cp -r skills/* ~/.claude/skills/
# Codex CLI / other agents
cp -r skills/* ~/.agents/skills/
# or per-project
cp -r skills/* your-project/.claude/skills/
```
Then just ask, e.g. *"build a Telegram shop bot with premium emoji and Stars payments"*.

## What's inside

### `skills/tg-bot-kit/` — the top-level playbook
`SKILL.md` + `reference/` — 25 deep-dives:

| Area | Files |
|---|---|
| UI | `premium-emoji.md` · `rich-messages.md` · `link-preview-control.md` · `media-groups.md` |
| Payments | `stars-payments.md` · `webhook-server.md` · `subscriptions.md` |
| Flows | `fsm.md` · `deep-links-and-commands.md` · `inline-and-webapp.md` · `broadcast.md` |
| Community | `groups-and-topics.md` · `moderation-and-antispam.md` |
| Ops | `webhook-vs-polling.md` · `media-and-deploy.md` · `local-bot-api.md` · `observability.md` · `testing.md` · `preview-image-server.md` |
| Tooling | `recon.md` · `session-qa.md` · `emoji-pack.md` · `localization.md` · `userbot-forwarder.md` |
| Other stack | `go-telebot.md` (Go + telebot.v3, Raw-API pattern) |

Run `skills/tg-bot-kit/check.sh` before contributing — checks broken links, orphan files, and private-data leaks.

### Bundled Rich Messages (Bot API 10.2) skills
Adapted from [`serejaris/telegram-skills`](https://github.com/serejaris/telegram-skills) (MIT):

| Skill | What it does |
|---|---|
| [`tg-rich-messages`](skills/tg-rich-messages/) | Core reference: markup, outgoing block JSON, media bindings and uploads, preflight, limits, raw HTTP sending |
| [`tg-markdown-to-rich`](skills/tg-markdown-to-rich/) | Convert Markdown into a rich message and bind `file_id`, URL, or uploaded media |
| [`tg-rich-streaming`](skills/tg-rich-streaming/) | Stream LLM output into a chat: draft animation, thinking block, mandatory finalization |
| [`tg-rich-digest`](skills/tg-rich-digest/) | Digest and channel-article patterns: flat layout, preview + collapsed full version, media as evidence, preflight gate |

### Reference
- [`reference/rich-messages-spec.md`](reference/rich-messages-spec.md) — full extracted spec: every type, every field, all limits (Bot API 10.2)
- Official: [Bot API docs](https://core.telegram.org/bots/api) · [changelog](https://core.telegram.org/bots/api-changelog) · demo bot [@RichTextDemoBot](https://t.me/RichTextDemoBot)

## Contributing
Patterns, not content — see [CONTRIBUTING.md](CONTRIBUTING.md). Keep it clean: no secrets, IPs,
private paths, session files, or private handles.

## License
MIT — see [LICENSE](LICENSE).
</content>
