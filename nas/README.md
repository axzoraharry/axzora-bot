# Axzora Bot on the ASUSTOR NAS (24/7)

This is the deployment kit for running **Axzora Bot** headless on the AS6510T
(Atom C3538, x64, ADM 5.1.4). Headless mode = `src/main.ts`: the full backend
(magpie gateway + bot runtime + WeChat/Feishu/Telegram/Slack/Discord channels +
web console) with **no Electron**.

Two ways to deploy:

| Path | Branding | Effort | Needs on NAS |
|---|---|---|---|
| **A — `deploy.sh pull`** | Modelflare/Anymodel (functional ids are identical) | one command | Docker app from App Central |
| **B — `deploy.sh build`** | Axzora Bot | one command (~10-20 min) | Docker + `git` |

The functional identity is the same in both (`dev.anymodel.bot` appId,
`anymodelbot://` scheme, Modelflare login) — only the on-screen strings differ.
Path B is recommended once you want the Axzora branding on the web console.

> The phone is arm64/musl and **cannot** package the Electron desktop build
> (electron-builder needs the glibc runtime); the NAS is x64/glibc, which is the
> established build + run target. That is exactly why this kit exists.

---

## One-command deploy

On the NAS (via SSH as `admin`, then `echo <pw> | sudo -S <cmd>` for root):

```sh
# Path B — clone the rebranded repo, build the image ON the NAS, run it, install watchdog:
echo <pw> | sudo -S sh nas/deploy.sh build

# Path A — pull the upstream image and run (fastest):
echo <pw> | sudo -S sh nas/deploy.sh pull
```

Both commands finish with a console URL. The deploy script:

1. writes `$BASE/deploy.env` (config: `IMAGE`, `PORT`, `AMB_UI_TOKEN`, `FEISHU_*`) if absent,
2. creates/starts the `axzora-bot` container (`-p 3600:3600`, `amb-data` volume, `--restart unless-stopped`),
3. installs `watchdog.sh` + a per-minute cron line in `/usr/builtin/etc/crontabs/root`,
4. waits for `/amb/healthz` to answer (up to ~45 s) and prints the console URL.

### Managing it afterwards

```sh
sh nas/deploy.sh status     # running / paused / no container
sh nas/deploy.sh logs       # tail -f the container logs
sh nas/deploy.sh token      # re-print the console URL
sh nas/deploy.sh stop       # stop + write .paused (watchdog won't undo it)
sh nas/deploy.sh start      # clear .paused and start
sh nas/deploy.sh ensure     # idempotent start (what cron calls)
```

### Configuration (`$BASE/deploy.env`)

Created from a template on first run (`chmod 600`). The ones that matter:

| Var | Meaning |
|---|---|
| `IMAGE` | container image (`build` sets `axzora-bot:local`) |
| `PORT` | host port for the console (default `3600`) |
| `AMB_UI_TOKEN` | fixed console token; empty = auto-generate into `/data/ui-token` |
| `FEISHU_APP_ID` / `FEISHU_APP_SECRET` | set before first run, else edit in the console later |

Any `AMB_*` var from `.env.example` (default model, context size, language,
log level…) can go in the same file — it is passed to `docker run --env-file`.

### What Path B actually does

```sh
git clone https://github.com/axzoraharry/axzora-bot.git /volume1/axzora-bot/src
cd /volume1/axzora-bot/src && git submodule update --init --depth 1 vendor/magpie
docker build -t axzora-bot:local .
```

> Only `vendor/magpie` (Go gateway, built `CGO_ENABLED=0` in a `golang:1.27`
> stage) and the tracked `vendor/yuque-mcp` are needed for the image; the other
> submodules (`deepseek-harness`, `kimi-computer-use`) are **not** initialised,
> keeping the build context small.

---

## Connect WeChat + Feishu (once, in the web console)

1. Open the console URL the deploy script printed (`http://<NAS-IP>:3600/?token=<token>`).
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
`/usr/builtin/etc/crontabs/root` survives and runs. `deploy.sh` installs it
automatically; the line is:

```
* * * * * root /volume1/axzora-bot/watchdog.sh ensure >> /volume1/axzora-bot/watchdog.log 2>&1
```

The watchdog is identical in spirit to the bark/egoexo/hedra `ctl.sh` pattern
already on the NAS: it starts the container if it is not running, and never
undoes a deliberate stop (a `.paused` marker disables it). It reads the same
`deploy.env` / `.image` files as `deploy.sh`, so image and port always agree.

---

## First-run checklist

- [ ] Docker container running (`docker ps | grep axzora-bot`)
- [ ] Console reachable at `http://<NAS-IP>:3600/` (HTTP plain)
- [ ] WeChat QR scanned, Feishu bot connected
- [ ] Watchdog installed + a test `docker stop` recovers within a minute
- [ ] `/data` persists across container recreation (`amb-data` named volume)

## Notes / limits

- The NAS is x64/glibc; the phone is arm64/musl, so **cross-building the image
  on the phone is not supported** — use `deploy.sh build` on the NAS.
- GitHub Actions is unavailable on this account (billing lock), so there is no
  CI-published rebranded image yet — that's why Path B builds on the NAS.
- The console binds `0.0.0.0:3600` (HTTP). Expose it only on the LAN; don't port-
  forward it. If you must reach it remotely, put it behind a tunnel, not a naked
  port-forward.
