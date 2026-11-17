#!/bin/sh
# watchdog.sh — keep the Axzora Bot Docker container alive on the ASUSTOR NAS.
# Run by a cron line in /usr/builtin/etc/crontabs/root (see nas/README.md).
#
#   watchdog.sh ensure     start the container if it is not running (idempotent)
#   watchdog.sh stop       stop the container AND write .paused so ensure won't undo it
#   watchdog.sh start      remove .paused and start unconditionally
#   watchdog.sh status     one-line state report

set -u
CONTAINER=axzora-bot
IMAGE=ghcr.io/modelflare-ai/anymodel-bot:latest
# override the image for the rebranded build:
[ -f /volume1/axzora-bot/.image ] && IMAGE=$(cat /volume1/axzora-bot/.image)
PAUSED=/volume1/axzora-bot/.paused

action="${1:-ensure}"

case "$action" in
  stop)
    docker stop "$CONTAINER" >/dev/null 2>&1
    touch "$PAUSED"
    echo "stopped (paused)"
    ;;
  start)
    rm -f "$PAUSED"
    docker start "$CONTAINER" >/dev/null 2>&1 \
      || docker run -d --name "$CONTAINER" -p 3600:3600 -v amb-data:/data --restart unless-stopped "$IMAGE"
    echo "started"
    ;;
  ensure)
    [ -f "$PAUSED" ] && { echo "paused, skipping"; exit 0; }
    if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      echo "running"
    else
      echo "down -> starting"
      docker start "$CONTAINER" >/dev/null 2>&1 \
        || docker run -d --name "$CONTAINER" -p 3600:3600 -v amb-data:/data --restart unless-stopped "$IMAGE"
    fi
    ;;
  status)
    if [ -f "$PAUSED" ]; then echo "paused"; else
      docker inspect -f '{{.State.Status}} (running={{.State.Running}})' "$CONTAINER" 2>/dev/null || echo "no container"
    fi
    ;;
  *)
    echo "usage: watchdog.sh {ensure|start|stop|status}" >&2
    exit 2
    ;;
esac
