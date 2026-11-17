#!/bin/sh
# watchdog.sh — keep the Axzora Bot Docker container alive on the ASUSTOR NAS.
# Run by a cron line in /usr/builtin/etc/crontabs/root (installed by deploy.sh).
#
#   watchdog.sh ensure     start the container if it is not running (idempotent)
#   watchdog.sh stop       stop the container AND write .paused so ensure won't undo it
#   watchdog.sh start      remove .paused and start unconditionally
#   watchdog.sh status     one-line state report

set -u
CONTAINER=axzora-bot
BASE=/volume1/axzora-bot
ENVFILE=$BASE/deploy.env
PAUSED=$BASE/.paused
IMAGEFILE=$BASE/.image

IMAGE=ghcr.io/modelflare-ai/anymodel-bot:latest
PORT=3600

# shared config wins (same file deploy.sh writes/reads)
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  . "$ENVFILE"
fi
# image chosen by 'deploy.sh build' outranks the env default
if [ -f "$IMAGEFILE" ]; then
  IMAGE=$(grep -E '^IMAGE=' "$IMAGEFILE" | sed 's/^IMAGE=//')
fi
# an empty assignment in deploy.env must not clobber the defaults
[ -n "${IMAGE:-}" ] || IMAGE=ghcr.io/modelflare-ai/anymodel-bot:latest
[ -n "${PORT:-}" ] || PORT=3600

run_args() {
  printf -- '-d --name %s -p %s:3600 -v amb-data:/data --restart unless-stopped' "$CONTAINER" "$PORT"
  [ -f "$ENVFILE" ] && printf ' --env-file %s' "$ENVFILE"
}

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
      || docker run $(run_args) "$IMAGE"
    echo "started"
    ;;
  ensure)
    [ -f "$PAUSED" ] && { echo "paused, skipping"; exit 0; }
    if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      echo "running"
    else
      echo "down -> starting"
      docker start "$CONTAINER" >/dev/null 2>&1 \
        || docker run $(run_args) "$IMAGE"
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
