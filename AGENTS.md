# Hermes

Autonomous AI agent that communicates via email and an OpenAI-compatible API, running on OCI with Cloudflare for email routing. Serves as the strategic orchestrator for **The Foundry** — routing tasks, maintaining memory, and deriving lessons.

## Ecosystem Context

See `foundry-core/docs/ECOSYSTEM.md` for the full system architecture and component relationships.

## Key Facts

- **Interfaces:** Email (Cloudflare routing), OpenAI-compatible API
- **Deploy target:** OCI ARM64 container
- **Delegates to:** Forge (for coding task execution)

> **Note:** Onyx (web chat UI) is planned but not installed.

## Documentation

- [docs/Hermes-Forge Orchestration.md](docs/Hermes-Forge%20Orchestration.md) — task delegation to Forge
- [docs/PHASE-A-DEPLOYMENT.md](docs/PHASE-A-DEPLOYMENT.md) — deployment guide
- [docs/Hermes Agent on OCI.md](docs/Hermes%20Agent%20on%20OCI.md) — full architecture (pipelines, security)
- [docs/Hermes and Onyx.md](docs/Hermes%20and%20Onyx.md) — future chat UI integration
- [docs/RUNTIME-ENVIRONMENT.md](docs/RUNTIME-ENVIRONMENT.md) — compute, container, ports, DNS, LLM
- [docs/LOGGING-IN.md](docs/LOGGING-IN.md) — SSH access, container management, remote API usage
- [docs/LESSONS.md](docs/LESSONS.md) — operational gotchas

> **Note:** Use browser-based testing whenever possible to validate system behavior.
