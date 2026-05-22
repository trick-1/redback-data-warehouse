# Semgrep MCP Service

This service runs Semgrep as a Model Context Protocol (MCP) server using the `streamable-http` transport. It is intended to expose Semgrep scanning capability to an MCP hub or MCP-compatible client while mounting local repositories read-only.

## Service Overview

```yaml
semgrep-mcp:
  image: returntocorp/semgrep:latest
  command: ["semgrep", "mcp", "-t", "streamable-http", "-p", "4004"]
  environment:
    - FASTMCP_HOST=0.0.0.0
    - SEMGREP_ENABLE_VERSION_CHECK=0
    - HTTP_PROXY=${HTTP_PROXY}
    - HTTPS_PROXY=${HTTPS_PROXY}
    - NO_PROXY=localhost,127.0.0.1,::1,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to
  volumes:
    - /opt/redback/repos:/repos:ro
  working_dir: /repos
  ports:
    - "4004:4004"
  restart: unless-stopped
```

## What This Service Does

The `semgrep-mcp` container starts Semgrep in MCP server mode and exposes it over HTTP on port `4004`.

It can be used by an MCP hub, AI assistant, or other MCP-aware client to run Semgrep-based code analysis against repositories mounted into the container.

The mounted repository path is:

```text
/opt/redback/repos
```

Inside the container, this is available as:

```text
/repos
```

The volume is mounted read-only, so Semgrep can inspect code but cannot modify repository files.

## Key Settings

### Image

```yaml
image: returntocorp/semgrep:latest
```

Uses the official Semgrep container image.

### Command

```yaml
command: ["semgrep", "mcp", "-t", "streamable-http", "-p", "4004"]
```

Starts Semgrep as an MCP server using:

- `mcp` — run Semgrep in MCP server mode
- `-t streamable-http` — use streamable HTTP transport
- `-p 4004` — listen on port `4004`

### Host Binding

```yaml
FASTMCP_HOST=0.0.0.0
```

This makes the MCP server listen on all container interfaces.

This is important because some MCP servers default to `127.0.0.1`, which would make them reachable only inside the container itself.

### Version Check Disabled

```yaml
SEMGREP_ENABLE_VERSION_CHECK=0
```

Disables Semgrep version checking.

This is useful for repeatable container startup and avoids unnecessary outbound checks during service launch.

### Proxy Configuration

```yaml
HTTP_PROXY=${HTTP_PROXY}
HTTPS_PROXY=${HTTPS_PROXY}
NO_PROXY=localhost,127.0.0.1,::1,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to
```

The service supports outbound network access via the host proxy environment.

The `NO_PROXY` list excludes local services and known internal hosts from being routed through the proxy.

This is especially important when the Semgrep MCP server is being accessed by nearby containers or internal MCP routing services.

### Repository Mount

```yaml
volumes:
  - /opt/redback/repos:/repos:ro
```

Mounts local repositories into the container at `/repos`.

The `:ro` suffix makes the mount read-only.

This is recommended for code scanning services because Semgrep only needs to inspect files, not change them.

### Working Directory

```yaml
working_dir: /repos
```

Sets `/repos` as the default working directory inside the container.

This allows Semgrep to operate relative to the mounted repository directory.

### Port Mapping

```yaml
ports:
  - "4004:4004"
```

Maps container port `4004` to host port `4004`.

The service should be reachable from the host at:

```text
http://localhost:4004
```

Or from another machine/container using the host IP:

```text
http://<host-ip>:4004
```

### Restart Policy

```yaml
restart: unless-stopped
```

Docker will restart the service automatically unless it has been manually stopped.

## Example MCP Hub Configuration

An MCP hub entry may look similar to this:

```json
{
  "semgrep": {
    "type": "http",
    "url": "http://semgrep-mcp:4004/mcp"
  }
}
```

If the MCP hub is not on the same Docker network, use the host IP instead:

```json
{
  "semgrep": {
    "type": "http",
    "url": "http://10.137.0.162:4004/mcp"
  }
}
```

## Docker Network Notes

If another container needs to reach this service by name, both containers must be on the same Docker network.

For example, if your MCP hub is running on a network called `mcp-hub_default`, attach this service to that network:

```yaml
networks:
  default:
    external: true
    name: mcp-hub_default
```

Or define the service like this in a compose file that joins the existing network:

