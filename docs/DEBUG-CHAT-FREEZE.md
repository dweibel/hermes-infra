# Debugging: Chat Freezes and Session Ends Immediately

**Symptom:** Typing in the Hermes chat window at `https://hermes.dirkweibel.dev/chat` freezes briefly, then the session ends. The typed message never appears and no response is shown.

**Date:** 2026-05-10

---

## Environment

- Container: `nousresearch/hermes-agent:sha-474d1e812bf3fe1a1f75b2ab06f477c631bf62c3`
- Dashboard: port 9119, accessed via Cloudflare Tunnel at `hermes.dirkweibel.dev`
- Runtime: Podman (rootless) on OCI Always Free instance
- Dashboard flags: `HERMES_DASHBOARD=1`, `HERMES_DASHBOARD_TUI=1`, `GATEWAY_ALLOW_ALL_USERS=true`

---

## What Was Tried

### 1. Added missing env vars to `enable-dashboard.sh`

**Hypothesis:** `HERMES_DASHBOARD_TUI=1` and `GATEWAY_ALLOW_ALL_USERS=true` were not being passed to the container, causing the chat tab to be disabled or sessions to be denied.

**Action:** Added `-e HERMES_DASHBOARD_TUI=1` and `-e GATEWAY_ALLOW_ALL_USERS=true` to the `podman run` command in `scripts/enable-dashboard.sh`.

**Result:** Container starts successfully. Health checks pass (HTTP 200 on `/`, `/chat`, and `/v1/models`). Chat still freezes.

**Verified:** `podman exec hermes-agent env` confirms all three flags are set in the running container.

---

### 2. Fixed `.hermes/.env` symlink → SELinux relabeling failure

**Hypothesis:** The gateway reads `.env` from `~/.hermes/.env` (resolves to `/opt/data/.hermes/.env` inside the container). A symlink pointing to a container-internal path (`/opt/data/.env`) can't be relabeled by Podman's `:Z` volume flag, causing startup failure.

**Action:** Replaced the symlink with a regular file copy (`sudo cp .env .hermes/.env`) and manually set SELinux context (`sudo chcon -R -t container_file_t`).

**Result:** Container starts without SELinux errors. Chat still freezes.

---

### 3. Fixed `auth.json` file permissions

**Hypothesis:** `/opt/data/auth.json` was owned by root (mode `0600`), causing repeated `Permission denied` errors in `hermes_cli.auth`. The gateway falls back to an empty auth store, which may prevent session creation.

**Action:** `sudo chmod 666 /mnt/workspace/hermes/auth.json` on the host.

**Result:** Auth errors stopped appearing in `errors.log` after container restart. The file is now readable inside the container. Chat still freezes.

**Verified:** Post-restart logs show no auth.json errors. Sessions start cleanly (TUI worker process spawns with correct model).

---

### 4. Verified LLM connectivity

**Hypothesis:** The chat freezes because the LLM call to OpenRouter times out or fails.

**Action:** Ran a direct `curl` to OpenRouter's chat completions endpoint from inside the container using the configured API key and model (`anthropic/claude-sonnet-4`).

**Result:** Got a valid response in ~2 seconds. LLM connectivity is fine.

---

### 5. Patched CORS `allow_origin_regex`

**Hypothesis:** The CORS middleware in `web_server.py` (line 92) only allows `localhost` and `127.0.0.1` origins. When the browser loads the page from `https://hermes.dirkweibel.dev`, API calls (XHR/fetch) from the React app are blocked by CORS, preventing the PTY session from starting.

**Action:** Patched the regex inside the running container:
```python
# Before:
allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$"
# After:
allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1|hermes\.dirkweibel\.dev)(:\d+)?$"
```

**Result:** Patch applied, container restarted, verified patch persisted. Chat still freezes.

---

## Current State After All Fixes

