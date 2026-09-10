# skill-tg — Telegram bot building skill

A [Claude Code](https://docs.claude.com/en/docs/claude-code) **skill** that teaches an agent to
build production Telegram bots the way this codebase does: **aiogram 3**, premium (custom animated)
**emoji** via Bot API 9.4, **colored inline buttons**, rich HTML text (expandable quotes, code),
a unified **invoice + payment-webhook** model, **RU/EN localization**, and **cloning** another
bot's UI 1-to-1 through a Telethon user session (plus using that session to QA your own bot).

Reference implementation: **[tg-shop-kit](https://github.com/suspectuso/tg-shop-kit)**.

## Install
Copy into your Claude Code skills directory:
```bash
git clone https://github.com/suspectuso/skill-tg ~/.claude/skills/tg-bot-kit
```
The agent auto-discovers it and invokes it on Telegram-bot tasks (custom/premium emoji, colored
buttons, competitor recon, etc.).

## Contents
- `SKILL.md` — the playbook (stack, premium emoji, colored buttons, payments, localization, deploy, gotchas).
- `reference/recon.md` — Telethon driver to snapshot another bot's screens 1-to-1.
- `reference/session-qa.md` — use the same session to verify/QA your own bot.
- `reference/premium-emoji.md` — `premiumize()`, glyph→id map, button factory, finding ids.
- `reference/emoji-pack.md` — copy emoji into your own @Stickers pack, get new ids.
- `reference/localization.md` — the RU/EN language dispatcher + middleware.

## License
MIT — see [LICENSE](LICENSE).