```yaml
services:
  semgrep-mcp:
    image: returntocorp/semgrep:latest
    command: ["semgrep", "mcp", "-t", "streamable-http", "-p", "4004"]
    environment:
      - FASTMCP_HOST=0.0.0.0
      - SEMGREP_ENABLE_VERSION_CHECK=0
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=localhost,127.0.0.1,::1,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to
    volumes:
      - /opt/redback/repos:/repos:ro
    working_dir: /repos
    ports:
      - "4004:4004"
    restart: unless-stopped
    networks:
      - mcp-hub_default

networks:
  mcp-hub_default:
    external: true
```

## Testing the Service

Start the service:

```bash
docker compose up -d semgrep-mcp
```

Check logs:

```bash
docker compose logs -f semgrep-mcp
```

Check that the container is running:

```bash
docker ps | grep semgrep-mcp
```

Test from the host:

```bash
curl -v http://localhost:4004/mcp
```

Test from another container on the same Docker network:

```bash
docker exec -it <mcp-hub-container> sh
curl -v http://semgrep-mcp:4004/mcp
```

If DNS resolution fails, check that both containers are on the same Docker network:

```bash
docker network inspect mcp-hub_default
```

## Troubleshooting

### MCP hub cannot connect

Check that Semgrep is listening on all interfaces:

```yaml
FASTMCP_HOST=0.0.0.0
```

Without this, the service may only listen on `127.0.0.1` inside the container.

### Connection refused

Confirm the container is running:

```bash
docker compose ps
```

Check logs:

```bash
docker compose logs semgrep-mcp
```

Check port binding:

```bash
docker port semgrep-mcp
```

### Host can connect, but another container cannot

Make sure both containers are on the same Docker network.

Check networks:

```bash
docker inspect semgrep-mcp | grep -A20 Networks
docker inspect <mcp-hub-container> | grep -A20 Networks
```

### Proxy issues

If the MCP hub or Semgrep service is trying to reach local services through the proxy, expand the `NO_PROXY` list.

Useful entries usually include:

```text
localhost,127.0.0.1,::1
```

Docker service names may also need to be added, for example:

```text
semgrep-mcp,mcp-hub
```

Example:

```yaml
NO_PROXY=localhost,127.0.0.1,::1,semgrep-mcp,mcp-hub,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to
```

### Repository path is empty

Check that the host path exists:

```bash
ls -la /opt/redback/repos
```

Check that files are visible inside the container:

```bash
docker exec -it semgrep-mcp sh
ls -la /repos
```

## Security Notes

The repository mount is read-only:

```yaml
/opt/redback/repos:/repos:ro
```

This reduces the risk of accidental file modification by the container.

If exposing this service beyond the local Docker network, place it behind appropriate authentication, firewalling, or reverse proxy controls.

Avoid exposing the MCP service directly to untrusted networks.

## Recommended Directory Layout

```text
/opt/redback/
└── repos/
    ├── repo-one/
    ├── repo-two/
    └── repo-three/
```

The Semgrep MCP server will see these as:

```text
/repos/repo-one
/repos/repo-two
/repos/repo-three
```

## Minimal Compose File

```yaml
services:
  semgrep-mcp:
    image: returntocorp/semgrep:latest
    command: ["semgrep", "mcp", "-t", "streamable-http", "-p", "4004"]
    environment:
      - FASTMCP_HOST=0.0.0.0
      - SEMGREP_ENABLE_VERSION_CHECK=0
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=localhost,127.0.0.1,::1,proxy1.it.deakin.edu.au,10.137.0.162,api.mcprouter.to
    volumes:
      - /opt/redback/repos:/repos:ro
    working_dir: /repos
    ports:
      - "4004:4004"
    restart: unless-stopped
```

## Operational Notes

Useful commands:

```bash
docker compose pull semgrep-mcp
docker compose up -d semgrep-mcp
docker compose logs -f semgrep-mcp
docker compose restart semgrep-mcp
docker compose down
```

To update the image:

```bash
docker compose pull semgrep-mcp
docker compose up -d semgrep-mcp
```

To confirm the image currently in use:

```bash
docker inspect semgrep-mcp --format '{{.Config.Image}}'
```

## Summary

This service provides a containerised Semgrep MCP endpoint for scanning mounted repositories.

It is designed to:

- Run as a long-lived Docker service
- Expose MCP over streamable HTTP
- Listen on port `4004`
- Use `/opt/redback/repos` as the host repository root
- Mount repositories read-only
- Support proxy-aware environments
- Integrate with an MCP hub or AI-assisted code analysis stack
