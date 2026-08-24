# =====================================================================
# Telegram Video Downloader - Web Backend (FastAPI)
# =====================================================================
# 单容器部署：Web 后台即主入口（端口 8080）。
#   - 查询全部会话（含机器人、用户）及 ID
#   - 点击会话触发下载
#   - 下载在本进程内后台执行，与查询共用同一个 Telethon client，
#     通过 asyncio 锁串行化，避免 session SQLite 锁冲突。
# 复用 downloader.py 的扫描 / 去重 / 并发下载逻辑。
# =====================================================================

import asyncio
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from telethon import TelegramClient
from telethon.tl.types import Channel, Chat, User

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
DOWNLOADS_DIR = os.getenv("DOWNLOADS_DIR", "downloads")

load_dotenv(override=True)

api_id_raw = os.getenv("API_ID")
api_hash = os.getenv("API_HASH")

# ---------------------------------------------------------------------
# Global single client + serialization lock
# ---------------------------------------------------------------------
_client = None
_client_lock = asyncio.Lock()  # serializes dialogs query vs download
_download_lock = asyncio.Lock()  # one download at a time
_download_state = {"running": False, "chat_id": None, "detail": ""}


class DownloadRequest(BaseModel):
    chat_id: int
    max_total_size: str | int | None = None


