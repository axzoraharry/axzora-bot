#!/bin/sh
# deploy.sh — run ON THE NAS to install Axzora Bot (Docker) end to end.
# Usage:  ssh admin@<NAS>  then  echo <pw> | sudo -S sh /path/deploy.sh
#
# Does:  checks docker, pulls the image, runs the container, prints the ui-token,
#        installs the watchdog + cron line so it stays alive across reboots.

set -eu
CONTAINER=axzora-bot
IMAGE=ghcr.io/modelflare-ai/anymodel-bot:latest
BASE=/volume1/axzora-bot

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found — install the 'Docker' app from ADM App Central first." >&2
  exit 1
fi

mkdir -p "$BASE"

# Optional: use a locally-built rebranded image instead.
if [ -n "${USE_IMAGE:-}" ]; then
  IMAGE="$USE_IMAGE"
  echo "$IMAGE" > "$BASE/.image"
fi

echo ">> pulling $IMAGE ..."
docker pull "$IMAGE"

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo ">> container exists, (re)starting"
  docker start "$CONTAINER" >/dev/null 2>&1 || true
else
  echo ">> creating container"
  docker run -d --name "$CONTAINER" \
    -p 3600:3600 \
    -v amb-data:/data \
    --restart unless-stopped \
    "$IMAGE"
fi

echo ">> installing watchdog"
install -m 0755 "$(dirname "$0")/watchdog.sh" "$BASE/watchdog.sh"
CRONLINE="* * * * * root $BASE/watchdog.sh ensure >> $BASE/watchdog.log 2>&1"
if ! grep -Fq "$BASE/watchdog.sh ensure" /usr/builtin/etc/crontabs/root 2>/dev/null; then
  echo "$CRONLINE" >> /usr/builtin/etc/crontabs/root
  echo ">> cron line added"
else
  echo ">> cron line already present"
fi

sleep 1
TOKEN=$(docker exec "$CONTAINER" cat /data/ui-token 2>/dev/null || echo "<see container logs>")
echo
echo "=============================================================="
echo " Axzora Bot is running."
echo " Console:   http://<NAS-IP>:3600/?token=$TOKEN"
echo " Watchdog:  $BASE/watchdog.sh (cron, every minute)"
echo " Next:      open the console -> Settings -> Chat channels ->"
echo "            connect WeChat (QR) and Feishu (bot app)."
echo "=============================================================="
