# skill-tg

An installable **Claude Code plugin** for building and designing **Telegram bots** — one
plugin, `tg-bot-kit`, that bundles a top-level build playbook plus a set of focused
Rich-Messages skills. Install it and your agent uses the right one automatically when a
Telegram task comes up.

Reference implementation (a full, sanitized shop-bot): **https://github.com/suspectuso/TelegramShop**

## Install

In an interactive `claude` terminal:

```
/plugin marketplace add suspectuso/skill-tg
/plugin install tg-bot-kit@skill-tg
```

`/plugin` opens a panel to browse/enable it; `/plugin marketplace update` pulls new versions.
For other agents (Codex CLI etc.) the skills are plain `SKILL.md` files under `skills/` — point
your agent at this repo or drop the folders into its skills directory.

## What's inside — plugin `tg-bot-kit`

| Skill | Use it for |
|---|---|
| **tg-bot-kit** | The top-level playbook. Build & ship a bot end-to-end (aiogram 3 or Go/telebot): premium custom emoji (Bot API 9.4), colored inline buttons, rich HTML, unified invoices + payment webhooks, Telegram Stars, closed-channel subscriptions, broadcasts, moderation, groups/forum-topics, RU/EN localization, Telethon recon/QA, observability, testing, deploy. |
| **tg-rich-messages** | Bot API 10.2 Rich Messages: tables, section headings, collapsible blocks, photo galleries, maps, formulas, audio — the block model, media bindings and limits when HTML/Markdown isn't enough. |
| **tg-markdown-to-rich** | Convert Markdown / a report / a doc into an `InputRichMessage` JSON for `sendRichMessage`, with `file_id` / URL / multipart-upload media bindings. Ships `md2rich.py` + tests. |
| **tg-rich-streaming** | Stream an LLM reply token-by-token (ChatGPT-style) with a "thinking" indicator, finalizing into one permanent message. |
| **tg-rich-digest** | Daily/weekly digests, community summaries, newsletters, channel articles as one structured rich message (flat + preview→collapsed layouts, preflight gate). |

### Reference

`reference/` holds ~27 deep-dive files the skills link into — buttons & styles, custom emoji,
inline/reply keyboards, tables, navigation & flows, rich media, streaming, localization & RTL,
limits & splitting, security & escaping, testing playbook, the Rich Messages spec, SDK
compatibility, and more. Skills pull only what a task needs.

## Credits

- The Rich Messages 10.2 skills (`tg-rich-messages`, `tg-markdown-to-rich`, `tg-rich-streaming`,
  `tg-rich-digest`) are adapted from **[serejaris/telegram-skills](https://github.com/serejaris/telegram-skills)** (MIT).
- Much of the bot UI/UX reference set is adapted from **[hlibsuslov/telegram-bot-ui](https://github.com/hlibsuslov/telegram-bot-ui)** (MIT).
- `tg-bot-kit` and this packaging by **suspectuso**.

## Contributing

Patterns, not content — see [CONTRIBUTING.md](CONTRIBUTING.md). Keep it clean: no tokens, IPs,
server paths, session files, or private handles.

## License

MIT — see [LICENSE](LICENSE).
