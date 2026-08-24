#!/bin/sh
# =====================================================================
# Entrypoint for the Telegram Video Downloader container.
#
# Usage:
#   web                       (default) -> start FastAPI web backend on :8080
#   download [chat_id] [dir]  -> run downloader.py once, then stay alive
#   list                      -> run list_chats.py (interactive login helper)
#   <anything else>           -> execute the given command as-is
#
# The scripts are run from /app/data so the session file (session.session)
# and downloaded files are written into the persistent volume.
# =====================================================================
set -e

mkdir -p /app/data/downloads
cd /app/data

case "$1" in
  download|"")
    # download [chat_id] [downloads_dir]
    if [ -n "$2" ]; then
      export CHANNEL_ID="$2"
    fi
    if [ -n "$3" ]; then
      export DOWNLOADS_DIR="$3"
    fi
    echo "==> Running Telegram Video Downloader (downloader.py)"
    echo "    chat_id: ${CHANNEL_ID:-<from .env>}"
    echo "    downloads_dir: ${DOWNLOADS_DIR:-downloads}"
    python /app/downloader.py
    echo "==> Download run finished (exit code $?)."
    echo "==> Keeping container alive. Use 'docker exec' to inspect session/data."
    echo "==> Restart the container to run the downloader again."
    while true; do
      sleep 3600
    done
    ;;
  list|chats|list-chats)
    echo "==> Listing chats (list_chats.py) - interactive login required"
    exec python /app/list_chats.py
    ;;
  web|webapp)
    echo "==> Starting Web backend (FastAPI) on :${WEB_PORT:-8080}"
    cd /app
    exec python -m uvicorn webapp:app --host 0.0.0.0 --port "${WEB_PORT:-8080}"
    ;;
  *)
    echo "==> Executing: $*"
    exec "$@"
    ;;
esac
