# Свой эмодзи-пак (копия чужих глифов, чтобы не палить источник)

Скачиваем нужные кастом-эмодзи по document_id и перезаливаем в свой пак через @Stickers → получаем
СВОИ id. Аккаунту нужен **Telegram Premium**, чтобы создать эмодзи-пак.

## 1. Скачать документы эмодзи
```python
from telethon.tl.functions.messages import GetCustomEmojiDocumentsRequest
docs = await client(GetCustomEmojiDocumentsRequest(document_id=[<id1>, <id2>, ...]))
MIME = {"application/x-tgsticker":"tgs", "video/webm":"webm", "image/webp":"webp"}
for i, d in enumerate(docs):
    ext = MIME.get(d.mime_type, "bin")
    await client.download_media(d, file=f"pack/{i}_{d.id}.{ext}")
```

## 2. Создать пак через @Stickers (драйв из сессии)
Флоу английский, тип выбирается **кнопкой** reply-клавиатуры (текст кнопки: `Animated emoji` /
`Video emoji` / `Static emoji`):
```
/cancel
/newemojipack
"Animated emoji"          # ← точный текст кнопки (не "Анимированные…")
"<PACK TITLE>"            # имя набора
# для каждого файла:
send_file(<.tgs>, force_document=True)  →  "<базовый эмодзи, напр. 👍>"
/publish
/skip                    # иконку можно пропустить
"<short_name>"           # → t.me/addemoji/<short_name>
```
Читай ответ @Stickers после каждого шага (`get_messages(limit=1)`, `not m.out`) — флоу хрупкий.

## 3. Забрать новые id из своего пака
```python
from telethon.tl.functions.messages import GetStickerSetRequest
from telethon.tl.types import InputStickerSetShortName
ss = await client(GetStickerSetRequest(InputStickerSetShortName(short_name="<short_name>"), hash=0))
emo_to_id = {}
for pack in ss.packs:
    for did in pack.documents:
        emo_to_id.setdefault(pack.emoticon, did)   # {"👍": <new_id>, ...}
```
Впиши новые id в `GLYPH_TO_ID` / `IC_*`. Бот может ссылаться на любой публичный кастом-эмодзи id —
пак не обязан принадлежать боту, важен только Premium у владельца.
</content>
