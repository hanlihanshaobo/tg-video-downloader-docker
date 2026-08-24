#!/bin/sh
# =====================================================================
# Entrypoint for the Telegram Video Downloader container.
#
# Usage:
#   download   (default)  -> run downloader.py
#   list                  -> run list_chats.py (interactive login helper)
#   <anything else>       -> execute the given command as-is
#
# The scripts are run from /app/data so the session file (session.session)
# and downloaded files are written into the persistent volume.
# =====================================================================
set -e

mkdir -p /app/data/downloads
cd /app/data

case "$1" in
  download|"")
    echo "==> Running Telegram Video Downloader (downloader.py)"
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
