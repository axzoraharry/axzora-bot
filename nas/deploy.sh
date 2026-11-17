#!/bin/sh
# deploy.sh — headless Axzora Bot deployment for the ASUSTOR NAS (x64 glibc, ADM 5.x).
# Run ON THE NAS as root:   ssh admin@<NAS>  then  echo <pw> | sudo -S sh /path/deploy.sh build
#
# Subcommands:
#   build    Path B — clone the repo + build the REBRANDED image on the NAS, then run   (recommended)
#   pull     Path A — pull the upstream Modelflare image, then run                      (fastest)
#   up       (re)create-or-start the container from the configured image
#   ensure   idempotent start (this is what the cron watchdog calls)
#   stop     stop the container AND write .paused (ensure/watchdog won't undo it)
#   start    remove .paused and start unconditionally
#   status   one-line state report
#   logs     follow the container logs (tail -f)
#   token    print the console URL incl. token
#
# Config (all optional): "$BASE/deploy.env" is created from a template on first run.
#   IMAGE         container image  (default ghcr.io/modelflare-ai/anymodel-bot:latest)
#   PORT          host port for the web console (default 3600)
#   AMB_UI_TOKEN  fixed console token (unset = auto-generated into /data/ui-token)
#   plus any AMB_* / FEISHU_* / AMB_MAGPIE_* vars from .env.example

set -eu

# ---------------------------------------------------------------- config
CONTAINER=axzora-bot
BASE=/volume1/axzora-bot
SRC=$BASE/src
ENVFILE=$BASE/deploy.env
PAUSED=$BASE/.paused
IMAGEFILE=$BASE/.image
REPO=https://github.com/axzoraharry/axzora-bot.git

# defaults (overridable via $ENVFILE)
IMAGE=ghcr.io/modelflare-ai/anymodel-bot:latest
PORT=3600

if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  . "$ENVFILE"
fi
# an empty assignment in deploy.env must not clobber the defaults
[ -n "${IMAGE:-}" ] || IMAGE=ghcr.io/modelflare-ai/anymodel-bot:latest
[ -n "${PORT:-}" ] || PORT=3600

# ---------------------------------------------------------------- helpers
log() { echo ">> $*"; }

need_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found — install the 'Docker' app from ADM App Central first." >&2
    exit 1
  fi
}

ensure_env() {
  mkdir -p "$BASE"
  if [ -f "$ENVFILE" ]; then return 0; fi
  cat > "$ENVFILE" <<'EOF'
# Axzora Bot — deploy config. Edit then run: deploy.sh up
# IMAGE: container image to run (leave commented for the default)
#   build mode -> axzora-bot:local (set automatically by 'deploy.sh build')
#   pull mode  -> ghcr.io/modelflare-ai/anymodel-bot:latest
#IMAGE=

# PORT: host port for the web console (default 3600)
PORT=3600

# Fixed console token. Leave empty to auto-generate one into /data/ui-token.
AMB_UI_TOKEN=

# --- chat channels (set before first run; later editable in the console) ---
#FEISHU_APP_ID=cli_xxx
#FEISHU_APP_SECRET=

# --- model / language overrides (all optional) ---
#AMB_DEFAULT_MODEL=openai/gpt-5.6-sol
#AMB_CONTEXT_MESSAGES=40
#AMB_CONTEXT_CHARS=24000
#AMB_LANG=zh-CN
#AMB_LOG_LEVEL=info
EOF
  chmod 600 "$ENVFILE"
  log "wrote $ENVFILE (edit it to set FEISHU_APP_ID etc., then run: deploy.sh up)"
}

# container create-or-start (idempotent)
up_container() {
  need_docker
  ensure_env
  local runargs="-d --name $CONTAINER -p ${PORT}:3600 -v amb-data:/data --restart unless-stopped"
  [ -f "$ENVFILE" ] && runargs="$runargs --env-file $ENVFILE"

  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "container exists, starting"
    docker start "$CONTAINER" >/dev/null 2>&1 || {
      log "start failed (config changed?) — recreating"
      docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      docker run $runargs "$IMAGE"
      return
    }
  else
    log "creating container from $IMAGE"
    # shellcheck disable=SC2086
    docker run $runargs "$IMAGE"
  fi
}

health_check() {
  local i=0
  while [ "$i" -lt 45 ]; do
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true || { i=$((i+1)); sleep 1; continue; }
    if command -v curl >/dev/null 2>&1; then
      # 200 (token already ok) or 401 (up but token required) both mean "serving".
      local code
      code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT/amb/healthz" 2>/dev/null || echo 000)
      if [ "$code" = "200" ] || [ "$code" = "401" ]; then
        log "console answering (HTTP $code) on :$PORT"
        return 0
      fi
    else
      log "container running (no curl on host to probe)"
      return 0
    fi
    i=$((i+1))
    sleep 1
  done
  echo "WARN: console not answering yet — run 'deploy.sh logs' to inspect." >&2
  return 1
}

