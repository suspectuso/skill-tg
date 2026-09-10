# Contributing to skill-tg

Thanks for helping enrich the skill. One rule above all:

## ⚠️ Patterns, not content
This skill is about **HOW to build** Telegram bots — not about any specific bot's texts,
catalog, prices, or articles. "Give a rod, not a fish."

**Wanted:** techniques, mechanics, non-obvious Bot API / library bugs, feature schemas
(Rich Messages, WebApp, etc.), recon/QA tricks, payment/webhook/localization patterns,
symptom → cause → fix notes. Other stacks welcome (Go/telebot, grammY, aiogram nuances).

**Not wanted:** screen texts, product catalogs, prices, guides, scraped data, any ready-made content.

## 🔒 Keep it clean (this repo is public)
Never commit secrets or private data:
- tokens, API keys, `.env` values
- server IPs, root deploy paths, `.session` file paths
- private bot handles / usernames, internal project names
- third-party scraped content

Use placeholders instead: `@your_bot`, `server:/root/app`, `@your_support`, `https://example.com/...`.

## Format
- Short and concrete, with a minimal real code snippet that illustrates the point.
- Top-level rule/pattern → add to `SKILL.md`.
- Deep dive → add or extend a file in `reference/` (new file: `reference/<topic>.md`, then link it
  from the `## Reference files` list in `SKILL.md`).
- Prefer "symptom → cause → fix" for gotchas.

## Submitting
- Fork → edit → open a Pull Request against `suspectuso/skill-tg`, or
- send the author a diff / text and it'll be merged.

## PR checklist
- [ ] It's a **pattern/technique**, not content.
- [ ] No secrets, IPs, private paths, session files, or private handles.
- [ ] Placeholders used for any credentials/hosts.
- [ ] Concrete and minimal — no filler.
