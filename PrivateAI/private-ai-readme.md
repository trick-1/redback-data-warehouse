# PrivateAI Stack Architecture and Capabilities

This document provides a top-level architecture overview of the PrivateAI stack.

The stack combines a local/private AI inference layer, a browser-based user interface, an MCP tool integration layer, repository security scanning, knowledge/memory services, and reverse proxy access.

It is designed as a modular private AI platform that can run local models, expose an OpenAI-compatible API, integrate external tools through MCP, scan repositories, and provide a secure web interface for users.

## Documented Components

The current stack documentation covers:

1. **Semgrep MCP Service**
2. **LocalAI with PostgreSQL / LocalRecall**
3. **OpenWebUI with Caddy HTTPS reverse proxy**
4. **Repo Security Scan Job MCP**
5. **MCP Hub with proxychains and integrations**

Together, these form the current PrivateAI platform.

## High-Level Architecture

```text
                          Users / Browser
                               |
                               v
                    https://10.137.17.254/
                               |
                               v
                            Caddy
                   HTTPS reverse proxy layer
                               |
                               v
                           OpenWebUI
                  Browser UI / chat interface
                               |
                               v
             OpenAI-compatible API endpoint / gateway
                  http://10.137.17.254:9443/v1
                               |
                               v
                            LocalAI
              Local inference, models, agents, memory
                               |
                +--------------+---------------+
                |                              |
                v                              v
          Local models                  PostgreSQL /
       GPU-backed inference             LocalRecall
                                        knowledge base

                               |
                               v
                            MCP Hub
              Tool and integration orchestration
                               |
     +------------+-------------+--------------+-------------+
     |            |             |              |             |
     v            v             v              v             v
 Playwright     Fetch       Git tools       Wazuh       Databases
 Browser       HTTP tools    Repo tools    Security     PostgreSQL /
 automation                                platform     Supabase
                               |
                               v
                     Repo Security Scan MCP
                               |
                               v
                         Semgrep scans
                               |
                               v
                        /opt/redback/repos
```

## Core Design Goals

The stack is intended to provide:

- A private AI interface for users
- Local model inference using GPU-backed LocalAI
- OpenAI-compatible API access for tools and frontends
- Persistent model, backend, config, image, and data storage
- PostgreSQL-backed agent memory and knowledge base capability
- MCP tool access for browsing, fetching, databases, security tools, and code repositories
- Repository security scanning using Semgrep
- HTTPS access via Caddy
- Corporate proxy compatibility
- Internal service routing without proxy interference
- Docker-based operational simplicity

## Main User Entry Point

The main user-facing entry point is OpenWebUI behind Caddy.

Users access:

```text
https://10.137.17.254/
```

Caddy handles HTTPS and forwards traffic to OpenWebUI internally:

```text
openwebui:8080
```

OpenWebUI provides the browser chat interface, authentication, OAuth login, and connection to the OpenAI-compatible backend.

## Reverse Proxy Layer

### Component

```text
Caddy
```

### Purpose

Caddy provides:

- HTTPS termination
- Reverse proxying to OpenWebUI
- Certificate handling
- Public-facing access on ports `443` and optionally `3000`

### Published Ports

```text
80  -> HTTP
443 -> HTTPS
3000 -> alternate HTTPS mapping
```

### Why It Matters

OpenWebUI is not exposed directly to the host. It is only exposed inside Docker using:

```yaml
expose:
  - "8080"
```

This keeps the UI behind the reverse proxy and allows secure cookie/session behaviour to work properly.

## Web UI Layer

### Component

```text
OpenWebUI
```

### Purpose

OpenWebUI provides the user-facing AI chat interface.

It is configured with:

- Authentication enabled
- Microsoft Entra / Azure AD OAuth
- Login form support
- Community sharing disabled
- Safe mode enabled
- HTTPS-aware cookie/session settings
- OpenAI-compatible backend API integration

### Backend API

OpenWebUI is configured to use:

```text
http://10.137.17.254:9443/v1
```

This means OpenWebUI talks to an OpenAI-compatible API endpoint rather than directly embedding model logic.

Depending on routing, that endpoint may point to LocalAI directly or to an API gateway such as LiteLLM or another routing layer.

