# MCP Hub Configuration

This document describes the MCP Hub deployment used to run multiple Model Context Protocol integrations behind a proxy-aware Docker setup.

The stack is based on the `samanhappy/mcphub` image with a custom Dockerfile that adds Playwright Chromium support and the Docker CLI. It also uses an entrypoint wrapper to run MCP Hub under `proxychains4`, allowing selected outbound traffic to traverse the corporate proxy while internal/local traffic remains unproxied.

## Overview

This MCP Hub instance exposes MCP Hub on host port `3003` and loads its server definitions from:

```text
./mcp_settings.json
```

It also mounts:

```text
./repo_scan_job_mcp.js
```

into the container so that the job-oriented repository security scan MCP can be run from the hub.

The main runtime container is:

```text
mcp-hub-mcphub-1
```

The service exposes MCP Hub externally at:

```text
http://<host-ip>:3003
```

## Enabled MCP Integrations

The MCP Hub configuration currently includes the following server integrations:

```json
{
  "servers": [
    {
      "name": "amap",
      "tools": "all"
    },
    {
      "name": "playwright",
      "tools": "all"
    },
    {
      "name": "fetch",
      "tools": "all"
    },
    {
      "name": "sequential-thinking",
      "tools": "all"
    },
    {
      "name": "time",
      "tools": "all"
    },
    {
      "name": "mindmap",
      "tools": "all"
    },
    {
      "name": "playwright-mcp",
      "tools": "all"
    },
    {
      "name": "fetch-mcp",
      "tools": "all"
    },
    {
      "name": "time-mcp",
      "tools": "all"
    },
    {
      "name": "mongodb",
      "tools": "all"
    },
    {
      "name": "git-mcp-server",
      "tools": "all"
    },
    {
      "name": "repo-security-scan",
      "tools": "all"
    },
    {
      "name": "arxiv-mcp",
      "tools": "all"
    },
    {
      "name": "wazuh",
      "tools": "all"
    },
    {
      "name": "postgresql",
      "tools": "all"
    },
    {
      "name": "supabase-postgres",
      "tools": "all"
    }
  ]
}
```

## Integration Summary

| Integration | Purpose |
|---|---|
| `amap` | Map/location-related MCP integration |
| `playwright` | Browser automation |
| `fetch` | HTTP fetching |
| `sequential-thinking` | Structured multi-step reasoning tool |
| `time` | Time/date tools |
| `mindmap` | Mind map generation or manipulation |
| `playwright-mcp` | Additional Playwright MCP server |
| `fetch-mcp` | Additional fetch MCP server |
| `time-mcp` | Additional time MCP server |
| `mongodb` | MongoDB access |
| `git-mcp-server` | Git repository interaction |
| `repo-security-scan` | Job-based Semgrep repository scanning |
| `arxiv-mcp` | arXiv search/research integration |
| `wazuh` | Wazuh security platform integration |
| `postgresql` | PostgreSQL access |
| `supabase-postgres` | Supabase PostgreSQL access |

## Docker Compose

```yaml
services:
  mcphub:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        HTTP_PROXY: ${MCPHUB_HTTP_PROXY}
        HTTPS_PROXY: ${MCPHUB_HTTPS_PROXY}
        NO_PROXY: ${MCPHUB_NO_PROXY}
        http_proxy: ${MCPHUB_HTTP_PROXY}
        https_proxy: ${MCPHUB_HTTPS_PROXY}
        no_proxy: ${MCPHUB_NO_PROXY}
    image: samanhappy/mcphub
    ports:
      - "3003:3000"
    volumes:
      - ./mcp_settings.json:/app/mcp_settings.json
      - ./entrypoint-proxy.sh:/app/entrypoint-proxy.sh:ro
      - ./proxychains.conf:/etc/proxychains.conf:ro
      - ./repo_scan_job_mcp.js:/app/repo_scan_job_mcp.js:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/redback/repos:/repos
    environment:
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=${NO_PROXY}
    restart: unless-stopped
    extra_hosts:
      - "proxy1.it.deakin.edu.au:10.137.0.162"
    entrypoint: ["/app/entrypoint-proxy.sh"]
    command: ["pnpm","start"]
```

## What This Compose File Does

The `mcphub` service:

