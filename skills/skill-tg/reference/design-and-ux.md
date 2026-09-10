# Design & UX — make a bot screen look intentional, not default

A Telegram bot has no CSS. Its whole "design" is: message layout, text hierarchy, microcopy,
emoji as icons, and button color/row composition. Apply this on every screen — a screen that
skips it reads as a debug dump, not a product.

## A screen = one job
Each message answers "where am I / what can I do here." Structure:
```
<icon> <b>Title</b>            ← one leading emoji + bold title
short 1–2 line description      ← plain, human, no wall of text
                                ← blank line
[ buttons ]                     ← actions, grouped (see below)
```
Never send a bare unformatted paragraph with buttons stuck under it.

## Text hierarchy & microcopy
- **Bold the title and the key numbers** (price, total, balance) with `<b>` — not everything.
- Long content (a table of contents, terms, a big list) → **`<blockquote expandable>`** so the
  screen stays short and the user opens it on demand.
- Copyable values (links, codes, ids) → `<code>…</code>`.
- Microcopy: short, active, human. "Выбери товар" not "Пожалуйста, осуществите выбор товара".
- Use the **same term for the same thing** on every screen (Каталог is always Каталог, not
  "Товары" here and "Магазин" there).

## Emoji = icons, not confetti
- One leading emoji per title/section as an icon. Don't sprinkle emoji through every sentence.
- **One glyph per concept, consistently**: ⭐ = Stars, 🛍/🛒 = catalog, 💳 = pay, ✅ = success,
  ⚠️ = warning, ❌ = error/cancel, 🔙/⬅️ = back. Reuse the same mapping everywhere.

## Buttons — color roles and rows
`style` is a role, not decoration. Assign by meaning:
- **`success`** = the one main positive action of the screen (Купить, Оплатить, Подтвердить).
  **Exactly one `success` per screen** — it's the eye's target.
- **`primary`** = neutral navigation / sections (Каталог, Профиль, next step).
- **`danger`** = destructive or back-out (Отмена, Удалить); also fine for a plain Back.
- Don't rainbow every button — a screen where everything is colored has no focus.

Row composition:
- Primary action of the screen → **its own full-width row** (Купить за N ⭐).
- Related secondary items → **2 per row** (Профиль | Поддержка).
- Navigation (Назад / Главная) → the **last row**, consistent placement, every non-home screen.
- Max ~2–3 buttons per row; keep labels to 1–3 words or they truncate on mobile.
- A stepper (− / count / +) is its own row of three; the count button is a no-op label.

## States
- **Empty** ("нет заказов", "избранное пусто") → a friendly one-liner + a button that leads somewhere.
- **Error / out of stock** → say what happened in one line + the way forward, never a raw traceback.
- **Success** (paid, registered) → confirm with ✅ + what they got + a next action.

## Quality bar — check before finishing any screen
- [ ] Title line with a leading emoji + `<b>`; body ≤ ~3 lines; blank line before buttons.
- [ ] Exactly one `success` button; `danger` only for back-out/destructive; rest `primary`/none.
- [ ] Navigation (Назад/Главная) present and in the last row.
- [ ] Bold used on title + key numbers only; long content in an expandable blockquote.
- [ ] Consistent terms + consistent emoji-per-concept across all screens.
- [ ] No literal `<b>`/`<code>` in the rendered text (you escaped only values, not the template —
      see `premium-emoji.md`).
- [ ] Reads like a product screen, not a form dump.
</content>
