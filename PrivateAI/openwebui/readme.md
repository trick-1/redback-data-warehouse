# OpenWebUI (Docker Compose + Caddy + Microsoft Entra ID)

This bundle runs **OpenWebUI** behind a **Caddy** reverse proxy with **HTTPS** (self‑signed cert) and **Microsoft Entra ID (OAuth/OIDC)** login enabled.  
It is also pre-wired to talk to an **OpenAI-compatible API** (e.g. LocalAI) via `OPENAI_API_BASE_URL`.

> **Security note:** The included `dot.env.example` contains placeholder/example values.  
> Treat any secrets as **compromised** if they were ever committed or shared—rotate them in Microsoft Entra and your model backend.

---

## What’s in this tarball

```
openwebui/
  docker-compose-entra.yaml
  dot.env.example
  caddy/
    Caddyfile
    Caddyfile.orig
    certs/
      local.crt
      local.key
    caddy_data/...
    caddy_config/...
```

### File-by-file: what each configuration does

#### `docker-compose-entra.yaml`
Defines **two services** on the same Docker network:

- **`openwebui`**
  - Image: `ghcr.io/open-webui/open-webui:main`
  - Exposes port `8080` **only to the internal Docker network** (`expose:`) — not published to the host.
  - Persists OpenWebUI state in `./data` (mounted to `/app/backend/data`).
  - Enables:
    - local login form (`ENABLE_LOGIN_FORM=true`)
    - OAuth/OIDC (`ENABLE_OIDC=true`, `OAUTH_MICROSOFT_ENABLED=true`)
    - auth (`WEBUI_AUTH=true`)
    - safe mode (`SAFE_MODE=true`)
  - Routes model calls to an OpenAI-compatible endpoint:
    - `OPENAI_API_BASE_URL=http://10.137.17.254:9443/v1`
    - `OPENAI_API_KEY=$LOCALAI_API_KEY` (read from `.env`)
  - Supports proxies via `HTTP_PROXY` / `HTTPS_PROXY` from `.env` and a `NO_PROXY` list.

- **`caddy`**
  - Image: `caddy:latest`
  - Publishes ports:
    - `80:80` (HTTP redirect to HTTPS)
    - `443:443` (HTTPS)
    - `3000:443` (optional alternate access to the same HTTPS listener)
  - Mounts:
    - `./caddy/Caddyfile` to `/etc/caddy/Caddyfile`
    - `./caddy/certs` to `/etc/caddy/certs` (read-only) for TLS cert/key
    - `./caddy_data` and `./caddy_config` for Caddy runtime state

> ⚠️ **Potential typo:** the compose includes `ENABLE_SIGNPUT=true`.  
> OpenWebUI uses `ENABLE_SIGNUP`. If you have issues with signup, change it to `ENABLE_SIGNUP=true`.

---

#### `dot.env.example`
An example environment file you copy to `.env` and edit. It provides:

- `HTTP_PROXY`, `HTTPS_PROXY` – outbound proxy settings (optional)
- `MICROSOFT_CLIENT_ID` – Entra app registration client ID
- `MICROSOFT_CLIENT_SECRET` – Entra app registration client secret
- `MICROSOFT_CLIENT_TENANT_ID` – Entra tenant ID (or `common`/`organizations` depending on your setup)
- `LOCALAI_API_KEY` – API key for your OpenAI-compatible backend (LocalAI, etc.)

> ⚠️ The comments in this example file are slightly mismatched (tenant vs secret).  
> Use the variable names as the source of truth.

---

#### `caddy/Caddyfile`
Caddy reverse proxy + TLS configuration:

- Disables Caddy auto-HTTPS (`auto_https off`) so it **only** uses the provided cert.
- HTTP listener `:80` **redirects** to `https://10.137.17.254{uri}`.
- HTTPS listener `:443`:
  - Uses the self-signed TLS cert:
    - cert: `/etc/caddy/certs/local.crt`
    - key:  `/etc/caddy/certs/local.key`
  - Proxies traffic to OpenWebUI at `http://openwebui:8080`.

> ⚠️ The redirect + public URL are hard-coded to `10.137.17.254`.  
> If your host IP/domain differs, update:
> - `caddy/Caddyfile` (redirect target)
> - `WEBUI_URL` and `MICROSOFT_REDIRECT_URI` in the compose

---

#### `caddy/Caddyfile.orig`
A prior/original version of the Caddyfile kept for reference.

---

