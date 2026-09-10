# Telethon recon — снять чужой бот 1-в-1

Гоняем чужой бот из **user-сессии**, кликаем инлайн-кнопки, снимаем текст+кнопки+стили+эмодзи.

## Загрузка сессии
```python
from telethon import TelegramClient
sess = "/path/session"                 # .session-файл user-аккаунта
api_id = api_hash = None
for line in open("/path/.env"):        # API_ID / API_HASH
    line = line.strip()
    if line.startswith("API_ID"):   api_id = int(line.split("=",1)[1].strip().strip("\"'"))
    if line.startswith("API_HASH"): api_hash = line.split("=",1)[1].strip().strip("\"'")
client = TelegramClient(sess, api_id, api_hash, flood_sleep_threshold=90)
```
**Один процесс за раз** на .session (иначе SQLite-lock / AUTH_KEY_DUPLICATED).

## Снять экран (текст + кнопки + стиль + иконка)
```python
def dump(m):
    print(m.message)
    for row in (m.reply_markup.rows if m.reply_markup else []):
        for b in row.buttons:
            data = getattr(b, "data", None)          # уже bytes
            st = getattr(b, "style", None)
            color = next((k.replace("bg_","") for k in ("bg_success","bg_primary","bg_danger")
                          if st and getattr(st, k, False)), None)
            icon = getattr(st, "icon", None) if st else None   # custom-emoji id на кнопке
            print(repr(b.text), data, color, icon)

def custom_emoji_ids(m):
    from telethon.tl.types import MessageEntityCustomEmoji
    return [e.document_id for e in (m.entities or []) if isinstance(e, MessageEntityCustomEmoji)]
```

## Навигация
```python
ent = await client.get_entity("SomeBot")     # username или id (из iter_dialogs())
await client.send_message(ent, "/start")
# клик по свежайшему входящему сообщению, где есть нужный callback:
async def newest(c, ent):
    for m in await c.get_messages(ent, limit=6):
        if not m.out: return m
async def click(c, ent, data):               # data: bytes
    m = await newest(c, ent)
    for row in (m.reply_markup.rows if m and m.reply_markup else []):
        for b in row.buttons:
            if getattr(b, "data", None) == data:
                await m.click(data=data); return True
    return False
```

## Ловушки (все проверены на практике)
- **`DataInvalidError: Encrypted data invalid`** — кликнул устаревшее сообщение. callback-данные
  криптографически привязаны к сообщению, на котором отрисованы; произвольный callback на чужом
  сообщении не пройдёт. Всегда бери самое свежее входящее.
- **Пагинация**: `nav:page:CAT:N` — следуй только вперёд (`N == cur+1`). Наивный «любой nav:page»
  ловит стрелку ⬅️ и бесконечно пинг-понгит между стр.1↔2. Текущую страницу бери из индикатора «P/N».
- **Flood-wait**: `flood_sleep_threshold=90` + `except FloodWaitError: sleep(e.seconds+2)`. Паузы ~2с.
- **Большой краул** — запускай detached (`nohup … &`), пиши JSON инкрементально, поллируй лог. Не
  держи 20-минутный обход в одном foreground-SSH (таймаут рвёт).
- **SSH heredoc ломает экранирование** — пиши скрипт файлом, `scp`, запускай `./venv/bin/python x.py`.
- Кнопка «Назад» из статьи может вернуть на стр.1 списка — веди множество `visited`, а не позицию.

## Результат
Складывай в JSON: `{screen: {text, buttons:[{text,data,color,icon}], emoji_ids:[...]}}`. Это готовое
ТЗ для клона: тексты → `texts.py`, кнопки+цвета+иконки → `keyboards.py`, эмодзи-ids → `emoji_map.py`.
</content>
