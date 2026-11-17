# Axzora Bot on the ASUSTOR NAS (24/7)

This is the deployment kit for running **Axzora Bot** headless on the AS6510T
(Atom C3538, x64, ADM 5.1.4). Headless mode = `src/main.ts`: the full backend
(magpie gateway + bot runtime + WeChat/Feishu/Telegram/Slack/Discord channels +
web console) with **no Electron**.

Two ways to deploy:

| Path | Branding | Effort | Needs on NAS |
|---|---|---|---|
| **A — upstream image** | Modelflare/Anymodel (functional ids are identical) | one `docker run` | Docker app from App Central |
| **B — rebranded image** | Axzora Bot | build on NAS (~10-20 min) | Docker + `vendor/magpie` submodule |

The functional identity is the same in both (`dev.anymodel.bot` appId,
`anymodelbot://` scheme, Modelflare login) — only the on-screen strings differ.
Path B is recommended once you want the Axzora branding on the web console.

---

## Path A — upstream image (fastest)

On the NAS (via SSH as `admin`, then `echo <pw> | sudo -S <cmd>` for root):

```sh
# 1. Install "Docker" from ADM App Central (one-time), then:
docker run -d --name axzora-bot \
  -p 3600:3600 \
  -v amb-data:/data \
  --restart unless-stopped \
  ghcr.io/modelflare-ai/anymodel-bot:latest

# 2. Get the console token
docker exec axzora-bot cat /data/ui-token

# 3. Open the console from your phone/browser (LAN):
#    http://<NAS-IP>:3600/?token=<token>
```

## Path B — rebranded image (Axzora branding)

```sh
# on the NAS (or any x64 box with Docker):
git clone --recurse-submodules https://github.com/axzoraharry/axzora-bot.git
cd axzora-bot
docker build -t axzora-bot .
docker run -d --name axzora-bot -p 3600:3600 -v amb-data:/data --restart unless-stopped axzora-bot
docker exec axzora-bot cat /data/ui-token
```

> `git clone --recurse-submodules` is required: the magpie model gateway is a Go
> binary in `vendor/magpie` (a submodule). The Dockerfile builds it with
> `CGO_ENABLED=0` in a `golang:1.27` stage, so no Go toolchain is needed on the
> host — only Docker.

---

## Connect WeChat + Feishu (once, in the web console)

1. Open `http://<NAS-IP>:3600/?token=<token>`.
2. **Settings → Chat channels**:
   - **WeChat**: click connect → a QR code appears → scan it with the WeChat
     account you want the bot to answer to. (WeChat = iLink, carries images/files.)
   - **Feishu**: create a Feishu app with bot capability → paste its credentials
     → the bot appears with streaming reply cards.
3. The first person to message the bot after connecting becomes its **owner**;
   everyone else gets a one-line notice and no model call until allowed.

---

## Keep it alive (ADM has no systemd)

ADM's crond is BusyBox and ignores `@reboot`, but a plain line in
`/usr/builtin/etc/crontabs/root` survives and runs. Install the watchdog:

```sh
# as root (echo <pw> | sudo -S ...):
install -m 0755 nas/watchdog.sh /volume1/axzora-bot/watchdog.sh
echo '* * * * * root /volume1/axzora-bot/watchdog.sh ensure >> /volume1/axzora-bot/watchdog.log 2>&1' \
  >> /usr/builtin/etc/crontabs/root
```

The watchdog (below) is identical in spirit to the bark/egoexo/hedra ctl.sh
pattern already on the NAS: it starts the container if it's not running, and
never undoes a deliberate stop (a `.paused` marker disables it).

---

## First-run checklist

- [ ] Docker container running (`docker ps | grep axzora-bot`)
- [ ] Console reachable at `http://<NAS-IP>:3600/` (self-signed? no — HTTP plain)
- [ ] WeChat QR scanned, Feishu bot connected
- [ ] Watchdog installed + a test `docker stop` recovers within a minute
- [ ] `/data` volume persists across container recreation (`amb-data` named volume)

## Notes / limits

- The NAS is x64; the phone is arm64, so **cross-building the rebranded image on
  the phone is not supported** — build on the NAS (Path B) or use Path A.
- GitHub Actions is unavailable on this account (billing lock), so there is no
  CI-published rebranded image yet — that's why Path B builds on the NAS.
- The console binds `0.0.0.0:3600` (HTTP). Expose it only on the LAN; don't port-
  forward it. If you must reach it remotely, put it behind a tunnel, not a naked
  port-forward.