## Inference Layer

### Component

```text
LocalAI
```

### Purpose

LocalAI provides the local model inference backend.

It is configured using the NVIDIA CUDA 12 GPU image:

```text
localai/localai:latest-gpu-nvidia-cuda-12
```

LocalAI exposes an OpenAI-compatible API and supports local models, backends, image outputs, agent features, memory integration, and skills.

### LocalAI API Port

LocalAI is mapped as:

```text
host port 4000 -> container port 8080
```

Direct LocalAI endpoint:

```text
http://localhost:4000
```

Container-internal endpoint:

```text
http://localai:8080
```

### GPU Capability

LocalAI is configured for NVIDIA GPUs:

```yaml
runtime: nvidia
gpus: all
NVIDIA_VISIBLE_DEVICES=all
NVIDIA_DRIVER_CAPABILITIES=compute,utility
```

This allows GPU-backed model inference.

### Model Storage

Models are persisted at:

```text
/opt/redback/privateai/volumes/models
```

Mounted inside LocalAI as:

```text
/models
```

### Backend Storage

LocalAI backends are stored at:

```text
/opt/redback/privateai/volumes/backends
```

Mounted inside LocalAI as:

```text
/usr/share/localai/backends
```

### Image Output Storage

Generated images are stored at:

```text
/opt/redback/privateai/volumes/images
```

Mounted inside LocalAI as:

```text
/tmp/generated/images
```

## Knowledge and Memory Layer

### Components

```text
PostgreSQL
LocalRecall
LocalAI Agent Pool
```

### Purpose

The knowledge/memory layer provides persistent storage for LocalAI agent memory and knowledge base workflows.

LocalAI is configured to use PostgreSQL as the vector engine:

```env
LOCALAI_AGENT_POOL_VECTOR_ENGINE=postgres
```

The database connection is:

```text
postgresql://localrecall:localrecall@postgres:5432/localrecall?sslmode=disable
```

### PostgreSQL Service

The stack uses:

```text
quay.io/mudler/localrecall:v0.5.2-postgresql
```

Database:

```text
localrecall
```

User:

```text
localrecall
```

### Agent Pool Defaults

Default agent model:

```text
gemma-4-e4b-it
```

Embedding model:

```text
granite-embedding-107m-multilingual
```

### Capability

This gives the stack the foundation for:

- Knowledge bases
- Agent memory
- Embedding-backed retrieval
- Local RAG-style workflows
- Skills-enabled agent behaviour
- Persistent logs for agent operations

## MCP Integration Layer

### Component

```text
MCP Hub
```

### Purpose

MCP Hub acts as the tool orchestration layer.

It connects AI clients and agents to external tools through the Model Context Protocol.

It is exposed on:

```text
host port 3003 -> container port 3000
```

Access:

```text
http://localhost:3003
```

### Current MCP Integrations

The hub is currently configured with:

```text
amap
playwright
fetch
sequential-thinking
time
mindmap
playwright-mcp
fetch-mcp
time-mcp
mongodb
git-mcp-server
repo-security-scan
arxiv-mcp
wazuh
postgresql
supabase-postgres
```

### Capability Categories

#### Browser Automation

```text
playwright
playwright-mcp
```

Provides browser-driven workflows, page inspection, and automation.

#### HTTP Fetching

```text
fetch
fetch-mcp
```

Provides tool-based HTTP retrieval.

#### Reasoning Support

```text
sequential-thinking
mindmap
```

Provides structured reasoning and planning style tools.

#### Time Tools

```text
time
time-mcp
```

Provides time/date utilities.

#### Repository and Git Tools

```text
git-mcp-server
repo-security-scan
```

Provides repository interaction and security scanning.

#### Security Platform Integration

```text
wazuh
```

Connects the AI tool layer to Wazuh security data.

#### Database Integrations

```text
mongodb
postgresql
supabase-postgres
```

Allows MCP-enabled access to database systems.

#### Research Integration

```text
arxiv-mcp
```

Provides arXiv research search capability.

## Repository Security Scanning

Repository scanning is implemented in two related ways.

## Semgrep MCP Service

### Component

```text
semgrep-mcp
```

### Purpose

Runs Semgrep as a streamable HTTP MCP server.

