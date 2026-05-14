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

## auth.lock must be owned by the hermes user

The `auth.lock` file in `/opt/data/` can end up owned by root (created during initial container setup or a prior run). The Hermes process runs as the `hermes` user and needs write access to acquire the lock. Without it, any operation touching authentication fails with `[Errno 13] Permission denied: '/opt/data/auth.lock'`.

**Fix:**

```bash
podman exec hermes-agent chown hermes:hermes /opt/data/auth.lock /opt/data/auth.json
```

## "OCI Hermes" or "Live Hermes" means the live instance

When referring to OCI Hermes or Live Hermes, this means the running instance at `ssh oci-agent` (`/mnt/workspace/hermes/home/job-search-pipeline/`), not the `oci-infra` repository.

## Local files are not always authoritative over remote

Do not assume the local copy of a file is newer or more correct than the remote. Ask or wait to be told which direction the sync should go.

## Job-search-pipeline architecture

The job-search-pipeline is a Hermes Agent skill set with a clear separation:

- `Inputs/` — source of truth, mostly read-only (resume, preferences, experience bank, narratives)
- `Memory/` — mutable pipeline state (lead tracker, closed archive, funnel analytics)
- `.hermes/skills/` — agent behavior definitions

The experience bank uses a **progressive disclosure** pattern: a lean YAML index (~250 lines, always read for matching) paired with a narrative vault (`Inputs/narratives/*.md`, unlimited size, read only when depth is needed for document generation). This keeps agent context small during gap analysis while allowing arbitrarily rich storytelling for output generation.

## Use high reasoning models for resumes and cover letters

When generating customized resumes and cover letters, use high reasoning models. The quality of tailoring, keyword placement, and narrative selection benefits significantly from deeper inference.

## Changing models: checklist

When updating the model tiers, the following files and locations must be changed:

### 1. Tiered Model Selection Skill (live Hermes)

**Location:** `/opt/data/skills/mlops/tiered-model-selection/SKILL.md` (inside the `hermes-agent` container)

**Access:**
```bash
podman exec -i hermes-agent tee /opt/data/skills/mlops/tiered-model-selection/SKILL.md < new-skill.md
```

**What to update:**
- Model IDs in the tier table
- Cost per M tokens (input/output)
- Description frontmatter
- "When to Use Each Tier" section examples
- Any model name references in Pitfalls or other sections

### 2. Hermes config.yaml (gateway + dashboard default model)

**Local:** `hermes-infra/config/config.yaml`
**Live:** `/mnt/workspace/hermes/config.yaml` on the OCI host

**What to update:**
- `model.default` — the model used by the dashboard TUI
- `agent.model` — the model used by the gateway for agent tasks

**Deploy:**
```bash
cat config/config.yaml | ssh oci-agent 'sudo tee /mnt/workspace/hermes/config.yaml > /dev/null'
ssh oci-agent 'podman restart hermes-agent'
```

The config.yaml default should typically be set to the **Standard** tier model (the everyday workhorse). Heavy and Budget models are selected per-task by the tiered-model-selection skill or via cron job overrides.

### 3. Cron jobs with pinned models

Cron jobs pin their model at creation time. After changing tiers, audit existing cron jobs:

```bash
podman exec hermes-agent hermes cron list
```

Jobs using old model IDs will continue using them until updated. Update with:
```
/cronjob update <job-name> model: {model: "new/model-id", provider: "openrouter"}
```

### 4. SOUL.md (if it references specific models)

**Location:** `/opt/data/SOUL.md` (inside the container)

Check if the system prompt references specific model names and update if needed.

### Summary of current tiers (May 2026)

| Tier | Model | OpenRouter ID | Cost (in/out per M) |
|------|-------|---------------|---------------------|
| Budget | GPT-5.4 Nano | `openai/gpt-5.4-nano` | $0.05 / $0.40 |
| Standard | Qwen3 Coder Flash | `qwen/qwen3-coder-flash` | $0.30 / $1.50 |
| Heavy | GPT-5.4 Mini | `openai/gpt-5.4-mini` | $0.25 / $2.00 |

## File transfer to `/mnt/workspace/hermes/` requires sudo

The `/mnt/workspace/hermes/` directory is owned by UID 109999 (the container's mapped user) with mode 700. The `opc` SSH user cannot read or write to it directly — all file operations there need `sudo`.

Since `scp` cannot use `sudo`, the transfer pattern is:

1. `scp` files to `/tmp/` on the remote host
2. `ssh` with `sudo mv` (or `sudo cp`) to the final destination

Files moved with `sudo mv` retain their original owner (`opc:opc`). Always follow up with `sudo chown` to the container UID (109999) so Hermes can write to them.

```bash
# Example: transfer local files to /mnt/workspace/hermes/activity/
scp myfile.csv oci-agent:/tmp/
ssh oci-agent "sudo mkdir -p /mnt/workspace/hermes/activity && sudo mv /tmp/myfile.csv /mnt/workspace/hermes/activity/"
ssh oci-agent "sudo bash -c 'chown 109999:109999 /mnt/workspace/hermes/activity/*.csv'"
```

## Globs don't expand under `sudo` without a shell

Running `sudo chown 109999:109999 /path/*.csv` over SSH fails because `sudo` does not invoke a shell to expand the glob. Wrap the command in `sudo bash -c '...'` to ensure glob expansion happens:

```bash
# Wrong — glob not expanded:
ssh oci-agent "sudo chown 109999:109999 /mnt/workspace/hermes/activity/*.csv"

# Correct — bash expands the glob:
ssh oci-agent "sudo bash -c 'chown 109999:109999 /mnt/workspace/hermes/activity/*.csv'"
```
