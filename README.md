# Telegram Video Downloader — Docker Image

> **All source code is bundled in this repo** (`src/`). The build no longer clones the upstream repo, so upstream changes can't break the build. Images are auto-built and pushed via GitHub Actions.

> **简体中文说明请见 [README_ZH.md](README_ZH.md).**

## Credits (Upstream Project)

The core download/list code comes from the following upstream project, thanks to the original author. It has been vendored into `src/` and enhanced:

- Upstream repo: [xyzbuddy/telegram-video-downloader](https://github.com/xyzbuddy/telegram-video-downloader)
- Original features: Telethon-based Telegram login, automatic video download from a channel/chat, cryptg fast decryption, 3-way concurrent download, realtime progress, size-budget filtering, `.env` config.

## Features

- **Fast decryption** via `cryptg` (C extension), 5–10x faster than pure Python
- **Concurrent download**: up to 3 videos in parallel (async Semaphore, avoids Telegram rate limits)
- **Realtime progress** for every download
- **Auto filtering**: only video messages from the target chat are processed
- **Size budget**: defaults to 20 GB max; supports human-readable units (`3GB` / `500MB` / `1.5MB`)
- **Auto dedup**: keeps downloaded message IDs in `downloaded_ids.txt` and skips them on later runs
- **Per-chat folders**: videos are saved under `downloads/<chat-name>/`
- **Auto monitor**: Web UI can poll a chat and automatically download newly added videos
- **Bilingual UI**: English/Chinese, auto-detected from the browser, manually switchable
- **Secure config**: credentials & session isolated via env vars / volume, never baked into the image

## Quick Start

### 1. Configure environment

```bash
cp .env.example .env
```

Fill in your Telegram credentials (get them at [my.telegram.org](https://my.telegram.org)):

```ini
API_ID=your_api_id_here
API_HASH=your_api_hash_here
```

> The download target is chosen in the Web UI (or via CLI arg), so there is no `CHANNEL_ID` in `.env`.

### 2. Get the image

**Option A: pull (recommended, after CI builds)**

```bash
docker pull ghcr.io/hanlihanshaobo/tg-video-downloader-docker:latest
```

**Option B: docker compose**

This repo ships a `docker-compose.yml` pointing at the GHCR image. Just start it:

```bash
docker compose up -d
```

### 3. First-time login & list chats

Run the chat list tool (interactive — you'll enter your phone number / code):

```bash
docker compose run --rm telegram-downloader list
```

On success the session is saved to `./data/session.session` on the host; no need to log in again. `list` prints **all chats** (channels, groups, users, bots) with their IDs.

### 4. Use the Web backend

The container starts the **Web backend** by default. Open **http://localhost:8080**:

- Lists **all chats** (channels, groups, bots, users) with IDs
- Click a row to select it, set a size limit, and hit "Start Download"
- Or "Start Monitor": set a poll interval (≥30 s); the backend keeps scanning that chat and **auto-downloads newly added videos** until you stop it
- Language follows your browser (English/Chinese); switch manually in the top-right corner
- Downloads run as background tasks in-process, sharing one session (no lock conflicts). Progress is in `docker compose logs -f telegram-downloader`

Completed videos are saved under **`./data/downloads/<chat-name>/`**; dedup records live in `./data/downloads/downloaded_ids.txt` (persisted; delete it to re-download everything).

### Common commands

| Command | Description |
| --- | --- |
| `docker compose up -d` | Start the Web backend (:8080) |
| `docker compose run --rm telegram-downloader list` | List chats (first login) |
| `docker compose logs -f telegram-downloader` | Follow download progress |
| `docker compose run --rm telegram-downloader download <chat_id> [dir]` | CLI download of a chat, optional custom output dir |
| `docker compose stop` | Stop the container |
| `docker run -it --rm --env-file .env -v "$PWD/data:/app/data" ghcr.io/hanlihanshaobo/tg-video-downloader-docker:latest list` | Pure Docker login |

## GitHub Actions (CI)

The repo ships `.github/workflows/docker-build.yml`; push triggers build → push automatically:

| Trigger | Image tags |
| --- | --- |
| push `main` / `master` | `latest`, `sha-<commit>` |
| push tag `v1.2.3` | `1.2.3`, `1.2`, `1`, `latest` |
| manual (Actions page) | `latest`, `sha-<commit>` |

- Builds **linux/amd64** + **linux/arm64** + **linux/arm/v7** (buildx + QEMU)
- Pushes to **GHCR**: `ghcr.io/hanlihanshaobo/tg-video-downloader-docker` (no extra config, uses built-in `GITHUB_TOKEN`)

### Using CI

1. Push this repo to your own GitHub repo (or fork it)
2. After the first push, confirm the workflow succeeds on the Actions page
3. Check the `Packages` page to confirm the GHCR image was created (first build defaults to private; you can make it public)
4. To release: `git tag v1.0.0 && git push origin v1.0.0`

## Security Notes

- **Never** commit `.env` or `*.session` files — they contain your Telegram credentials
- `.gitignore` and `.dockerignore` already exclude these files plus `data/` and `downloads/`
- Session & downloads persist in the `./data` volume; deleting the container keeps your data

## Disclaimer

For personal, lawful use only. Respect the content copyright and Telegram Terms of Service of any target channel; you are responsible for what you download.