- Builds from a local custom `Dockerfile`
- Uses `samanhappy/mcphub` as the base image
- Publishes MCP Hub on host port `3003`
- Mounts MCP settings from the host
- Mounts a proxy-aware entrypoint script
- Mounts a `proxychains.conf`
- Mounts the repository security scan MCP wrapper
- Mounts the Docker socket so repo scan jobs can launch Semgrep containers
- Mounts `/opt/redback/repos` into the hub at `/repos`
- Runs the hub through `entrypoint-proxy.sh`
- Starts MCP Hub using `pnpm start`

## Port Mapping

```yaml
ports:
  - "3003:3000"
```

This maps container port `3000` to host port `3003`.

Access MCP Hub at:

```text
http://localhost:3003
```

Or from another machine:

```text
http://<host-ip>:3003
```

## Mounted Files and Directories

### MCP Settings

```yaml
- ./mcp_settings.json:/app/mcp_settings.json
```

This is the main MCP Hub configuration file.

It defines the enabled MCP servers and how they are launched or connected.

### Proxy Entrypoint

```yaml
- ./entrypoint-proxy.sh:/app/entrypoint-proxy.sh:ro
```

This script configures proxy environment variables, installs `proxychains4` if needed, and launches MCP Hub through proxychains.

### Proxychains Configuration

```yaml
- ./proxychains.conf:/etc/proxychains.conf:ro
```

This defines which traffic should go through the proxy and which networks should remain local.

### Repo Scan MCP Wrapper

```yaml
- ./repo_scan_job_mcp.js:/app/repo_scan_job_mcp.js:ro
```

This mounts the custom job-oriented Semgrep scan MCP server into the hub container.

The MCP settings can then run this file as a stdio MCP server.

### Docker Socket

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

This gives the MCP Hub container access to the host Docker daemon.

This is required by `repo_scan_job_mcp.js`, because that tool launches Semgrep scan jobs using `docker run`.

Important: mounting the Docker socket is powerful and should only be used in trusted environments.

### Repository Mount

```yaml
- /opt/redback/repos:/repos
```

This exposes host repositories to MCP Hub at:

```text
/repos
```

The repo scan MCP uses this path to list repositories and validate scan targets.

## Custom Dockerfile

```dockerfile
FROM samanhappy/mcphub:latest

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV NO_PROXY=${NO_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV no_proxy=${NO_PROXY}

WORKDIR /app

# Make npm aware of the proxy during build, if provided
RUN if [ -n "$HTTP_PROXY" ]; then npm config set proxy "$HTTP_PROXY"; fi \
 && if [ -n "$HTTPS_PROXY" ]; then npm config set https-proxy "$HTTPS_PROXY"; fi \
 && npx playwright install chromium

# Copy docker CLI from official image
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker

CMD ["node", "dist/index.js"]
```

## What the Dockerfile Adds

The custom image extends `samanhappy/mcphub:latest` and adds:

1. Proxy environment variables during image build
2. npm proxy configuration
3. Playwright Chromium browser installation
4. Docker CLI copied from the official Docker CLI image

### Why Playwright Chromium Is Installed

Some MCP tools use Playwright for browser automation.

The build step installs Chromium:

```dockerfile
npx playwright install chromium
```

This avoids runtime failures when a Playwright MCP server needs a browser binary.

### Why Docker CLI Is Added

The repo scan MCP launches Semgrep jobs using:

```bash
docker run
```

Mounting `/var/run/docker.sock` is not enough by itself. The container also needs the `docker` command available.

The Dockerfile copies the CLI from the official Docker image:

```dockerfile
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker
```

## Entrypoint Proxy Script