install_watchdog() {
  local self
  self=$(dirname "$0")
  install -m 0755 "$self/watchdog.sh" "$BASE/watchdog.sh"
  local cronfile=/usr/builtin/etc/crontabs/root
  if grep -Fq "$BASE/watchdog.sh ensure" "$cronfile" 2>/dev/null; then
    log "watchdog cron line already present"
  else
    echo "* * * * * root $BASE/watchdog.sh ensure >> $BASE/watchdog.log 2>&1" >> "$cronfile"
    log "watchdog cron line added"
  fi
}

show_token() {
  ensure_env
  local tok=""
  # prefer a fixed token from deploy.env, else read the auto-generated one from the data volume
  tok=$(grep -E '^[[:space:]]*AMB_UI_TOKEN=[^#]' "$ENVFILE" 2>/dev/null | sed 's/^[[:space:]]*AMB_UI_TOKEN=//' | tr -d '"' | tr -d "'" || true)
  if [ -z "$tok" ]; then
    tok=$(docker exec "$CONTAINER" cat /data/ui-token 2>/dev/null || true)
  fi
  if [ -z "$tok" ]; then
    echo "token not ready yet — run 'deploy.sh logs' (generated once the console starts)."
  else
    echo "http://<NAS-IP>:$PORT/?token=$tok"
  fi
}

# ---------------------------------------------------------------- actions
cmd="${1:-pull}"

case "$cmd" in
  build)
    need_docker
    command -v git >/dev/null 2>&1 || { echo "ERROR: git not found on NAS." >&2; exit 1; }
    ensure_env
    if [ -d "$SRC/.git" ]; then
      log "updating source at $SRC"
      git -C "$SRC" pull --ff-only || { echo "ERROR: git pull failed (local edits?)." >&2; exit 1; }
    else
      log "cloning $REPO (this is the rebranded Axzora Bot source)"
      git clone "$REPO" "$SRC"
    fi
    log "fetching magpie submodule (Go gateway binary)"
    git -C "$SRC" submodule update --init --depth 1 vendor/magpie
    IMAGE=axzora-bot:local
    log "building $IMAGE (glibc, headless, no Electron) — ~10-20 min on the Atom C3538"
    docker build -t "$IMAGE" "$SRC"
    # persist choices so the watchdog and later runs agree
    printf 'IMAGE=%s\nPORT=%s\n' "$IMAGE" "$PORT" > "$IMAGEFILE"
    log "recorded $IMAGEFILE"
    ;;
  pull)
    need_docker
    ensure_env
    # explicit image override only; default remains the upstream ghcr tag
    if [ -f "$IMAGEFILE" ]; then
      IMAGE=$(grep -E '^IMAGE=' "$IMAGEFILE" | sed 's/^IMAGE=//')
      log "using image from $IMAGEFILE: $IMAGE"
    fi
    log "pulling $IMAGE"
    docker pull "$IMAGE"
    ;;
  up)
    up_container
    ;;
  ensure)
    need_docker
    ensure_env
    [ -f "$IMAGEFILE" ] && IMAGE=$(grep -E '^IMAGE=' "$IMAGEFILE" | sed 's/^IMAGE=//')
    [ -f "$PAUSED" ] && { echo "paused, skipping"; exit 0; }
    if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
      echo "running"
    else
      echo "down -> starting"
      up_container
    fi
    ;;
  stop)
    need_docker
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    touch "$PAUSED"
    echo "stopped (paused)"
    ;;
  start)
    need_docker
    rm -f "$PAUSED"
    up_container
    ;;
  status)
    need_docker
    if [ -f "$PAUSED" ]; then echo "paused"; else
      docker inspect -f '{{.State.Status}} (running={{.State.Running}})' "$CONTAINER" 2>/dev/null || echo "no container"
    fi
    ;;
  logs)
    need_docker
    docker logs -f --tail 100 "$CONTAINER"
    ;;
  token)
    need_docker
    show_token
    ;;
  *)
    echo "usage: deploy.sh {build|pull|up|ensure|stop|start|status|logs|token}" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------- post-run (only for the "install" commands)
case "$cmd" in
  build|pull|up)
    up_container
    install_watchdog
    health_check
    echo
    echo "=============================================================="
    echo " Axzora Bot is up."
    echo " Console:   $(show_token)"
    echo " Watchdog:  $BASE/watchdog.sh (cron, every minute)"
    echo " Manage:    sh $0 {status|logs|stop|start|token}"
    echo " Next:      open the console -> Settings -> Chat channels ->"
    echo "            connect WeChat (QR) and Feishu (bot app)."
    echo "=============================================================="
    ;;
esac