It exposes Semgrep functionality over MCP and mounts repositories read-only:

```text
/opt/redback/repos:/repos:ro
```

It listens on:

```text
4004
```

This service is useful when an MCP client wants direct Semgrep MCP access over HTTP.

## Repo Security Scan Job MCP

### Component

```text
repo_scan_job_mcp.js
```

### Purpose

This is a custom job-oriented MCP wrapper around Semgrep.

Instead of blocking while a scan runs, it starts a background Docker job and returns a `job_id`.

The client can then:

1. List repositories
2. Start a scan
3. Check scan status
4. Fetch completed results
5. List recent jobs

### Main Tools

```text
repo_list
repo_security_scan_start
repo_security_scan_status
repo_security_scan_result
repo_security_scan_list_jobs
```

### Why This Exists

Large Semgrep scans can take time.

The job wrapper allows the assistant or MCP client to start a scan and come back for results later, without blocking the MCP tool call.

### Repository Root

Host path:

```text
/opt/redback/repos
```

Container path:

```text
/repos
```

### Scan Profiles

Supported profiles:

```text
security
secrets
full
```

Profile mapping:

```text
security -> p/security-audit
secrets  -> p/secrets
full     -> p/security-audit + p/secrets + p/owasp-top-ten
```

### Docker Requirement

The job wrapper launches Semgrep using Docker:

```bash
docker run --rm ...
```

Therefore MCP Hub is configured with:

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

and the custom MCP Hub image includes the Docker CLI.

## Proxy and Network Design

The stack is designed to work in an environment that requires a corporate proxy.

Proxy host:

```text
proxy1.it.deakin.edu.au
```

Proxy IP:

```text
10.137.0.162
```

Proxy port:

```text
3128
```

### HTTP Proxy Variables

Common proxy variables:

```env
HTTP_PROXY=http://proxy1.it.deakin.edu.au:3128
HTTPS_PROXY=http://proxy1.it.deakin.edu.au:3128
```

### NO_PROXY

Internal traffic is excluded using `NO_PROXY`.

Typical entries include:

```text
localhost
127.0.0.1
::1
localai
postgres
mcphub
openwebui
semgrep-mcp
mcp-hub-mcphub-1
proxy1.it.deakin.edu.au
10.137.0.162
10.137.17.254
api.mcprouter.to
```

### Why NO_PROXY Matters

Without correct `NO_PROXY`, internal Docker and internal network traffic may be sent through the external proxy.

That can cause:

- `fetch failed`
- connection refused
- bad port errors
- proxy recursion
- internal services becoming unreachable
- MCP servers failing to connect
- OAuth/backend API calls behaving unexpectedly

## Proxychains in MCP Hub

MCP Hub uses a custom entrypoint that runs the hub under `proxychains4`.

This helps with tools or dependencies that do not respect normal proxy environment variables.

### Proxychains Local Network Exclusions

The configuration excludes:

```text
10.137.0.162/32
127.0.0.0/8
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

This prevents internal traffic and the proxy itself from being proxied.

### Why This Matters

Some MCP tools make outbound network calls through Node.js, Python, browser tooling, or subprocesses.

Proxychains gives a broad fallback mechanism for forcing outbound traffic through the proxy when native proxy handling is unreliable.

## Data and Storage Layout

The stack uses a host-based storage layout under `/opt/redback`.

### AI Stack Data

```text
/opt/redback/privateai/volumes/
├── models/
├── images/
├── backends/
├── localai_data/
└── localai_config/
```

### Repository Data

```text
/opt/redback/repos/
```

This directory is used by:

- Semgrep MCP
- Repo security scan MCP
- Git MCP tooling
- Code analysis workflows

### MCP Hub Files

A typical MCP Hub working directory contains:

```text
mcp-hub/
├── docker-compose.yaml
├── Dockerfile
├── .env
├── mcp_settings.json
├── entrypoint-proxy.sh
├── proxychains.conf
├── nodefetch.sh
└── repo_scan_job_mcp.js
```

### OpenWebUI Stack Files

A typical OpenWebUI/Caddy directory contains:

```text
openwebui-stack/
├── docker-compose.yml
├── .env
├── data/
└── caddy/
    ├── Caddyfile
    ├── caddy_data/
    ├── caddy_config/
    └── certs/
