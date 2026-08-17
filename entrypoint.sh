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
    exec python /app/downloader.py
    ;;
  list|chats|list-chats)
    echo "==> Listing chats (list_chats.py) - interactive login required"
    exec python /app/list_chats.py
    ;;
  *)
    echo "==> Executing: $*"
    exec "$@"
    ;;
esac
