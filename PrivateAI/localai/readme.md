# LocalAI GPU Service with PostgreSQL Knowledge Base

This compose service runs LocalAI with NVIDIA CUDA 12 GPU support and a PostgreSQL-backed LocalRecall knowledge base.

It is designed for a private AI stack where LocalAI provides the OpenAI-compatible API, model hosting, agent memory, skills, image outputs, and backend management.

To setup you will need to copy the env file to .env and then generate a new API key for clients to connect.

## Service Overview

```yaml
services:
  localai:
    container_name: local-ai
    hostname: localai
    image: localai/localai:latest-gpu-nvidia-cuda-12
    restart: unless-stopped
    ports:
      - 4000:8080
        #network_mode: host
    runtime: nvidia
    deploy: {}

    # Compose v2:
    gpus: all

    environment:
      # Keep core behaviour
      #- LOCALAI_SINGLE_ACTIVE_BACKEND=true
      # Outbound proxy for model/gallery downloads
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      # Don't proxy internal Docker traffic
      - NO_PROXY=localhost,127.0.0.1,::1,localai,postgres,mcphub,mcp-hub-mcphub-1

      #- BACKENDS=llama-cpp
      #- DISABLE_BACKEND_AUTODETECT=true
      - AUTO_LOAD_MODELS=false
      #- AUTO_UPDATE_MODELS=true
      - DISABLE_TELEMETRY=true
      - HEALTHCHECKS=false
      - DISABLE_GRAMMAR=true
      - DISABLE_TOKENIZER_CHECKS=true
      #- DEFAULT_MODEL=llama-3.3-70b-instruct
      - MCP_HEADERS={"Accept":"application/json, text/event-stream"}
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
      - DEBUG=true
      - LOCALAI_LOG_LEVEL=debug
      #- LOGLEVEL=trace
      #- LOCALAI_AUTOLOAD_GALLERIES=false
      # - LOCALAI_GALLERIES=[]
      #- LOCALAI_DATA_PATH=/data
      # PostgreSQL-backed knowledge base
      - LOCALAI_AGENT_POOL_VECTOR_ENGINE=postgres
      - LOCALAI_AGENT_POOL_DATABASE_URL=postgresql://localrecall:localrecall@postgres:5432/localrecall?sslmode=disable
      #- LOCALAI_AGENT_POOL_DEFAULT_MODEL=hermes-3-llama3.1-8b-lorablated
      # disabled this and nominated gemma4 so that we don't double up on models that are running, save some GPU memory
      - LOCALAI_AGENT_POOL_DEFAULT_MODEL=gemma-4-e4b-it
      - LOCALAI_AGENT_POOL_EMBEDDING_MODEL=granite-embedding-107m-multilingual
      - LOCALAI_AGENT_POOL_ENABLE_SKILLS=true
      - LOCALAI_AGENT_POOL_ENABLE_LOGS=true
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "5"
    volumes:
      - /opt/redback/privateai/volumes/models:/models:cached
      - /opt/redback/privateai/volumes/images/:/tmp/generated/images/
      - /opt/redback/privateai/volumes/backends:/usr/share/localai/backends
      - /opt/redback/privateai/volumes/localai_data:/data
      - /opt/redback/privateai/volumes/localai_config:/etc/localai


      # Make libcuda visible to backends that overwrite LD_LIBRARY_PATH:
      #- /usr/lib/x86_64-linux-gnu/libcuda.so.1:/backends/cuda12-stablediffusion-ggml/lib/libcuda.so.1:ro
      #- /usr/lib/x86_64-linux-gnu/libcuda.so.1:/backends/cuda12-llama-cpp/lib/libcuda.so.1:ro
      #
      #

  postgres:
    image: quay.io/mudler/localrecall:v0.5.2-postgresql
    environment:
      - POSTGRES_DB=localrecall
      - POSTGRES_USER=localrecall
      - POSTGRES_PASSWORD=localrecall

      # Runtime: don't force HTTP(S)_PROXY, just no-proxy for internal services
      - NO_PROXY=localhost,127.0.0.1,::1,localai,postgres,mcphub,mcp-hub-mcphub-1
    volumes:
      - /opt/redback/privateai/volumes/localai_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U localrecall"]
      interval: 10s
      timeout: 5s
      retries: 5
```

