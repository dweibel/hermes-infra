# AGENTS.md

Hermes is an autonomous AI agent that communicates via email and an OpenAI-compatible API, running on OCI with Cloudflare for email routing.

## Documentation

- [Phase A Deployment Guide](docs/PHASE-A-DEPLOYMENT.md) — step-by-step deployment of the Hermes container
- [Hermes Agent on OCI](docs/Hermes%20Agent%20on%20OCI.md) — full architecture overview (inbound/outbound pipelines, security)
- [Hermes and Onyx](docs/Hermes%20and%20Onyx.md) — future Onyx Lite chat UI integration
- [Lessons Learned](docs/LESSONS.md) — operational gotchas discovered while running Hermes

> **Note:** Onyx is not installed. It is planned as a future enhancement to provide a web-based chat UI for Hermes.

See the dedicated documents for operational details:

- [Runtime Environment](docs/RUNTIME-ENVIRONMENT.md) — compute, container, ports, DNS, and LLM details
- [Logging In](docs/LOGGING-IN.md) — SSH access, container management, and remote API usage.  Read when you need to log into the remote OCI server.

> **Note:** Use browser-based testing whenever possible to validate system behavior.