#### `caddy/certs/local.crt` and `caddy/certs/local.key`
A **self-signed** TLS certificate and private key used by Caddy for HTTPS.

- Browsers will show a certificate warning unless you **trust** the certificate on your machine.
- For a production deployment, replace these with a proper certificate (e.g., Let’s Encrypt with a real domain).

---

#### `caddy/caddy_data/*` and `caddy/caddy_config/*`
Caddy’s persisted runtime state:

- `caddy_data` – instance UUID, lock files, last-clean metadata, etc.
- `caddy_config/caddy/autosave.json` – Caddy’s autosaved config snapshot (generated/maintained by Caddy)

You normally **do not edit** these manually.

---

## Prerequisites

- Docker + Docker Compose plugin (`docker compose version`)
- Ports **80** and **443** available on the host (and optionally **3000**)
- If you’ll use Entra login:
  - A Microsoft Entra App Registration with a redirect URI matching your deployment URL.

---

## Quick start

### 1) Extract the tarball
From the directory containing the tar:

```bash
tar -xf openwebui.tar
cd openwebui
```

### 2) Create your `.env`
Copy the example and edit values:

```bash
cp dot.env.example .env
nano .env
```

At minimum, set:

- `LOCALAI_API_KEY=...`
- `MICROSOFT_CLIENT_ID=...`
- `MICROSOFT_CLIENT_SECRET=...`
- `MICROSOFT_CLIENT_TENANT_ID=...`

Optionally set proxy variables (or delete them if not needed).

### 3) Update host/IP references (recommended)
This bundle is hardcoded to `10.137.17.254`.

Search & replace in:

- `caddy/Caddyfile` (redirect line)
- `docker-compose-entra.yaml`:
  - `WEBUI_URL`
  - `MICROSOFT_REDIRECT_URI`
  - (optionally) `OPENAI_API_BASE_URL` if your model endpoint differs

### 4) Start the stack
Run:

```bash
docker compose --env-file .env -f docker-compose-entra.yaml up -d
```

Check logs:

```bash
docker compose -f docker-compose-entra.yaml logs -f --tail=200
```

Stop:

```bash
docker compose -f docker-compose-entra.yaml down
```

---

## Accessing OpenWebUI

- Primary (standard HTTPS): `https://<your-host>/`
- Optional alternate mapping: `https://<your-host>:3000/`

Because the certificate is self-signed, your browser will warn unless you trust `caddy/certs/local.crt`.

### Trusting the self-signed cert (quick guidance)

- **macOS:** Keychain Access → System (or Login) → Certificates → Import `local.crt` → set to “Always Trust”.
- **Windows:** `certmgr.msc` → Trusted Root Certification Authorities → Certificates → Import `local.crt`.
- **Linux:** depends on distro; typically copy to `/usr/local/share/ca-certificates/` and run `update-ca-certificates`.

---

## Microsoft Entra ID (OAuth/OIDC) notes

In Entra App Registration:

- Add a **Redirect URI** matching:
  - `https://<your-host>/oauth/microsoft/callback`
- Ensure the app is configured for the correct tenant type:
  - Single-tenant: use your tenant ID
  - Multi-tenant/personal: you may need `common` and adjust scopes/claims

This compose sets:
- `OAUTH_SCOPES=["openid","profile","email"]`
- `OAUTH_EMAIL_CLAIM=preferred_username`
- `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`

> The compose includes `ENABLE_OAUTH_WITHOUT_EMAIL=true` (marked as a workaround).  
> If you don’t need it, consider disabling it for cleaner account semantics.

---

## Troubleshooting

### Port 80/443 already in use
- Another service (nginx, Traefik, etc.) may be listening.
- Either stop the conflicting service or change the published ports in the `caddy` service.

### Redirect goes to the wrong IP
Update the `redir` target in `caddy/Caddyfile`.

### OAuth login loops or fails
- Confirm the redirect URI matches **exactly** (scheme/host/path).
- Confirm the tenant setting and the `MICROSOFT_CLIENT_*` values in `.env`.
- Check OpenWebUI logs for OAuth errors.

### OpenWebUI can’t reach the model backend
- Confirm `OPENAI_API_BASE_URL` is reachable **from inside Docker**.
- If the backend runs on the Docker host, `host.docker.internal` is available due to `extra_hosts`.

---

## Data persistence

- OpenWebUI data is stored in `./data` (in the `openwebui/` folder).
- Caddy state is stored in `./caddy/caddy_data` and `./caddy/caddy_config`.

Back up those directories if you want to preserve state.

---