## What This Stack Provides

This compose file starts two main services:

- `localai` — the LocalAI inference/API service using the CUDA 12 NVIDIA GPU image.
- `postgres` — a PostgreSQL-backed LocalRecall database used by LocalAI agent memory and knowledge base features.

LocalAI is exposed on host port `4000`, mapped to container port `8080`.

The API endpoint is therefore:

```text
http://localhost:4000
```

From another Docker container on the same network, the service should be reachable as:

```text
http://localai:8080
```

## LocalAI Service

### Image

```yaml
image: localai/localai:latest-gpu-nvidia-cuda-12
```

This uses the LocalAI GPU image built for NVIDIA CUDA 12.

This is suitable for hosts with NVIDIA GPUs, the NVIDIA driver installed, Docker installed, and NVIDIA Container Toolkit configured.

### Container Name and Hostname

```yaml
container_name: local-ai
hostname: localai
```

The explicit hostname `localai` is useful for internal Docker service resolution and for other services that need to call the LocalAI API.

### Port Mapping

```yaml
ports:
  - 4000:8080
```

This maps the LocalAI API to the host on port `4000`.

Use:

```bash
curl http://localhost:4000/v1/models
```

Or from a remote machine:

```bash
curl http://<host-ip>:4000/v1/models
```

## GPU Configuration

The service enables NVIDIA GPU access using both the legacy runtime setting and Compose v2 GPU syntax:

```yaml
runtime: nvidia
gpus: all
```

The NVIDIA environment variables are:

```yaml
- NVIDIA_VISIBLE_DEVICES=all
- NVIDIA_DRIVER_CAPABILITIES=compute,utility
```

These allow the container to access all visible GPUs for compute workloads and NVIDIA utility functions such as `nvidia-smi`.

### GPU Validation

After startup, test GPU visibility:

```bash
docker exec -it local-ai nvidia-smi
```

If this fails, check the host first:

```bash
nvidia-smi
```

Then verify Docker GPU access:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

## Proxy Configuration

The LocalAI service passes through outbound proxy settings:

```yaml
- HTTP_PROXY=${HTTP_PROXY}
- HTTPS_PROXY=${HTTPS_PROXY}
```

These are useful for model downloads, gallery downloads, and other outbound network access.

Internal Docker traffic is excluded from the proxy using:

```yaml
- NO_PROXY=localhost,127.0.0.1,::1,localai,postgres,mcphub,mcp-hub-mcphub-1
```

This prevents calls to nearby containers from being routed through the external proxy.

If additional internal services are added, append them to `NO_PROXY`.

Example:

```yaml
- NO_PROXY=localhost,127.0.0.1,::1,localai,postgres,mcphub,mcp-hub-mcphub-1,litellm,semantic-router
```

## Core LocalAI Behaviour

### Model Autoloading

```yaml
- AUTO_LOAD_MODELS=false
```

Automatic model loading is disabled.

This helps avoid loading every available model at startup and gives more direct control over GPU memory usage.

### Telemetry Disabled

```yaml
- DISABLE_TELEMETRY=true
```

Disables telemetry.

### Healthchecks Disabled

```yaml
- HEALTHCHECKS=false
```

Disables LocalAI healthchecks.

This can reduce noisy healthcheck behaviour during debugging or when backends take a long time to initialise.

### Grammar and Tokenizer Checks Disabled

```yaml
- DISABLE_GRAMMAR=true
- DISABLE_TOKENIZER_CHECKS=true
```

These settings reduce startup and runtime issues with some model/backend combinations.

### Debug Logging

```yaml
- DEBUG=true
- LOCALAI_LOG_LEVEL=debug
```

Enables verbose debug output from LocalAI.

This is useful when troubleshooting backend loading, model startup, memory issues, MCP connectivity, or knowledge base behaviour.

## MCP Headers

```yaml
- MCP_HEADERS={"Accept":"application/json, text/event-stream"}
```

