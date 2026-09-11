# Media handling + deploy hazards

## Contents
- file_id caching — the mandatory pattern
- Rich slideshow needs file_ids
- macOS `tar` and the AppleDouble trap
- Video compression under the 50 MB limit
- `rsync` deploy — the `.env` obliteration
- SSH heredocs, escape hell, and the fix
- Two bot processes, one token = intermittent style loss
- Fresh MTProto session vs. long-lived bot session
- Reboot / systemd checklist for the bot

Traps that don't fit anywhere else but ruin a deploy each. Read once, remember forever.

## file_id caching — the mandatory pattern

Bot API caps a `sendPhoto`/`sendVideo` upload at **50 MB per file** and re-uploading the same
asset on every send is slow and wastes bandwidth. Cache the `file_id` returned by Telegram the
first time you send an asset, keep it in DB / KV, always send by `file_id` after.

```sql
-- key = "fileid:content/media/rooms/standard/01.jpg"
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Warm-up procedure (one-shot after adding new media):

1. For each asset path P: upload as a real message to the bot's own chat with the owner.
2. Read `message.photo[-1].file_id` (largest photo size) or `message.video.file_id`.
3. `INSERT INTO meta VALUES ('fileid:' || P, file_id, now()) ON CONFLICT (key) DO UPDATE …`.
4. `deleteMessage` — don't leave warm-up spam in the chat.

Send path:

```python
file_id = db.meta_get(f"fileid:{rel_path}")
if file_id:
    await bot.send_photo(chat_id, file_id, caption=cap)
else:
    # first send this session → save, then reuse
    msg = await bot.send_photo(chat_id, FSInputFile(local_path), caption=cap)
    db.meta_set(f"fileid:{rel_path}", msg.photo[-1].file_id)
```

`file_id` is bot-scoped and stable — same value works across all chats for the same bot.
When you switch tokens, the cache is invalid; clear the `fileid:*` keys.

## Rich slideshow needs file_ids

`RichBlockPhoto` accepts `media: <file_id | url>` only. In production always use `file_id`
(instant, no repeat upload). URL uploads work as fallback but re-fetch every send. Prime a
whole directory with a one-shot warm-up script before shipping a new content pack.

## macOS `tar` and the AppleDouble trap

macOS `tar` bundles resource-fork sidecar files `._<name>` into the archive when packing from a
Mac filesystem. The bot's build/deploy pipeline extracts them next to your media, then the
uploader picks up the sidecars — Telegram rejects them with `IMAGE_PROCESS_FAILED`.

**Before every `tar -czf` from a Mac:**

```bash
find content/media -name '._*' -delete
COPYFILE_DISABLE=1 tar -czf pack.tgz content/media/
```

Or `--exclude='._*'` at pack time. Verify: `tar -tzf pack.tgz | grep '^\._' | head` should be
empty.

## Video compression under the 50 MB limit

Media taken from a phone / a site can be huge. ffmpeg one-liner that's small enough for the API
and still looks fine:

```bash
ffmpeg -i in.mp4 -c:v libx264 -preset veryfast -crf 28 \
  -vf "scale='min(1280,iw)':-2" -c:a aac -b:a 96k -movflags +faststart out.mp4
```

- `crf 28` around 5–8 MB per minute of 720p footage — usually under 50 MB.
- `scale='min(1280,iw)':-2` — only scale down, never up; preserves aspect (evens the height).
- `+faststart` — moves moov atom to the front so Telegram can preview without buffering.

Run this on the server side of the deploy (`docker exec` or ssh + ffmpeg) so you don't ship
compressed twice.

## `rsync` deploy — the `.env` obliteration

Deploying a Go bot from `bot-go/` to a server via `rsync -a` without an `.env` exclude
**overwrites the production `.env` with your local dev `.env`** on the next push. Production
secrets that only live on the server (SMTP passwords, `WEB_LINK_SECRET`, per-env feature flags)
vanish. If the container has already been recreated, you cannot recover them from a running
image.

**The only safe form:**

```bash
rsync -az --delete \
  --exclude '.env' \
  --exclude 'data/' \
  --exclude '.git' \
  bot-go/  server:~/app/bot-go/
```

Belt-and-braces: back up the remote `.env` before the sync.

```bash
ssh server 'cp ~/app/bot-go/.env ~/app/bot-go/.env.bak.$(date +%s)'
rsync … as above …
ssh server 'diff -u ~/app/bot-go/.env.bak.* ~/app/bot-go/.env || true'   # should be identical
```

Prefer `git pull` on the server if the repo is cloned there — it never touches `.env` because
`.env` is in `.gitignore`. Some servers can't reach GitLab; in that case rsync stays, with the
excludes.

## SSH heredocs, escape hell, and the fix

Passing a Python or shell driver through `ssh 'host' << 'EOF' … EOF` corrupts backticks,
`$vars`, and quote-nesting more often than not. Two failure modes seen in the wild:

- zsh globbing on the local side eats a `*.py` before ssh sees it.
- The remote shell interprets `\n` differently than the local heredoc.

**Fix:** always write the driver to a temp file locally, `scp` it, run it as a file.

```bash
cat > /tmp/drive.py <<'PY'
… any code, no escape worry …
PY
scp /tmp/drive.py server:/tmp/
ssh server '~/app/venv/bin/python /tmp/drive.py'
```

For an even more robust setup, keep drivers as committed files in the repo and just `ssh server
'cd /path && ./venv/bin/python scripts/drive_something.py'`.

## Two bot processes, one token = intermittent style loss

If a rogue `nohup ./bot &` from a debugging session outlives your systemd unit, both processes
race for `getUpdates` and Telegram round-robins updates between them. Symptoms:

- Some button clicks fire, others silently drop.
- Coloured buttons occasionally render as plain-white (because the losing process's
  `editMessageReplyMarkup` never lands).
- Long-poller timeouts look normal in logs.

Grep and kill before you deploy: `ps auxf | grep bot | grep -v systemd`. Only the systemd
process should be alive.

## Fresh MTProto session vs. long-lived bot session

- **Bot session** = the bot's own `getUpdates` state; there's no session file, so nothing to
  guard.
- **User session (Telethon)** = a `.session` SQLite file. **One process per session file** —
  a second process crashes with `AUTH_KEY_DUPLICATED` and the running process gets `database is
  locked` from the SQLite side. Before running any driver, stop competing services:

```bash
systemctl is-active <session-consuming-svc>...   # check first!
systemctl stop      <session-consuming-svc>...   # frees the .session
# work…
systemctl start     <session-consuming-svc>...   # ONLY if they were active before you stopped them
```

## Reboot / systemd checklist for the bot

- Unit file with `Restart=always`, `RestartSec=5`.
- `EnvironmentFile=/root/app/.env` — never inline secrets in the unit file.
- `journalctl -u <svc> -n 40 --no-pager` for post-deploy verification.
- On red-flag logs (`getUpdates` 5xx loop, `MIGRATE_TO_DC` on user sessions), stop retrying and
  fix the root cause; long back-off just extends the outage.
