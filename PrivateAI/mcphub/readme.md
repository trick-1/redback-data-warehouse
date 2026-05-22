# MCPHub — Install & Configuration Guide

This folder contains a small **Docker Compose** deployment for **MCPHub** plus supporting configuration files for running behind a corporate proxy (e.g. Deakin).  
It is designed so you can unpack the tarball, adjust a few values, and run the service reliably.

before starting copy env file to .env

> **Security note:** The provided configs include placeholders and/or example secrets (API keys, bearer tokens, hashed admin password).  
> Treat them as **defaults** and rotate/replace before exposing the service beyond a trusted network.

---

## Contents

After extracting `mcphub.tar`, you should have:

```text
mcphub/
├── docker-compose.yaml
├── entrypoint-proxy.sh
├── proxychains.conf
└── mcp_settings.json
```

---

## Quick install

### 1) Extract

```bash
tar -xf mcphub.tar
cd mcphub
```

### 2) Create an `.env` file

Create `mcphub/.env` (recommended) with your proxy settings:

```env
# Outbound proxy (optional but required in restricted networks)
HTTP_PROXY=http://proxy1.it.deakin.edu.au:3128
HTTPS_PROXY=http://proxy1.it.deakin.edu.au:3128

# Internal destinations that must NOT be proxied
NO_PROXY=localhost,127.0.0.1,::1,mcphub,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to
```

If you’re not behind a proxy, you can omit `HTTP_PROXY` / `HTTPS_PROXY` and rely on direct outbound access.

### 3) Start MCPHub

```bash
docker compose up -d
```

### 4) Verify

The Compose file maps container port **3000** to host port **3003**:

- MCPHub UI/API: `http://<host>:3003`

Check logs:

```bash
docker compose logs -f --tail=200
```

---

## Configuration files

## `docker-compose.yaml`

**Purpose:** Runs the `samahappy/mcphub` image with local configuration injected via bind mounts, plus proxy environment variables.

Key sections:

- **`image: samanhappy/mcphub`**  
  Uses a prebuilt MCPHub container image.

- **`ports: "3003:3000"`**  
  Exposes MCPHub on **host port 3003**.

- **`volumes:`**  
  Mounts your configuration into the container:
  - `./mcp_settings.json` → `/app/mcp_settings.json` *(read-only)*  
    Main MCPHub configuration (servers, users, routing, providers).
  - `./entrypoint-proxy.sh` → `/app/entrypoint-proxy.sh` *(read-only)*  
    Wrapper entrypoint to ensure proxy support works inside container.
  - `./proxychains.conf` → `/etc/proxychains.conf` *(read-only)*  
    Proxychains config (forces outbound TCP via your proxy).

- **`environment:`**
  - `HTTP_PROXY`, `HTTPS_PROXY` are passed through from `.env`
  - `NO_PROXY` ensures internal calls (including Docker DNS names) are not proxied

- **`extra_hosts:`**
  - `"proxy1.it.deakin.edu.au:10.137.0.162"`  
    Forces resolution of the proxy hostname inside the container (useful if DNS can’t resolve it).

- **`entrypoint:` / `command:`**
  - Entry is overridden to run `/app/entrypoint-proxy.sh`
  - Then runs MCPHub via `pnpm start`

---

## `entrypoint-proxy.sh`

**Purpose:** Makes proxy behaviour reliable inside the container by:

1. Normalising proxy env vars (`HTTP_PROXY` → `http_proxy`, etc.)
2. Configuring `apt` to use the proxy (if `apt-get` exists)
3. Installing `proxychains4` (or `proxychains-ng`) if missing
4. Ensuring a proxychains config exists (uses `/etc/proxychains.conf` or generates one from proxy env vars)
5. Running the container’s original entrypoint under proxychains:

```sh
exec proxychains4 -q /usr/local/bin/entrypoint.sh "$@"
```

**Why this matters:** Some tools ignore `HTTP_PROXY`/`HTTPS_PROXY` for certain network calls.  
Proxychains forces TCP connections through the proxy when needed.

---

## `proxychains.conf`

**Purpose:** Defines how proxychains routes traffic.

Notable directives:

- `strict_chain`  
  Use the proxies in the listed order.
- `proxy_dns`  
  Resolve DNS through proxychains (helps in locked-down DNS scenarios).
- Timeouts:
  - `tcp_read_time_out 15000`
  - `tcp_connect_time_out 8000`

