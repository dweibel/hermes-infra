# Lessons Learned

Operational notes discovered while running Hermes.

## Gateway auth applies to the dashboard TUI

The dashboard web server (port 9119) and the embedded chat tab are separate concerns. The chat tab spawns a PTY session that goes through the gateway's user authorization layer. 

## Gateway reads `.env` from `~/.hermes/.env`, not `/opt/data/.env`

The gateway process drops privileges to the `hermes` user (HOME=`/opt/data`). It reads its `.env` from `~/.hermes/.env`, which resolves to `/opt/data/.hermes/.env` inside the container. The file at `/opt/data/.env` (the volume root) is **not** automatically found by the gateway.

```bash
# On the OCI host (persists across container recreations):
sudo mkdir -p /mnt/workspace/hermes/.hermes
sudo ln -sf /opt/data/.env /mnt/workspace/hermes/.hermes/.env
```

The symlink target uses the container-internal path (`/opt/data/.env`) because it is read from inside the container. The deploy script now creates this symlink automatically.

## `podman restart` does not re-read the env file

Environment variables passed via `--env-file` at `podman run` time are baked into the container definition. However, Hermes reads its own `.env` from the mounted volume (`/opt/data/.env`) at process startup. A `podman stop` / `podman start` cycle is sufficient for Hermes to pick up `.env` changes — no need to recreate the container.

## Dashboard does not always auto-start with the gateway

The container entrypoint checks the `HERMES_DASHBOARD` environment variable at startup. When set to `1` (or `true`/`yes`), it launches the dashboard as a background process before starting the gateway.

Since `--env-file` vars are baked into the container at `podman run` time, `HERMES_DASHBOARD=1` must be in the `.env` **before** the container is created. If added later, the container must be recreated (`podman rm` + `podman run`), not just restarted.

If the dashboard is missing after a restart and `HERMES_DASHBOARD=1` is not in the container's environment, start it manually:

```bash
podman exec -d hermes-agent /opt/hermes/.venv/bin/hermes dashboard --host 0.0.0.0 --port 9119 --insecure --tui --no-open
```


## TUI chat freezes: missing hermes-ink bundle triggers blocking build

**Symptom:** Typing in the chat at `hermes.dirkweibel.dev/chat` freezes briefly, then the session ends. No message or response is shown.

**Root cause:** The file `/opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js` does not exist in the container image. Every WebSocket connection to `/api/pty` triggers `_tui_build_needed()` → `npm run build` (~15 seconds), which runs synchronously on the async event loop. The WebSocket 101 response never gets flushed, cloudflared times out (EOF), and returns 502 to the browser.

**Fix:** Pre-build the TUI after container creation:

```bash
podman exec hermes-agent bash -c "cd /opt/hermes/ui-tui && npm run build --prefix packages/hermes-ink && npm run build"
podman exec hermes-agent touch /opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js /opt/hermes/ui-tui/dist/entry.js
```

The deploy scripts (`deploy-hermes.sh`, `enable-dashboard.sh`) now include this step automatically.

## CORS blocks API calls when accessed via Cloudflare Tunnel

The dashboard's CORS middleware (line 92 of `web_server.py`) only allows `localhost` and `127.0.0.1` origins. When accessed via `https://hermes.dirkweibel.dev`, browser fetch/XHR calls are blocked.

**Fix:** Patch the regex after container creation:

```bash
podman exec hermes-agent sed -i \
    's|allow_origin_regex=r"^https?://(localhost\|127\\.0\\.0\\.1)(:\\d+)?$"|allow_origin_regex=r"^https?://(localhost\|127\\.0\\.0\\.1\|hermes\\.dirkweibel\\.dev)(:\\d+)?$"|' \
    /opt/hermes/hermes_cli/web_server.py
podman restart hermes-agent
```

This patch lives in the container's writable layer and is lost on `podman rm`. The deploy scripts apply it automatically.

## auth.json must be writable by the hermes user

The `auth.json` file on the volume may end up root-owned (e.g., created by a prior container run with different UID mapping). The `hermes` user (UID 10000) inside the container needs read/write access. Without it, the gateway logs repeated `Permission denied` errors and falls back to an empty auth store.

**Fix:**

```bash
sudo chmod 666 /mnt/workspace/hermes/auth.json
```

## Use file copy instead of symlink for `.hermes/.env`

The deploy script originally created a symlink at `/mnt/workspace/hermes/.hermes/.env` → `/opt/data/.env` (container-internal path). Podman's `:Z` volume flag tries to relabel all files for SELinux, but cannot relabel a symlink pointing to a non-existent host path. This causes `lsetxattr: operation not permitted`.

**Fix:** Use a regular file copy instead:

```bash
sudo cp /mnt/workspace/hermes/.env /mnt/workspace/hermes/.hermes/.env
```

The `enable-dashboard.sh` script now uses `cp` instead of `ln -sf`.
