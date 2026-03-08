# NanoClaw Golden Image Integration

Analysis and integration plan for deploying NanoClaw as part of the EV golden image on k3s edge hardware.

## Architecture Analysis

### What NanoClaw Is

NanoClaw is a lightweight personal AI assistant runtime forked from [qwibitai/nanoclaw](https://github.com/qwibitai/nanoclaw) (20K stars, MIT license). It is a single Node.js process (~35K tokens of source) that:

1. **Polls channels** (WhatsApp, Telegram, Slack, Discord, Gmail) for inbound messages
2. **Routes messages** through a trigger pattern (`@Andy`) and per-group queue system
3. **Spawns isolated agent containers** via Docker, each running the Claude Agent SDK
4. **Persists state** in SQLite (`store/messages.db`) with per-group filesystem isolation
5. **Manages scheduled tasks** (cron, interval, one-shot) via IPC between orchestrator and containers

### Two-Tier Container Model

This is the critical architectural insight: NanoClaw has TWO container images, not one.

| Image | Purpose | Dockerfile | Runtime |
|-------|---------|-----------|---------|
| **Orchestrator** | Channel polling, SQLite, IPC, queue management | `container/Dockerfile.golden` (new) | Long-running, single replica |
| **Agent** | Claude Agent SDK execution per conversation | `container/Dockerfile` (existing) | Ephemeral, spawned per-group |

The orchestrator spawns agent containers via the Docker socket. Each agent container runs in isolation with only its group's filesystem mounted. This is the security model: agents cannot see other groups' data or the host filesystem.

### Key Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/index.ts` | 589 | Main orchestrator: state, message loop, agent invocation |
| `src/container-runner.ts` | 703 | Builds volume mounts, spawns containers, parses output |
| `src/db.ts` | 698 | SQLite schema, CRUD, migrations |
| `src/group-queue.ts` | 366 | Per-group queue with global concurrency limit |
| `src/ipc.ts` | 456 | IPC watcher: message routing, task scheduling |
| `src/container-runtime.ts` | 88 | Docker abstraction (swappable) |
| `src/config.ts` | 70 | Configuration from .env / process.env |
| `src/channels/registry.ts` | 29 | Channel self-registration system |
| `container/agent-runner/src/index.ts` | 589 | In-container agent: Claude SDK, IPC, streaming output |

### Dependencies

**Orchestrator (6 runtime deps):**
- `better-sqlite3` - SQLite bindings (native addon, needs build tools at install)
- `cron-parser` - Cron expression parsing for scheduled tasks
- `pino` + `pino-pretty` - Structured logging
- `yaml` - YAML parsing
- `zod` - Schema validation

**Agent container (4 deps):**
- `@anthropic-ai/claude-agent-sdk` - Claude Code agent SDK
- `@modelcontextprotocol/sdk` - MCP protocol for IPC tools
- `cron-parser` - Same as orchestrator
- `zod` - Same as orchestrator

Plus globally installed in agent container:
- `agent-browser` - Chromium browser automation
- `@anthropic-ai/claude-code` - Claude Code CLI

### Configuration Model

NanoClaw intentionally avoids configuration files. All config comes from:
1. **Environment variables** (`.env` file or `process.env`)
2. **Code changes** (the codebase is designed to be modified)
3. **Per-group CLAUDE.md** files (agent memory/instructions)

Key environment variables:
- `ASSISTANT_NAME` - Trigger word (default: "Andy")
- `CONTAINER_IMAGE` - Agent container image name
- `MAX_CONCURRENT_CONTAINERS` - Concurrency limit (default: 5)
- `IDLE_TIMEOUT` - Container idle timeout in ms (default: 1800000 = 30min)
- `CONTAINER_TIMEOUT` - Hard timeout in ms (default: 1800000)
- `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` - Required for Claude API
- `LOG_LEVEL` - pino log level (default: "info")

### Channel System

Channels are skills that self-register at startup. The barrel file `src/channels/index.ts` imports channel modules. In the current fork, ALL channel imports are commented out (clean slate). Channels are added via skills like `/add-whatsapp`, `/add-telegram`, etc.

For the golden image, NanoClaw starts with **no channels configured**. This is by design:
- Channels require external API credentials
- Each user activates only the channels they need
- Channel code is added to the codebase via skills (not config)

## What Was Created

### 1. Orchestrator Dockerfile (`container/Dockerfile.golden`)

Multi-stage build optimized for the golden image:
- **Stage 1 (builder):** Installs deps, compiles TypeScript, prunes devDependencies
- **Stage 2 (runtime):** Node.js 22-slim + Docker CLI + tini
- Non-root user (`nanoclaw`)
- Health check via SQLite probe
- Tini as PID 1 for proper SIGTERM handling
- Docker CLI installed for spawning agent containers (no Docker daemon)

### 2. k3s Manifest (`deploy/k3s-manifest.yaml`)

Auto-deploy manifest for `/var/lib/rancher/k3s/server/manifests/`:
- Namespace: `nanoclaw`
- Deployment (single replica, Recreate strategy for SQLite safety)
- ConfigMap with golden image defaults
- Secret placeholder for channel credentials
- Resource limits: 256Mi-512Mi memory, 250m-500m CPU
- Docker socket mount for agent container spawning
- hostPath volumes for SQLite, data, and groups (appropriate for single-node edge)
- Liveness and startup probes
- Service placeholder for future health/metrics endpoint

### 3. Build Script (`scripts/build-golden.sh`)

Builds both container images and tags for the EV Gitea registry:
- Orchestrator: `git.escape-velocity-ventures.org/ev/nanoclaw:{tag}`
- Agent: `git.escape-velocity-ventures.org/ev/nanoclaw-agent:{tag}`
- Auto-tags with package.json version
- Optional `--push` flag
- Platform-aware (default: linux/amd64)

## Items Requiring Human Attention

### Critical: Docker Socket Access

NanoClaw's security model depends on spawning agent containers via Docker. On k3s (which uses containerd, not Docker), you need one of:

1. **Install Docker CE alongside k3s** and mount `/var/run/docker.sock` (simplest)
2. **Use nerdctl** with containerd socket — requires modifying `src/container-runtime.ts` to use `nerdctl` instead of `docker`
3. **Use DinD sidecar** — add a Docker-in-Docker sidecar container to the pod

Recommendation: Option 1 for the golden image. Docker CE is already likely needed for other workloads. The orchestrator only needs the Docker CLI, not the daemon.

### Critical: Claude API Authentication

NanoClaw requires either `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` to function. The agent container passes this to the Claude Agent SDK. For the golden image:

- Secrets should be provisioned via `kubectl create secret` during node setup
- The k3s manifest includes a Secret placeholder (`nanoclaw-secrets`)
- Consider using the existing cluster secret infrastructure (similar to `pai-state-api-key`)

### Critical: No Channels = No Messages

The current fork has all channel imports commented out in `src/channels/index.ts`. If the orchestrator starts with zero channels, it will `process.exit(1)` immediately (line 531 of `src/index.ts`).

Options:
1. **Add a "null channel"** that always returns connected (for testing/readiness)
2. **Remove the fatal exit** — allow NanoClaw to start and wait for channel configuration
3. **Pre-configure a channel** (e.g., Telegram) in the golden image via a skill

Recommendation: Option 2. Modify the startup to warn instead of exit when no channels are configured, allowing the image to be provisioned before channels are added.

### Important: Agent Container Pre-Build

The orchestrator references `nanoclaw-agent:latest` and spawns it via `docker run`. This image must be pre-built on the node or available from the registry. The build script handles both.

For the golden image, the agent container should be pre-pulled during image bake:
```bash
docker pull git.escape-velocity-ventures.org/ev/nanoclaw-agent:latest
```

### Important: better-sqlite3 Native Addon

`better-sqlite3` is a native Node.js addon that compiles C++ code. The multi-stage build handles this, but if you switch to Alpine or a different base image, you may need additional build dependencies (`python3`, `make`, `g++`).

### Important: Resource Limits

The k3s manifest sets conservative limits for edge hardware:
- **Orchestrator:** 256Mi-512Mi memory, 250m-500m CPU
- **Agent containers:** Not limited by the k3s manifest (they're spawned via Docker, not k8s)

To limit agent containers, set `MAX_CONCURRENT_CONTAINERS=2` (or 1 for very constrained hardware) and consider adding `--memory` and `--cpus` flags to the Docker run command in `src/container-runner.ts`.

### Nice-to-Have: Bundled Skills Only

The current codebase copies skills from `container/skills/` into each group's `.claude/skills/` directory. For the golden image, you can:
1. **Curate the skills directory** — remove browser automation skill if not needed
2. **Add EV-specific skills** — custom skills for the golden image use case
3. **Lock down skill installation** — prevent agents from adding new skills at runtime

### Nice-to-Have: Local Model Support

NanoClaw supports custom API endpoints via `ANTHROPIC_BASE_URL`. For true local-first operation (no external API keys), you could:
1. Run Ollama or a local model server as another k3s workload
2. Set `ANTHROPIC_BASE_URL` to point to the local server
3. The agent container would use the local model instead of Claude API

This requires an Anthropic API-compatible proxy (e.g., LiteLLM) in front of the local model.

### Nice-to-Have: Metrics/Observability

NanoClaw uses pino for structured logging (JSON to stderr). For the golden image:
1. k3s will capture container logs via containerd
2. Consider adding a pino transport for Prometheus metrics
3. The SQLite DB could be queried for operational metrics

## File Inventory

```
container/Dockerfile.golden    - NEW: Orchestrator multi-stage Dockerfile
deploy/k3s-manifest.yaml       - NEW: k3s auto-deploy manifest
scripts/build-golden.sh        - NEW: Build + tag script for Gitea registry
GOLDEN-IMAGE-INTEGRATION.md    - NEW: This document
```

## Next Steps

1. **Decide on Docker socket strategy** (Docker CE vs nerdctl vs DinD)
2. **Provision Claude API credentials** in the golden image secret store
3. **Fix the no-channels fatal exit** so NanoClaw can start before channel setup
4. **Build and test** locally: `./scripts/build-golden.sh`
5. **Push to Gitea registry**: `./scripts/build-golden.sh latest --push`
6. **Deploy to test node**: Copy `deploy/k3s-manifest.yaml` to k3s manifests dir
7. **Add a channel** via skill and verify end-to-end message flow