This configures request headers for MCP interactions.

The `text/event-stream` accept value is important for streamable HTTP MCP servers.

## PostgreSQL-Backed Agent Pool and Knowledge Base

LocalAI is configured to use PostgreSQL as the vector engine:

```yaml
- LOCALAI_AGENT_POOL_VECTOR_ENGINE=postgres
```

The connection string points to the `postgres` service:

```yaml
- LOCALAI_AGENT_POOL_DATABASE_URL=postgresql://localrecall:localrecall@postgres:5432/localrecall?sslmode=disable
```

The database credentials are defined in the `postgres` service:

```yaml
- POSTGRES_DB=localrecall
- POSTGRES_USER=localrecall
- POSTGRES_PASSWORD=localrecall
```

## Agent Pool Models

### Default Agent Pool Model

```yaml
- LOCALAI_AGENT_POOL_DEFAULT_MODEL=gemma-4-e4b-it
```

This selects `gemma-4-e4b-it` as the default agent pool model.

The intent is to avoid doubling up on GPU-heavy models and reduce unnecessary GPU memory use.

### Embedding Model

```yaml
- LOCALAI_AGENT_POOL_EMBEDDING_MODEL=granite-embedding-107m-multilingual
```

This model is used for embeddings in the LocalAI agent pool and knowledge base workflows.

## Skills and Logs

```yaml
- LOCALAI_AGENT_POOL_ENABLE_SKILLS=true
- LOCALAI_AGENT_POOL_ENABLE_LOGS=true
```

These enable LocalAI agent skills and logs.

This is useful when using LocalAI as part of an agent-oriented private AI stack.

## Volumes

The service uses host-mounted volumes under:

```text
/opt/redback/privateai/volumes
```

### Model Storage

```yaml
- /opt/redback/privateai/volumes/models:/models:cached
```

Stores LocalAI models.

Inside the container, models are available at:

```text
/models
```

### Generated Images

```yaml
- /opt/redback/privateai/volumes/images/:/tmp/generated/images/
```

Stores generated image outputs.

### Backend Storage

```yaml
- /opt/redback/privateai/volumes/backends:/usr/share/localai/backends
```

Stores LocalAI backend binaries and backend-related files.

This allows backends to persist across container restarts.

### LocalAI Data

```yaml
- /opt/redback/privateai/volumes/localai_data:/data
```

Stores LocalAI data.

Note that the same host path is also used by the PostgreSQL service as its database directory:

```yaml
- /opt/redback/privateai/volumes/localai_data:/var/lib/postgresql/data
```

If you want stricter separation between LocalAI application data and PostgreSQL database files, consider using separate paths, for example:

```yaml
- /opt/redback/privateai/volumes/localai_data:/data
- /opt/redback/privateai/volumes/postgres_data:/var/lib/postgresql/data
```

### LocalAI Config

```yaml
- /opt/redback/privateai/volumes/localai_config:/etc/localai
```

Stores LocalAI configuration files.

## Logging

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "20m"
    max-file: "5"
```

This limits Docker JSON logs to five files of 20 MB each.

This prevents LocalAI debug logs from filling the host disk.

## PostgreSQL Service

The PostgreSQL service uses the LocalRecall PostgreSQL image:

```yaml
image: quay.io/mudler/localrecall:v0.5.2-postgresql
```

It creates a database called:

```text
localrecall
```

With username:

```text
localrecall
```

And password:

```text
localrecall
```

## PostgreSQL Healthcheck

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U localrecall"]
  interval: 10s
  timeout: 5s
  retries: 5
```

This checks that PostgreSQL is accepting connections.

## Suggested Directory Layout

```text
/opt/redback/privateai/
└── volumes/
    ├── models/
    ├── images/
    ├── backends/
    ├── localai_data/
    └── localai_config/
```

Create the directories before starting the stack:

```bash
sudo mkdir -p /opt/redback/privateai/volumes/models
sudo mkdir -p /opt/redback/privateai/volumes/images
sudo mkdir -p /opt/redback/privateai/volumes/backends
sudo mkdir -p /opt/redback/privateai/volumes/localai_data
sudo mkdir -p /opt/redback/privateai/volumes/localai_config
```

