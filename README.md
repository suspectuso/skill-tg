<img src="https://raw.githubusercontent.com/suspectuso/suspectuso/9b84055845032c59df728478bbf1cffc65d0b422/assets/profile-opening.png" width="100%" alt="suspectuso — mascot in a green frog hoodie" />

<p align="center">
  <a href="https://t.me/zkprooff"><img src="https://raw.githubusercontent.com/suspectuso/suspectuso/9b84055845032c59df728478bbf1cffc65d0b422/assets/contact-telegram.svg" width="160" height="56" alt="Telegram" /></a>
  <a href="mailto:dev@suspectus.ru"><img src="https://raw.githubusercontent.com/suspectuso/suspectuso/9b84055845032c59df728478bbf1cffc65d0b422/assets/contact-email.svg" width="160" height="56" alt="Email: dev@suspectus.ru" /></a>
</p>

# skill-tg

An installable **Claude Code plugin** for building and shipping production **Telegram bots**.
Install it and the agent uses it automatically when a Telegram bot task comes up.

Reference implementation (a full, sanitized shop-bot): **https://github.com/suspectuso/TelegramShop**

## Install

In an interactive `claude` terminal:

```
/plugin marketplace add suspectuso/skill-tg
/plugin install skill-tg@skill-tg
```

`/plugin` opens a panel to browse/enable it; `/plugin marketplace update` pulls new versions.
For other agents (Codex CLI etc.) the skill is a plain `SKILL.md` under `skills/skill-tg/` —
point your agent at this repo or drop the folder into its skills directory.

## What's inside — skill `skill-tg`

The build playbook for a Telegram bot on **aiogram 3** or **Go/telebot**:

- premium custom (animated) emoji via Bot API 9.4 — in text (`<tg-emoji>`) and on buttons (`icon_custom_emoji_id`)
- colored inline buttons (`style: primary/success/danger`), rich HTML, and Rich Messages (10.1+)
- Telegram Stars (XTR) + a unified invoice / payment-webhook model (CryptoBot, xRocket, OxaPay, YooKassa, platega)
- closed-channel subscriptions, mass broadcasts, in-memory FSM, deep links / start payloads
- groups, supergroups, forum topics, moderation and anti-spam
- RU/EN localization, Telethon recon/QA of your own or a competitor bot, observability, testing, deploy

Deep-dive material lives under `skills/skill-tg/reference/` — the skill links only what a task needs.

## Contributing

Patterns, not content — see [CONTRIBUTING.md](CONTRIBUTING.md). Keep it clean: no tokens, IPs,
server paths, session files, or private handles.

## License

MIT — see [LICENSE](LICENSE).

<img src="https://raw.githubusercontent.com/suspectuso/suspectuso/9b84055845032c59df728478bbf1cffc65d0b422/assets/profile-closing-matched.png" width="100%" alt="Let’s build something — mascot waving goodbye" />