Local network bypasses (important):

- `localnet 10.137.0.162/32`  
  Prevents proxying traffic *to the proxy itself* (avoids recursion).
- Also bypasses:
  - `127.0.0.0/8`
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`

Proxy list:

- `http 10.137.0.162 3128`

If your proxy changes, update this file (or rely on auto-generation from env vars by removing the mounted file).

---

## `mcp_settings.json`

**Purpose:** The main MCPHub configuration file.

It contains several top-level sections:

### `mcpServers`
Defines MCP servers MCPHub can launch and route to. This file includes examples such as:

- `playwright` / `playwright-mcp` (Playwright MCP server)
- `fetch` / `fetch-mcp` (fetch MCP server)
- `time` / `time-mcp` (time MCP server)
- `slack` (Slack MCP server; requires tokens)
- `sequential-thinking` (reasoning helper server)
- `mindmap` (mindmap server)
- `amap` (Amap maps server; requires API key)

Each server entry generally looks like:

```json
{
  "command": "npx",
  "args": ["-y", "@some/package"],
  "env": { "SOME_KEY": "your-value" }
}
```

**What to edit:**
- Replace placeholder API keys (e.g. `SLACK_BOT_TOKEN`, `AMAP_MAPS_API_KEY`)
- Remove servers you don’t want MCPHub to expose
- Pin versions if you need reproducible deployments

### `users`
Defines MCPHub users. The sample includes an `admin` user with a **bcrypt hashed password**.

**What to edit:**
- Replace the default password hash with your own
- Consider disabling password auth if you are using bearer/OAuth only (depends on your deployment model)

### `systemConfig`
Controls platform-wide behaviour. Notable subsections include:

- **`routing`**
  - `enableGlobalRoute`: global routing on/off
  - `enableGroupNameRoute`: group-based routing on/off
  - `enableBearerAuth`: bearer auth on/off
  - `bearerAuthKey`: bearer token key (rotate before public exposure)

- **`install`**
  - `baseUrl`: base URL used by MCPHub (ensure it matches your deployment)
  - `pythonIndexUrl` / `npmRegistry`: optional private registries

- **`oauthServer`**
  Enables an embedded OAuth server and controls lifetimes and registration behaviour.
  If you don’t need OAuth, set `enabled` to `false`.

- **`mcpRouter`**
  Contains settings for the upstream routing API (including API key, base URL, referer/title).  
  Treat API keys here as secrets.

### `providers`
Defines LLM providers MCPHub can talk to. The sample includes a LocalAI provider entry (OpenAI-compatible):
- `base_url`: your LocalAI endpoint
- `models`: list of model IDs you want available through this provider

Update this to match your LocalAI host and model list.

### `groups`
Defines groups and which servers/tools are available to each group.

### `bearerKeys`
Defines bearer tokens and access scoping:
- `accessType: all` allows everything (tighten if needed)
- `allowedGroups` / `allowedServers` can restrict access

---

## Recommended hardening (if exposing beyond LAN)

- Put MCPHub behind a reverse proxy (Nginx/Caddy/Traefik) with TLS
- Rotate/replace:
  - bearer auth token(s)
  - any `mcpRouter.apiKey`
  - admin password hash
  - any third-party API tokens (Slack, Amap, etc.)
- Restrict allowed servers/tools to the minimum needed
- Consider network policies/firewall rules to limit who can reach port 3003

---

## Common changes

### Change the host port
Edit `docker-compose.yaml`:

```yaml
ports:
  - "3003:3000"
```

For example, to run on 8088:

```yaml
ports:
  - "8088:3000"
```

### Change the proxy target
Update `proxychains.conf` and/or `.env`, plus `extra_hosts` if required.

---

## Troubleshooting

### Proxy loops / “connection refused” to proxy
Make sure `proxychains.conf` includes a `localnet` rule for the proxy IP itself (it already does for `10.137.0.162/32`).

### NPM/Python installs fail
- Confirm `HTTP_PROXY`/`HTTPS_PROXY` are correct
- If you use private registries, set `systemConfig.install.npmRegistry` / `pythonIndexUrl`

### MCP server packages change unexpectedly
Pin versions in `mcpServers` (avoid `@latest` where reproducibility matters).

---

## License / Attribution

This repository contains **deployment configuration and documentation**.  
MCPHub and MCP servers remain under their respective upstream licenses.