SIZE_UNITS = {"KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}


def parse_size(raw) -> int | None:
    """Parse a size that is either plain bytes (int) or a human unit like '3GB'/'1.5MB'."""
    if raw is None:
        return None
    s = str(raw).strip().upper()
    if not s:
        return None
    m = re.match(r"^([\d.]+)\s*(KB|MB|GB|TB)?$", s)
    if not m:
        return None
    val = float(m.group(1))
    mult = SIZE_UNITS[m.group(2)] if m.group(2) else 1
    return int(val * mult)


def validate_credentials() -> str | None:
    if not api_id_raw or not api_hash or api_hash == "your_api_hash_here":
        return "API_ID / API_HASH 未配置或仍是占位值，请先在 .env 中填写。"
    try:
        int(api_id_raw)
    except ValueError:
        return f"API_ID 必须是整数，当前为: '{api_id_raw}'"
    return None


def get_client() -> TelegramClient:
    global _client
    if _client is None:
        _client = TelegramClient(str(DATA_DIR / "session"), int(api_id_raw), api_hash)
    return _client


async def ensure_logged_in(client: TelegramClient):
    await client.connect()
    if not await client.is_user_authorized():
        raise HTTPException(
            status_code=401,
            detail="未登录。请先在容器内运行 `list` 命令完成首次登录。",
        )


# ---------------------------------------------------------------------
# Download logic (mirrors downloader.py, runs in-process)
# ---------------------------------------------------------------------

DOWNLOAD_SEMAPHORE = asyncio.Semaphore(3)
DOWNLOAD_LIMIT = 20 * 1024 * 1024 * 1024


def clean_filename(name: str) -> str:
    cleaned = re.sub(r'[\\/*?:"<>|]', "", name)
    return re.sub(r"\s+", " ", cleaned).strip()


def load_downloaded_ids() -> set:
    path = Path(DATA_DIR) / DOWNLOADS_DIR / "downloaded_ids.txt"
    ids = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.isdigit():
                ids.add(int(line))
    return ids


def record_downloaded_id(message_id: int):
    path = Path(DATA_DIR) / DOWNLOADS_DIR / "downloaded_ids.txt"
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{message_id}\n")
    except OSError:
        pass


def make_progress_cb(message_id, video_name, size_mb):
    last = {"pct": -5}

    def cb(received, total):
        if not total:
            return
        pct = int((received / total) * 100)
        if pct - last["pct"] >= 10 or pct == 100:
            last["pct"] = pct
            print(f"  -> [Video ID {message_id}] {video_name} ({size_mb:.1f} MB) - {pct}% downloaded")

    return cb


async def download_worker(message, index, total_count) -> bool:
    file_size = getattr(message.file, "size", 0)
    size_mb = file_size / (1024 * 1024)

    video_name = ""
    if message.text:
        first_line = message.text.split("\n")[0].strip()
        if first_line:
            video_name = clean_filename(first_line)[:50]
    if not video_name and getattr(message.file, "name", None):
        video_name = clean_filename(message.file.name)
    if not video_name:
        video_name = f"video_{message.date.strftime('%Y%m%d_%H%M%S')}"

    ext = getattr(message.file, "ext", ".mp4")
    if not ext.startswith("."):
        ext = f".{ext}"
    if not video_name.lower().endswith(ext.lower()):
        video_name = f"{video_name}{ext}"

    async with DOWNLOAD_SEMAPHORE:
        print(f"\n[Queue {index}/{total_count}] Starting: {video_name} (ID: {message.id})")
        try:
            output_path = os.path.join(DATA_DIR, DOWNLOADS_DIR, video_name)
            await message.download_media(file=output_path, progress_callback=make_progress_cb(message.id, video_name, size_mb))
            print(f"✓ [Finished] Video ID: {message.id} ({video_name})")
            record_downloaded_id(message.id)
            return True
        except Exception as e:
            print(f"✗ [Failed] Video ID: {message.id} ({video_name}). Error: {e}")
            return False


async def run_download(chat_id: int, max_total_size: int):
    client = get_client()
    await client.connect()

    downloads_path = Path(DATA_DIR) / DOWNLOADS_DIR
    downloads_path.mkdir(parents=True, exist_ok=True)
    downloaded_ids = load_downloaded_ids()

    max_size = max_total_size or DOWNLOAD_LIMIT

    _download_state["chat_id"] = chat_id
    _download_state["detail"] = f"正在连接会话 {chat_id} ..."

    try:
        entity = await client.get_entity(chat_id)
    except Exception as e:
        _download_state["detail"] = f"会话 {chat_id} 连接失败: {e}"
        print(f"[ERROR] Failed to connect/locate channel {chat_id}: {e}")
        return

    queue = []
    scanned = 0
    limit_reached = False
    async for message in client.iter_messages(entity, reverse=True):
        if not message.video:
            continue
        if message.id in downloaded_ids:
            continue
        file_size = getattr(message.file, "size", 0)
        if scanned + file_size > max_size:
            limit_reached = True
            break
        queue.append(message)
        scanned += file_size

    total = len(queue)
    _download_state["detail"] = f"扫描完成，找到 {total} 个待下载视频"
    if limit_reached:
        print("Note: size budget reached during scan.")

    if total == 0:
        _download_state["detail"] = "没有需要下载的视频"
        return

    tasks = [download_worker(m, idx + 1, total) for idx, m in enumerate(queue)]
    results = await asyncio.gather(*tasks)
    success = sum(1 for r in results if r)
    _download_state["detail"] = f"下载完成：成功 {success} / {total}，失败 {total - success}"
    print(f"\nDownload summary: {success}/{total} succeeded.")


# ---------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------

app = FastAPI(title="Telegram Video Downloader", docs_url=None, redoc_url=None)


@app.get("/")
async def index():
    return FileResponse(BASE_DIR / "web" / "index.html")


@app.get("/api/dialogs")
async def list_dialogs():
    err = validate_credentials()
    if err:
        raise HTTPException(status_code=400, detail=err)

    client = get_client()
    async with _client_lock:
        await ensure_logged_in(client)
        dialogs = []
        async for dialog in client.iter_dialogs():
            entity = dialog.entity
            name = (dialog.name or "Unknown Name").replace("\n", " ").strip()
            if isinstance(entity, Channel):
                chat_type = "Channel" if entity.broadcast else "MegaGroup"
            elif isinstance(entity, Chat):
                chat_type = "Group"
            elif isinstance(entity, User):
                chat_type = "Bot" if entity.bot else "User"
            else:
                chat_type = type(entity).__name__
            dialogs.append(
                {
                    "id": dialog.id,
                    "name": name,
                    "type": chat_type,
                    "unread": dialog.unread_count,
                }
            )

    dialogs.sort(key=lambda d: d["name"].lower())
    return {"dialogs": dialogs}


@app.post("/api/download")
async def start_download(req: DownloadRequest):
    err = validate_credentials()
    if err:
        raise HTTPException(status_code=400, detail=err)

    if _download_state["running"]:
        raise HTTPException(status_code=409, detail=f"已有下载任务进行中: {_download_state['chat_id']}")

    max_size = parse_size(req.max_total_size)
    if req.max_total_size is not None and max_size is None:
        raise HTTPException(status_code=400, detail=f"无法解析大小上限: '{req.max_total_size}'")

    _download_state["running"] = True
    _download_state["chat_id"] = req.chat_id
    _download_state["detail"] = "任务已加入队列"

    async def _task():
        try:
            async with _client_lock, _download_lock:
                await run_download(req.chat_id, max_size or 0)
        except Exception as e:
            _download_state["detail"] = f"下载出错: {e}"
            print(f"[ERROR] Download task failed: {e}")
        finally:
            _download_state["running"] = False

    asyncio.create_task(_task())
    return {
        "started": True,
        "chat_id": req.chat_id,
        "note": f"已开始下载会话 {req.chat_id}，进度见容器日志。",
    }


@app.get("/api/status")
async def download_status():
    return {
        "running": _download_state["running"],
        "chat_id": _download_state["chat_id"],
        "detail": _download_state["detail"],
    }


app.mount("/static", StaticFiles(directory=str(BASE_DIR / "web")), name="static")