```sh
#!/bin/sh
set -eu

# Ensure apt and other tools see proxy envs (many tools expect lowercase)
if [ -n "${HTTP_PROXY:-}" ] && [ -z "${http_proxy:-}" ]; then export http_proxy="$HTTP_PROXY"; fi
if [ -n "${HTTPS_PROXY:-}" ] && [ -z "${https_proxy:-}" ]; then export https_proxy="$HTTPS_PROXY"; fi
if [ -n "${NO_PROXY:-}" ] && [ -z "${no_proxy:-}" ]; then export no_proxy="$NO_PROXY"; fi

# If we're on Debian/Ubuntu, also configure apt to use the proxy explicitly
if command -v apt-get >/dev/null 2>&1; then
  mkdir -p /etc/apt/apt.conf.d
  # Prefer HTTPS proxy if set, otherwise HTTP proxy
  APT_PROXY="${https_proxy:-${http_proxy:-}}"
  if [ -n "$APT_PROXY" ]; then
    cat > /etc/apt/apt.conf.d/99proxy <<EOF
Acquire::http::Proxy "$APT_PROXY";
Acquire::https::Proxy "$APT_PROXY";
EOF
  fi
fi

# Install proxychains if not present
if ! command -v proxychains4 >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache proxychains-ng
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    # Try common package names
    apt-get install -y proxychains4 || apt-get install -y proxychains-ng
  else
    echo "No supported package manager found to install proxychains." >&2
    exit 1
  fi
fi

# Generate a proxychains config if none provided
CONF="/etc/proxychains.conf"
if [ ! -f "$CONF" ]; then
  PROXY_URL="${https_proxy:-${http_proxy:-}}"
  if [ -z "$PROXY_URL" ]; then
    echo "HTTP_PROXY/HTTPS_PROXY not set and no $CONF provided." >&2
    exit 1
  fi

  HOSTPORT="$(echo "$PROXY_URL" | sed -E 's#^[a-zA-Z]+://##' | sed -E 's#/.*$##' | sed -E 's#^[^@]*@##')"
  HOST="$(echo "$HOSTPORT" | cut -d: -f1)"
  PORT="$(echo "$HOSTPORT" | cut -d: -f2)"

  cat > "$CONF" <<EOF
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
http $HOST $PORT
EOF
fi

# Run original image entrypoint + args under proxychains
exec proxychains4 -q /usr/local/bin/entrypoint.sh "$@"
```

## Entrypoint Behaviour

The entrypoint script performs the following steps:

1. Mirrors uppercase proxy environment variables to lowercase equivalents
2. Configures apt proxy settings if the image uses Debian/Ubuntu tools
3. Installs `proxychains4` if it is missing
4. Generates a proxychains configuration if one was not mounted
5. Starts the original MCP Hub entrypoint through proxychains

The final command is:

```sh
exec proxychains4 -q /usr/local/bin/entrypoint.sh "$@"
```

The compose file passes:

```yaml
command: ["pnpm","start"]
```

So the original image entrypoint receives:

```bash
pnpm start
```

## Proxychains Configuration

```conf
strict_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000

# IMPORTANT: do NOT proxy connections to the proxy itself (avoid recursion)
localnet 10.137.0.162/32

# Also keep local traffic unproxied
localnet 127.0.0.0/8
localnet 10.0.0.0/8
localnet 172.16.0.0/12
localnet 192.168.0.0/16

[ProxyList]
http 10.137.0.162 3128
```

## Proxychains Behaviour

The proxychains configuration uses:

```conf
strict_chain
```

This forces proxied traffic through the configured proxy.

It also uses:

```conf
proxy_dns
```

This makes DNS lookups for proxied traffic happen through the proxy chain.

## Local Networks Excluded from Proxychains

The following networks are excluded:

```text
10.137.0.162/32
127.0.0.0/8
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

This is important because internal service traffic should not go through the corporate proxy.

The explicit exclusion for:

```text
10.137.0.162/32
```

prevents recursive proxying to the proxy server itself.

## Proxy Server

The proxy is:

```text
10.137.0.162:3128
```

Also mapped as:

```yaml
extra_hosts:
  - "proxy1.it.deakin.edu.au:10.137.0.162"
```

This allows the container to resolve:

```text
proxy1.it.deakin.edu.au
```

to:

```text
10.137.0.162
```

## Environment File

```env
MCPHUB_HTTP_PROXY=http://proxy1.it.deakin.edu.au:3128
MCPHUB_HTTPS_PROXY=http://proxy1.it.deakin.edu.au:3128
MCPHUB_NO_PROXY=localhost,127.0.0.1,::1,mcphub,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to,10.137.17.254,mcp-hub-mcphub-1
mcphub_http_proxy=http://proxy1.it.deakin.edu.au:3128
mcphub_https_proxy=http://proxy1.it.deakin.edu.au:3128
mcphub_no_proxy=localhost,127.0.0.1,::1,mcphub,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to,10.137.17.254,mcp-hub-mcphub-1
```

## Environment Variable Roles

### Build-Time Proxy Variables

The compose build args use:

```env
MCPHUB_HTTP_PROXY
MCPHUB_HTTPS_PROXY
MCPHUB_NO_PROXY
```

These are passed to the Dockerfile as:

```yaml
args:
  HTTP_PROXY: ${MCPHUB_HTTP_PROXY}
  HTTPS_PROXY: ${MCPHUB_HTTPS_PROXY}
  NO_PROXY: ${MCPHUB_NO_PROXY}