Set ownership if running Docker as your user:

```bash
sudo chown -R "$USER:$USER" /opt/redback/privateai/volumes
```

## Starting the Stack

Start both services:

```bash
docker compose up -d
```

Start only PostgreSQL:

```bash
docker compose up -d postgres
```

Start LocalAI:

```bash
docker compose up -d localai
```

Follow logs:

```bash
docker compose logs -f localai
```

Check PostgreSQL logs:

```bash
docker compose logs -f postgres
```

## Basic API Tests

List models:

```bash
curl http://localhost:4000/v1/models
```

Check LocalAI root endpoint:

```bash
curl http://localhost:4000
```

Test from another container on the same Docker network:

```bash
curl http://localai:8080/v1/models
```

## Useful Operational Commands

Pull the latest LocalAI image:

```bash
docker compose pull localai
```

Recreate the service after pulling:

```bash
docker compose up -d localai
```

Restart LocalAI:

```bash
docker compose restart localai
```

View running containers:

```bash
docker compose ps
```

Stop the stack:

```bash
docker compose down
```

Stop the stack and remove anonymous volumes:

```bash
docker compose down -v
```

## Troubleshooting

### LocalAI cannot see the GPU

Check the host:

```bash
nvidia-smi
```

Check Docker GPU support:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

Check inside the LocalAI container:

```bash
docker exec -it local-ai nvidia-smi
```

### LocalAI cannot reach PostgreSQL

Check the PostgreSQL container:

```bash
docker compose ps postgres
docker compose logs postgres
```

Check name resolution from LocalAI:

```bash
docker exec -it local-ai sh
getent hosts postgres
```

Check the PostgreSQL port from inside LocalAI:

```bash
docker exec -it local-ai sh
nc -vz postgres 5432
```

If `nc` is not installed in the container, use a temporary debug container on the same Docker network.

### Internal traffic is going through the proxy

Make sure all internal service names are included in `NO_PROXY`.

Current value:

```text
localhost,127.0.0.1,::1,localai,postgres,mcphub,mcp-hub-mcphub-1
```

Add any additional internal services, such as:

```text
litellm,semantic-router,openwebui,semgrep-mcp
```

### Model does not load automatically

This is expected because:

```yaml
- AUTO_LOAD_MODELS=false
```

Load or select models explicitly through LocalAI configuration, API calls, model galleries, or mounted model files.

### Debug logs are very noisy

Debugging is enabled:

```yaml
- DEBUG=true
- LOCALAI_LOG_LEVEL=debug
```

Once the service is stable, reduce log verbosity by setting:

```yaml
- DEBUG=false
- LOCALAI_LOG_LEVEL=info
```

Or remove those environment variables.

## Notes on Shared `localai_data`

This compose file maps the same host path to both:

```text
/data
```

For LocalAI, and:

```text
/var/lib/postgresql/data
```

For PostgreSQL.

That may work depending on the intended LocalAI layout, but it is usually cleaner to separate application data from database data.

Recommended alternative:

```yaml
localai:
  volumes:
    - /opt/redback/privateai/volumes/localai_data:/data

postgres:
  volumes:
    - /opt/redback/privateai/volumes/postgres_data:/var/lib/postgresql/data
```

This makes backups, restores, and troubleshooting easier.

## Security Notes

The database credentials in this compose file are simple defaults:

```text
localrecall / localrecall
```

For production or shared environments, change the database password and update:

```yaml
LOCALAI_AGENT_POOL_DATABASE_URL
```

Do not expose the LocalAI API port directly to untrusted networks without authentication, firewalling, or a reverse proxy.

## Summary

This compose stack runs LocalAI with:

- NVIDIA CUDA 12 GPU support
- OpenAI-compatible API access on host port `4000`
- Persistent model, backend, image, data, and config volumes
- Debug logging enabled
- Proxy-aware outbound access
- PostgreSQL-backed LocalAI agent pool and knowledge base support
- Skills and agent logs enabled
- Docker log rotation to prevent runaway logs