```

## Authentication and Access Control

### OpenWebUI

OpenWebUI authentication is enabled:

```env
WEBUI_AUTH=true
```

Microsoft Entra OAuth is enabled:

```env
ENABLE_OIDC=true
OAUTH_MICROSOFT_ENABLED=true
ENABLE_OAUTH_SIGNUP=true
```

This allows users to authenticate with Microsoft Entra / Azure AD.

### Caddy

Caddy provides HTTPS access and certificate handling.

### MCP Hub

MCP Hub is powerful and should be treated as sensitive.

It has access to:

- MCP tools
- Internal services
- Repositories
- Docker socket
- Databases
- Security systems
- Browser automation
- Outbound network access

MCP Hub should only be exposed to trusted clients or placed behind authentication and network controls.

## Capability Overview

The current PrivateAI stack can provide the following capabilities.

## 1. Private Chat Interface

Users can access OpenWebUI through a browser and chat with local or routed models.

Capability:

```text
User -> OpenWebUI -> OpenAI-compatible API -> LocalAI / gateway
```

## 2. Local GPU Inference

LocalAI can run local models using NVIDIA GPUs.

Capability:

```text
Prompt -> LocalAI -> GPU-backed model -> Response
```

## 3. OpenAI-Compatible API

LocalAI exposes an OpenAI-compatible interface.

This allows tools like OpenWebUI, LiteLLM, agents, or custom applications to call local models using familiar API patterns.

## 4. Knowledge Base and Memory

LocalAI is configured with PostgreSQL-backed vector/memory support.

Capability:

```text
Documents / memory -> embeddings -> PostgreSQL / LocalRecall -> retrieval -> model context
```

## 5. MCP Tool Use

MCP Hub exposes external tools to AI clients.

Capability examples:

- Fetch webpages
- Use browser automation
- Query databases
- Search arXiv
- Interact with Git repositories
- Check time/date
- Use structured reasoning tools
- Query security systems
- Run repository security scans

## 6. Repository Security Scanning

Semgrep can scan repositories under:

```text
/opt/redback/repos
```

Capabilities:

- Security audit scans
- Secret scans
- OWASP Top Ten scans
- Background scan jobs
- Scan status polling
- JSON result retrieval
- Severity summaries

## 7. Security Operations Integration

The Wazuh MCP integration gives the stack a pathway into security monitoring data.

Potential capabilities:

- Query alerts
- Investigate endpoints
- Summarise security events
- Connect findings to repository or infrastructure context

## 8. Database-Aware Assistance

MCP integrations include:

```text
mongodb
postgresql
supabase-postgres
```

Potential capabilities:

- Query operational data
- Inspect schemas
- Summarise records
- Support application debugging
- Assist with reporting and analysis

## 9. Browser and Web Automation

Playwright tools provide browser automation.

Potential capabilities:

- Page testing
- UI validation
- Screenshot-style inspection
- Web workflow automation
- Login/session testing where appropriately configured

## 10. Research Support

The arXiv MCP integration provides research discovery capability.

Potential capabilities:

- Search papers
- Summarise technical topics
- Support research workflows
- Combine local reasoning with external paper discovery

## Deployment Boundaries

The stack has several major trust boundaries.

## User Boundary

```text
Users -> Caddy -> OpenWebUI
```

Users should interact through HTTPS and authenticated OpenWebUI sessions.

## API Boundary

```text
OpenWebUI -> OpenAI-compatible backend
```

OpenWebUI sends prompts and receives model responses through the configured backend API.

## Tool Boundary

```text
AI client / hub -> MCP tools
```

MCP tools can access sensitive systems. This boundary requires careful trust and configuration.

## Host Boundary

```text
MCP Hub -> Docker socket -> host Docker daemon
```

Docker socket access is effectively privileged host access.

This is the highest-risk boundary in the current architecture.

## Data Boundary

```text
Repositories, models, generated files, databases, configs
```

Persistent data is stored on the host and mounted into containers.

Permissions, backups, and separation of writable/read-only paths matter.

## Security Considerations

Important security considerations:

- Do not expose MCP Hub to untrusted networks.
- Treat Docker socket access as privileged.
- Keep repository mounts read-only where possible.
- Use separate writable job storage for scan outputs.
- Store secrets in `.env`, secret stores, or Docker secrets.
- Do not commit `.env` files.
- Avoid using simple default database passwords in production.
- Keep OAuth redirect URIs exact.
- Use HTTPS for OpenWebUI.
- Limit MCP tools where possible instead of exposing `"tools": "all"` everywhere.
- Pin container image versions for reproducibility.
- Monitor logs for proxy and authentication failures.
- Consider splitting risky tools into separate MCP Hub instances.

## Operational Validation

## Validate OpenWebUI

```bash
curl -k https://10.137.17.254/
```

## Validate LocalAI

```bash
curl http://localhost:4000/v1/models
```

## Validate LocalAI GPU Access

```bash
docker exec -it local-ai nvidia-smi
```

## Validate PostgreSQL

```bash
docker compose logs postgres
```

or:

```bash
docker exec -it <postgres-container> pg_isready -U localrecall
```

## Validate MCP Hub

```bash
curl http://localhost:3003
```

Check logs:

```bash
docker compose logs -f mcphub
```

## Validate MCP Hub Docker Access

```bash
docker exec -it mcp-hub-mcphub-1 docker ps
```

## Validate Repository Mount

```bash
docker exec -it mcp-hub-mcphub-1 ls -la /repos
```

## Validate Internal HTTP Fetch

```bash
./nodefetch.sh
```

## Validate Semgrep Scan Image

```bash
docker exec -it mcp-hub-mcphub-1 sh -lc \
'docker run --rm -v /opt/redback/repos:/repos:ro semgrep/semgrep:1.159.0 semgrep --version'
```

## Current Strengths

The current architecture has several strengths:

- Modular Docker-based design
- Local model support
- GPU-backed inference
- OpenAI-compatible API pattern
- Browser UI with OAuth support
- Caddy-based HTTPS
- MCP tool integration layer
- Repository scanning and security tooling
- Proxy-aware networking
- Persistent host-mounted storage
- Extensible integration approach

## Current Risks and Gaps

Areas that may need future hardening:

- MCP Hub has broad tool access
- Docker socket mount is high risk
- Some images use `latest`
- Some credentials are simple defaults
- Repo scan jobs may write logs under repository mount unless separated
- Tool exposure currently uses `"tools": "all"` for many integrations
- Runtime proxy variables should be checked carefully
- OAuth without email is a workaround and may affect account stability
- More explicit network segmentation may be useful
- Centralised backup/restore documentation is still needed

## Recommended Next Improvements

Recommended next steps:

1. Pin all container image versions.
2. Split high-risk MCP tools into separate MCP Hub instances.
3. Put MCP Hub behind authentication and TLS.
4. Use a Docker socket proxy instead of mounting the Docker socket directly.
5. Move repo scan job logs to a dedicated `/jobs` volume.
6. Make repository mounts read-only wherever possible.
7. Replace default PostgreSQL credentials.
8. Add healthchecks for key services.
9. Add backup and restore procedures.
10. Add a network diagram with actual hostnames/IPs.
11. Add a model inventory document.
12. Add a runbook for proxy troubleshooting.
13. Add a runbook for OAuth troubleshooting.
14. Add a security model for MCP tool exposure.
15. Add a standard onboarding guide for new tools.

## Architecture Summary

The PrivateAI stack is a locally controlled AI platform made up of:

- **Caddy** for HTTPS ingress
- **OpenWebUI** for the user interface
- **LocalAI** for local GPU-backed inference
- **PostgreSQL / LocalRecall** for knowledge base and memory support
- **MCP Hub** for tool orchestration
- **Semgrep and repo scan MCP** for repository security scanning
- **Proxychains and proxy configuration** for reliable operation behind a corporate proxy
- **Host-mounted storage** for models, repositories, configs, generated outputs, and persistent data

The platform is capable of private chat, local inference, tool use, browser automation, repository analysis, security scanning, database interaction, research assistance, and knowledge-backed workflows.

The overall design is flexible and powerful, but MCP Hub and Docker socket access should be treated as sensitive infrastructure and hardened before broader production use.