```

This allows npm and Playwright installation to work during image build.

### Runtime Proxy Variables

The compose runtime environment uses:

```yaml
environment:
  - HTTP_PROXY=${HTTP_PROXY}
  - HTTPS_PROXY=${HTTPS_PROXY}
  - NO_PROXY=${NO_PROXY}
```

This means the runtime container expects these variables to exist in the shell or `.env`.

If the `.env` only contains `MCPHUB_HTTP_PROXY` and not `HTTP_PROXY`, runtime proxy variables may be empty.

A safer `.env` pattern is:

```env
HTTP_PROXY=http://proxy1.it.deakin.edu.au:3128
HTTPS_PROXY=http://proxy1.it.deakin.edu.au:3128
NO_PROXY=localhost,127.0.0.1,::1,mcphub,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to,10.137.17.254,mcp-hub-mcphub-1

MCPHUB_HTTP_PROXY=http://proxy1.it.deakin.edu.au:3128
MCPHUB_HTTPS_PROXY=http://proxy1.it.deakin.edu.au:3128
MCPHUB_NO_PROXY=localhost,127.0.0.1,::1,mcphub,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to,10.137.17.254,mcp-hub-mcphub-1
```

## Node Fetch Test Script

```sh
docker exec -it mcp-hub-mcphub-1 sh -lc 'node -e "
(async () => {
  try {
    const r = await fetch(\"http://10.137.17.254:4045/health\", {
      headers: { Authorization: \"redacted\"}
    });
    console.log(\"status\", r.status);
    console.log(await r.text());
  } catch (e) {
    console.error(\"FETCH_ERR\", e);
  }
})();"'
```

## What the Node Fetch Test Does

This command runs a Node.js `fetch()` call from inside the MCP Hub container.

It tests whether the container can reach:

```text
http://10.137.17.254:4045/health
```

with an `Authorization` header.

This is useful for debugging MCP servers such as Wazuh or other internal HTTP services.

## Expected Fetch Test Result

A healthy result should show an HTTP status and response body, for example:

```text
status 200
{"status":"ok"}
```

A failure may show:

```text
FETCH_ERR TypeError: fetch failed
```

Common causes include:

- Target service is down
- Wrong port
- Authentication failure
- Proxy recursion
- Internal IP missing from `NO_PROXY`
- proxychains intercepting traffic that should be local
- Firewall or routing issue
- MCP service bound only to `127.0.0.1` instead of `0.0.0.0`

## Repo Security Scan Integration

The file:

```text
./repo_scan_job_mcp.js
```

is mounted into the MCP Hub container as:

```text
/app/repo_scan_job_mcp.js
```

It provides the `repo-security-scan` MCP integration.

This integration launches Semgrep scans as background Docker jobs and exposes tools such as:

```text
repo_list
repo_security_scan_start
repo_security_scan_status
repo_security_scan_result
repo_security_scan_list_jobs
```

## Docker Requirements for Repo Security Scan

The repo scan MCP requires:

1. Docker CLI inside the MCP Hub container
2. Docker socket mounted from the host
3. Repositories mounted at `/repos`
4. Correct `HOST_REPOS_BASE_DIR`
5. Semgrep image available or pullable

The Dockerfile provides the Docker CLI:

```dockerfile
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker
```

The compose file provides the Docker socket:

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

The compose file provides repository access:

```yaml
- /opt/redback/repos:/repos
```

## Recommended Repo Security Scan Environment

In `mcp_settings.json`, the `repo-security-scan` server should set environment variables similar to:

```json
{
  "REPOS_BASE_DIR": "/repos",
  "HOST_REPOS_BASE_DIR": "/opt/redback/repos",
  "JOBS_BASE_DIR": "/repos/logs/security-jobs",
  "SEMGREP_IMAGE": "semgrep/semgrep:1.159.0",
  "SEMGREP_JOBS": "2",
  "SEMGREP_PER_FILE_TIMEOUT": "2",
  "SEMGREP_TIMEOUT_THRESHOLD": "1",
  "SEMGREP_MAX_TARGET_BYTES": "500000",
  "JOB_RETENTION_LIMIT": "100"
}
```

If you want `/repos` to be read-only, use a separate job directory:

```json
{
  "JOBS_BASE_DIR": "/jobs"
}
```

And mount:

```yaml
- /opt/redback/repos:/repos:ro
- /opt/redback/security-jobs:/jobs
```

## Suggested Directory Layout

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

Host repositories are stored at:

```text
/opt/redback/repos
```

Inside the MCP Hub container they appear as:

```text
/repos
```

## Build and Start

Build the custom image:

```bash
docker compose build mcphub
```

Start MCP Hub:

```bash
docker compose up -d
```

Follow logs:

```bash
docker compose logs -f mcphub
```

Check status:

```bash
docker compose ps
```

## Rebuild After Dockerfile Changes

If you change the Dockerfile, rebuild without cache:

```bash
docker compose build --no-cache mcphub
docker compose up -d mcphub
```

## Restart After Settings Changes

If you change `mcp_settings.json`:

```bash
docker compose restart mcphub
```

Then check logs:

```bash
docker compose logs -f mcphub
```

## Validate Container Basics

Enter the container:

```bash
docker exec -it mcp-hub-mcphub-1 sh
```

Check proxy environment:

```bash
env | grep -i proxy
```

Check Docker CLI:

```bash
docker version
docker ps
```

Check repository mount:

```bash
ls -la /repos
```

Check MCP settings:

```bash
ls -la /app/mcp_settings.json
```

Check repo scan script:

```bash
ls -la /app/repo_scan_job_mcp.js
```

Check proxychains:

```bash
which proxychains4
cat /etc/proxychains.conf
```

## Validate Playwright

Inside the container:

```bash
npx playwright --version
```

Check installed Chromium browser files:

```bash
ls -la /root/.cache/ms-playwright || true
```

If Playwright complains that Chromium is missing, rebuild the image:

```bash
docker compose build --no-cache mcphub
docker compose up -d mcphub
```

## Validate Docker Socket Access

Inside the MCP Hub container:

```bash
docker ps
```

If this fails, check:

```bash
ls -la /var/run/docker.sock
```

If permission is denied, the container user may not have access to the Docker socket.

Possible fixes include:

- Run the container as a user with access to the Docker socket
- Adjust Docker socket group permissions
- Use a Docker socket proxy
- Run the MCP Hub container as root if appropriate for the environment

## Validate Repo Scan Docker Launch

Inside the MCP Hub container:

```bash
docker run --rm -v /opt/redback/repos:/repos:ro semgrep/semgrep:1.159.0 semgrep --version
```

If the Semgrep image cannot be pulled, check proxy access.

If the mount path is wrong, check that `/opt/redback/repos` exists on the Docker host.

## Validate Internal HTTP Access

Run the provided Node fetch test:

```bash
./nodefetch.sh
```

Or directly:

```bash
docker exec -it mcp-hub-mcphub-1 sh -lc 'node -e "
(async () => {
  try {
    const r = await fetch(\"http://10.137.17.254:4045/health\", {
      headers: { Authorization: \"redacted\"}
    });
    console.log(\"status\", r.status);
    console.log(await r.text());
  } catch (e) {
    console.error(\"FETCH_ERR\", e);
  }
})();"'
```

## Troubleshooting

### MCP Hub Does Not Start

Check logs:

```bash
docker compose logs mcphub
```

Common causes:

- Invalid `mcp_settings.json`
- Entrypoint script not executable
- Proxychains installation failure
- Missing proxy environment variables
- `pnpm start` failing inside the base image

Check script permissions:

```bash
chmod +x entrypoint-proxy.sh
```

### Proxychains Cannot Connect

Inspect proxychains config:

```bash
docker exec -it mcp-hub-mcphub-1 cat /etc/proxychains.conf
```

Check the proxy host:

```bash
docker exec -it mcp-hub-mcphub-1 getent hosts proxy1.it.deakin.edu.au
```

Check connection to proxy:

```bash
docker exec -it mcp-hub-mcphub-1 sh -lc 'nc -vz proxy1.it.deakin.edu.au 3128'
```

If `nc` is not installed, use another debug container or install netcat temporarily.

### Proxy Recursion

Proxy recursion can happen if the container tries to reach the proxy through the proxy.

This is why the proxy IP is excluded:

```conf
localnet 10.137.0.162/32
```

Also ensure it appears in `NO_PROXY`:

```text
10.137.0.162,proxy1.it.deakin.edu.au
```

### Internal MCP Server Connection Fails

For internal IPs such as:

```text
10.137.17.254
```

make sure they are in:

```env
NO_PROXY
MCPHUB_NO_PROXY
```

And that proxychains excludes the relevant network:

```conf
localnet 10.0.0.0/8
```

### Node Fetch Shows `bad port`

This can happen when proxy environment variables or Node/undici proxy handling are malformed.

Check:

```bash
docker exec -it mcp-hub-mcphub-1 env | grep -i proxy
```

Make sure proxy values look like:

```text
http://proxy1.it.deakin.edu.au:3128
```

and not like:

```text
proxy1.it.deakin.edu.au:3128
```

or values with hidden characters.

### MCP Server Bound to Localhost Only

If an HTTP MCP server runs in another container and binds only to `127.0.0.1`, MCP Hub will not be able to reach it.

The target MCP server should bind to:

```text
0.0.0.0
```

For FastMCP-based servers, this is often:

```env
FASTMCP_HOST=0.0.0.0
```

### Docker CLI Missing

Check:

```bash
docker exec -it mcp-hub-mcphub-1 which docker
```

If missing, rebuild the image:

```bash
docker compose build --no-cache mcphub
docker compose up -d mcphub
```

### Docker Socket Missing

Check:

```bash
docker exec -it mcp-hub-mcphub-1 ls -la /var/run/docker.sock
```

If missing, confirm the compose volume:

```yaml
- /var/run/docker.sock:/var/run/docker.sock
```

### Repositories Missing

Check on host:

```bash
ls -la /opt/redback/repos
```

Check inside container:

```bash
docker exec -it mcp-hub-mcphub-1 ls -la /repos
```

### Playwright Browser Missing

Rebuild the image:

```bash
docker compose build --no-cache mcphub
docker compose up -d mcphub
```

Then check logs for:

```text
npx playwright install chromium
```

## Security Notes

This deployment is powerful because MCP Hub has:

- Access to many MCP integrations
- Access to repositories under `/repos`
- Access to the Docker socket
- Access to internal network services
- Proxy-enabled outbound network access

Important safeguards:

- Keep MCP Hub on a trusted network.
- Do not expose port `3003` to untrusted clients.
- Protect `mcp_settings.json`, `.env`, and any credentials.
- Treat Docker socket access as equivalent to privileged host access.
- Keep repository mounts read-only where possible.
- Prefer separate writable job storage for scan outputs.
- Avoid logging secrets in test scripts or MCP server output.

## Recommended Hardening

Consider the following improvements:

- Put MCP Hub behind authentication.
- Use a reverse proxy with TLS.
- Restrict Docker socket access using a Docker socket proxy.
- Make `/opt/redback/repos` read-only in MCP Hub if possible.
- Use a separate `/jobs` volume for security scan outputs.
- Split high-risk MCP tools into a separate hub instance.
- Limit exposed tools per integration instead of using `"tools": "all"` everywhere.
- Store secrets in a secret manager or Docker secrets where practical.
- Add healthchecks for MCP Hub and critical MCP servers.
- Pin container image versions instead of using `latest`.
- Keep a known-good backup of `mcp_settings.json`.

## Useful Commands

### Start

```bash
docker compose up -d
```

### Stop

```bash
docker compose down
```

### Restart

```bash
docker compose restart mcphub
```

### Logs

```bash
docker compose logs -f mcphub
```

### Rebuild

```bash
docker compose build --no-cache mcphub
docker compose up -d mcphub
```

### Shell

```bash
docker exec -it mcp-hub-mcphub-1 sh
```

### Check Enabled Servers in Settings

```bash
docker exec -it mcp-hub-mcphub-1 sh -lc 'cat /app/mcp_settings.json'
```

### Check Proxy

```bash
docker exec -it mcp-hub-mcphub-1 env | grep -i proxy
```

### Check Docker Access

```bash
docker exec -it mcp-hub-mcphub-1 docker ps
```

### Check Repositories

```bash
docker exec -it mcp-hub-mcphub-1 ls -la /repos
```

## Summary

This MCP Hub configuration provides a proxy-aware MCP integration layer for a private AI stack.

It includes:

- MCP Hub exposed on host port `3003`
- Multiple MCP integrations enabled
- Playwright Chromium support
- Docker CLI support
- Docker socket access for repo scan jobs
- Repository access through `/repos`
- Custom proxychains entrypoint
- Corporate proxy support
- Internal network bypass rules
- A Node fetch test for validating internal HTTP connectivity

This setup is suitable for an internal lab or trusted private AI environment where MCP tools need access to repositories, browsers, databases, security systems, and internal HTTP services.
