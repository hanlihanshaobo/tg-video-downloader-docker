# =====================================================================
# Telegram Video Downloader - Web Backend (FastAPI)
# =====================================================================
# 提供一个轻量 Web 后台：
#   - 查询你的全部会话（含机器人、用户）及 ID
#   - 点击会话触发下载
#
# 复用 /app/data 下的 session（与 downloader.py / list_chats.py 相同），
# 下载通过子进程运行 downloader.py 完成，从而完全复用其去重逻辑。
# =====================================================================

import os
import sys
import subprocess
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

load_dotenv(override=True)

api_id_raw = os.getenv("API_ID")
api_hash = os.getenv("API_HASH")


class DownloadRequest(BaseModel):
    chat_id: int
    max_total_size: int | None = None


def validate_credentials() -> str | None:
    if not api_id_raw or not api_hash or api_hash == "your_api_hash_here":
        return "API_ID / API_HASH 未配置或仍是占位值，请先在 .env 中填写。"
    try:
        int(api_id_raw)
    except ValueError:
        return f"API_ID 必须是整数，当前为: '{api_id_raw}'"
    return None


app = FastAPI(title="Telegram Video Downloader", docs_url=None, redoc_url=None)


def get_client():
    return TelegramClient(str(DATA_DIR / "session"), int(api_id_raw), api_hash)


@app.get("/")
async def index():
    return FileResponse(BASE_DIR / "web" / "index.html")


@app.get("/api/dialogs")
async def list_dialogs():
    err = validate_credentials()
    if err:
        raise HTTPException(status_code=400, detail=err)

    dialogs = []
    client = get_client()
    try:
        await client.connect()
        if not await client.is_user_authorized():
            raise HTTPException(
                status_code=401,
                detail="未登录。请先在容器内运行 `list` 命令完成首次登录。",
            )
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
    finally:
        await client.disconnect()

    dialogs.sort(key=lambda d: d["name"].lower())
    return {"dialogs": dialogs}


@app.post("/api/download")
async def start_download(req: DownloadRequest):
    err = validate_credentials()
    if err:
        raise HTTPException(status_code=400, detail=err)

    if not (DATA_DIR / "session.session").exists():
        raise HTTPException(
            status_code=401,
            detail="未登录。请先在容器内运行 `list` 命令完成首次登录。",
        )

    env = os.environ.copy()
    env["CHANNEL_ID"] = str(req.chat_id)
    if req.max_total_size:
        env["MAX_TOTAL_SIZE"] = str(req.max_total_size)

    os.makedirs(DATA_DIR / "downloads", exist_ok=True)
    proc = subprocess.Popen(
        [sys.executable, str(BASE_DIR / "downloader.py")],
        cwd=str(DATA_DIR),
        env=env,
    )
    return {
        "started": True,
        "pid": proc.pid,
        "chat_id": req.chat_id,
        "note": "下载已在后台开始，可通过容器日志查看进度。",
    }


app.mount("/static", StaticFiles(directory=str(BASE_DIR / "web")), name="static")
