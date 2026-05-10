# Phase A Deployment Guide

Steps to deploy Hermes on the OCI instance using native chat.

> **Note:** Onyx Lite is installed but not configured. It is planned as a future enhancement. See [Hermes and Onyx.md](Hermes%20and%20Onyx.md) for details when ready to enable.

## Prerequisites

- SSH access to the OCI instance (`ssh oci-agent`)
- Hermes container image available (set `HERMES_IMAGE` env var if not using default)
- Cloudflare tunnel already running on the instance

## Deployment Steps

### 1. Create Hermes data directory

```bash
ssh oci-agent 'bash -s' < scripts/setup-hermes-dirs.sh
```

Creates `/mnt/workspace/hermes/` and `/mnt/workspace/hermes/data/` on the block volume.

### 2. Populate secrets

```bash
scp config/.env.example oci-agent:/mnt/workspace/hermes/.env
ssh oci-agent "nano /mnt/workspace/hermes/.env"
```

Fill in at minimum:
- `OPENROUTER_API_KEY` — shared with Goose (from https://openrouter.ai/keys)
- `HERMES_API_KEY` — required for Phase A
- `WEBHOOK_PASSPHRASE`, `CF_API_TOKEN`, `CF_ACCOUNT_ID` — optional now, required for Phase B

### 3. Deploy configuration

```bash
scp config/config.yaml oci-agent:/mnt/workspace/hermes/config.yaml
```

### 4. Start the Hermes container

```bash
ssh oci-agent 'bash -s' < scripts/deploy-hermes.sh
```

Pulls the image and starts the container with ports 8081 and 8082 mapped.

### 5. *(Future)* Start Onyx Lite

> **Skipped for now.** Hermes is running with native chat. Onyx Lite will be configured as a future enhancement.

```bash
ssh oci-agent 'bash -s' < scripts/deploy-onyx-lite.sh
```

Starts the Onyx Lite stack on port 3080 with the lite override (no Vespa/Redis).

### 6. Configure Cloudflare Tunnel routes

Routes are managed in the **Cloudflare Zero Trust dashboard** (the tunnel uses a token-based configuration with no local config file).

1. Open the Cloudflare Zero Trust dashboard: **Networks → Tunnels → your tunnel → Public Hostname**
2. Add the following public hostname entries:

| Public Hostname | Origin | Status |
|-----------------|--------|--------|
| `hermes.dirkweibel.dev` | `http://localhost:9119` | Active — Dashboard/Chat |
| `hermes-api.dirkweibel.dev` | `http://localhost:8081` | Active |

Cloudflared runs as a systemd service on the OCI instance. Verify it is active:

```bash
ssh oci-agent "systemctl status cloudflared"
```

### 7. Wait for DNS propagation

The CNAME records for `hermes` and `hermes-api` subdomains need to resolve. This typically takes a few minutes but can take up to an hour.

```bash
# Check propagation
dig hermes.dirkweibel.dev CNAME +short
dig hermes-api.dirkweibel.dev CNAME +short
```

## Validation

Once everything is live, run the Phase A smoke tests:

```bash
export HERMES_DOMAIN="dirkweibel.dev"
ssh oci-agent 'bash -s' < scripts/test-phase-a.sh
```

If all tests pass, Phase A is complete (Task 5 satisfied) and you can proceed to Phase B.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| DNS not resolving | Wait for propagation, verify CNAME in CF dashboard |
| 502 Bad Gateway | `ssh oci-agent "systemctl status cloudflared"` — verify service is active, then check containers with `podman ps` |
| Hermes API 401 | API key mismatch between `.env` files |
| Onyx can't reach Hermes *(future)* | Verify Podman bridge: `ssh oci-agent "curl http://10.88.0.1:8081/v1/models"` |
| cloudflared not running | `ssh oci-agent "systemctl status cloudflared"` and `ssh oci-agent "journalctl -u cloudflared --no-pager -n 20"` |
