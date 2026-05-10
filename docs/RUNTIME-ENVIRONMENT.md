# Runtime Environment

| Component | Detail |
|-----------|--------|
| Compute | Oracle Cloud Infrastructure (OCI) — Always Free tier |
| Container runtime | Podman |
| Container image | `nousresearch/hermes-agent` (pinned by SHA) |
| Data directory | `/mnt/workspace/hermes/` on attached block volume |
| Ports | 8081 (API), 8082 (webhook gateway), 9119 (web UI) |
| DNS/Tunnel | Cloudflare Tunnel routes `hermes-api.dirkweibel.dev` → localhost:8081 |
| LLM | Qwen 3.5-122B via OpenRouter |
