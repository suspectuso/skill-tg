# Локализация RU/EN без правки call-sites

Хэндлеры продолжают писать `render(T.KEY, **kw)`. Меняем только модуль `texts`.

## texts.py — диспетчер языка
```python
import contextvars
import texts_en, texts_ru

current_lang = contextvars.ContextVar("lang", default="ru")
_MODS = {"ru": texts_ru, "en": texts_en}

def __getattr__(name):                      # module-level __getattr__ (Python 3.7+)
    mod = _MODS.get(current_lang.get(), texts_ru)
    val = getattr(mod, name, None)
    return val if val is not None else getattr(texts_ru, name)   # фолбэк на RU
```
`texts_ru.py` / `texts_en.py` — одинаковые имена констант, одинаковые `{плейсхолдеры}`.
Ключ, которого нет в EN, автоматически берётся из RU. `import texts as T; T.KEY` продолжает работать,
но отдаёт строку текущего языка (module `__getattr__` срабатывает, т.к. константы вынесены из texts.py).

## Middleware — ставит язык юзера перед каждым апдейтом
```python
@dp.update.outer_middleware()
async def lang_mw(handler, event, data):
    user = getattr(getattr(event, "message", None), "from_user", None) \
        or getattr(getattr(event, "callback_query", None), "from_user", None)
    if user:
        try: T.current_lang.set(db.get_lang(user.id) or "ru")
        except Exception: T.current_lang.set("ru")
    return await handler(event, data)
```
`T.current_lang` — реальный глобал модуля (не перехватывается `__getattr__`).

## Онбординг
- Экран выбора языка показывается ДО выбора → двуязычный (одинаков для всех), держи его только в
  texts_ru.py (EN упадёт в фолбэк).
- После выбора `db.set_lang(uid, lang)` + `T.current_lang.set(lang)` (чтобы текущий рендер уже был на новом).
- Кнопка «🌐 Язык / Language» в главном меню возвращает на экран выбора.
- Хранение: колонка `users.lang` (NULL = ещё не выбран → показать экран языка).

## Что переводить
- Тексты экранов (`texts_*`) — да, все ключи.
- Подписи кнопок в keyboards.py — если нужно, вынеси `BTN_*`-ключи и импортируй `texts` в keyboards
  (ContextVar уже стоит middleware). Имена собственные (Telegram Stars, Premium) не переводятся.
</content>