- Container running, all health checks pass (dashboard 200, API 200, /chat 200)
- No errors in `errors.log` or `agent.log` on session start
- TUI worker process spawns: `python3 -m tui_gateway.slash_worker --session-key ... --model anthropic/claude-sonnet-4`
- LLM calls work from inside the container
- CORS patched to allow the external domain
- `_ws_client_is_allowed()` returns True (bound to `0.0.0.0` with `--insecure`)
- Host header middleware passes (bound to `0.0.0.0` accepts any host)

---

## Architecture (for reference)

```
Browser (hermes.dirkweibel.dev)
  → Cloudflare Tunnel (HTTPS terminated at edge)
    → cloudflared on OCI instance
      → http://localhost:9119 (dashboard, uvicorn/FastAPI)

Chat flow:
1. Browser loads /chat → gets HTML with embedded session token
2. React app (ChatPage.tsx) constructs WebSocket URL:
   wss://hermes.dirkweibel.dev/api/pty?token=<session_token>&channel=<uuid>
3. Browser opens WebSocket to /api/pty
4. Server spawns PTY (hermes --tui) and bridges bytes over WebSocket
5. Browser renders ANSI output via xterm.js
```

---

## Remaining Hypotheses (Not Yet Tested)

**RESOLVED** — See root cause below.

---

## Root Cause (Confirmed 2026-05-10)

The `/opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js` file did not exist in the container. This caused `_hermes_ink_bundle_stale()` to return `True` on every WebSocket connection to `/api/pty`, triggering a full `npm run build` (~15 seconds) **synchronously on the async event loop**.

The sequence:
1. Browser opens WebSocket to `/api/pty`
2. Server calls `await ws.accept()` (queues the 101 response)
3. Server calls `_resolve_chat_argv()` → `_make_tui_argv()` → `_tui_build_needed()` → `True`
4. `subprocess.run([npm, "run", "build"])` blocks the event loop for 15+ seconds
5. The 101 response never gets flushed to the client
6. Cloudflared times out waiting for the HTTP upgrade response → reports EOF → returns 502 to browser
7. Browser sees WebSocket handshake fail → session ends

**Fix:** Pre-build the TUI and touch the output files so the staleness check passes:
```bash
podman exec hermes-agent bash -c "cd /opt/hermes/ui-tui && npm run build --prefix packages/hermes-ink && npm run build"
podman exec hermes-agent touch /opt/hermes/ui-tui/packages/hermes-ink/dist/ink-bundle.js /opt/hermes/ui-tui/dist/entry.js
```

This must be run after every container recreation (`podman rm` + `podman run`) since the container's writable layer is lost.

---

## Files Modified

| File | Change |
|------|--------|
| `hermes-infra/scripts/enable-dashboard.sh` | Added TUI/gateway env vars, symlink step, TUI health check |
| Container: `/opt/hermes/hermes_cli/web_server.py` | CORS regex patched (non-persistent across `podman rm`) |
| Host: `/mnt/workspace/hermes/auth.json` | Permissions changed to 666 |
| Host: `/mnt/workspace/hermes/.hermes/.env` | Changed from symlink to regular file copy |

---

## Next Steps to Try

1. **Check browser DevTools** — Open Network tab and Console while reproducing. Look for failed WebSocket upgrade (status != 101), CORS errors, or JS exceptions.

2. **Check npm logs** — `podman exec hermes-agent cat /opt/data/.npm/_logs/2026-05-10T19_53_37_443Z-debug-0.log` to see if the TUI Node app fails to install/build.

3. **Test WebSocket upgrade directly** — Use `websocat` or a browser extension to connect to `wss://hermes.dirkweibel.dev/api/pty?token=<token>&channel=test` and see what response comes back.

4. **Check Cloudflare Tunnel WebSocket settings** — Verify the tunnel's public hostname config has WebSocket support enabled (should be by default, but worth confirming in Zero Trust dashboard).

5. **Try accessing directly via IP:9119** — Bypass Cloudflare entirely to isolate whether the issue is tunnel-related or server-side.
