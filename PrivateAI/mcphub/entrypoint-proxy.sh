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
# --- after proxychains is installed + config exists ---

# Run original image entrypoint + args under proxychains
exec proxychains4 -q /usr/local/bin/entrypoint.sh "$@"
