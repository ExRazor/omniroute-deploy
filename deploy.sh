#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_SRC="$SCRIPT_DIR/container"
ENV_FILE="$SCRIPT_DIR/.env"
NGINX_TMPL="$CONTAINER_SRC/omniroute.nginx.tmpl"
COMPOSE_TMPL="$CONTAINER_SRC/docker-compose.yml.tmpl"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Podman-only paths
TMPL_FILE="$CONTAINER_SRC/omniroute.container.tmpl"
NETWORK_FILE="$CONTAINER_SRC/omniroute.network"
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/omniroute.container"

# --- Engine detection ---
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
else
  echo "❌ podman or docker not found." >&2
  exit 1
fi
echo "ℹ️  Container engine: $CONTAINER_CMD"

if [[ "$CONTAINER_CMD" == "docker" ]]; then
  if ! groups | grep -qw docker && [[ "$(id -u)" != "0" ]]; then
    echo "❌ User '$USER' is not in the docker group." >&2
    echo "   Run: sudo usermod -aG docker \$USER" >&2
    echo "   Then log out & back in, or run: newgrp docker" >&2
    exit 1
  fi
fi

command -v openssl >/dev/null 2>&1 || { echo "❌ openssl not found."; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "⚠️  .env created from .env.example. Fill in INITIAL_PASSWORD & DOMAIN then re-run."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

changed=false
if [[ -z "${JWT_SECRET:-}" ]]; then
  JWT_SECRET="$(openssl rand -hex 32)"
  sed -i "s#^JWT_SECRET=.*#JWT_SECRET=${JWT_SECRET}#" "$ENV_FILE"
  changed=true
fi
if [[ -z "${API_KEY_SECRET:-}" ]]; then
  API_KEY_SECRET="$(openssl rand -hex 32)"
  sed -i "s#^API_KEY_SECRET=.*#API_KEY_SECRET=${API_KEY_SECRET}#" "$ENV_FILE"
  changed=true
fi
[[ "$changed" == true ]] && echo "🔐 Empty secrets generated & saved to .env"

# Sync CONTAINER_HOST in .env with the detected engine
if [[ -n "${CONTAINER_HOST:-}" && "$CONTAINER_HOST" != "$CONTAINER_CMD" ]]; then
  sed -i "s#^CONTAINER_HOST=.*#CONTAINER_HOST=${CONTAINER_CMD}#" "$ENV_FILE"
  echo "ℹ️  CONTAINER_HOST in .env synced to: $CONTAINER_CMD"
fi
# ponytail: CONTAINER_HOST in .env is a custom var for the OmniRoute image entrypoint,
# NOT podman remote-client. But podman has a same-named env var that switches to
# remote mode. `set -a; source .env` exports it into the shell, podman reads it
# and rejects `podman unshare` ("remote podman client"). Unset here in the deploy
# script env — the container still receives the value via EnvironmentFile=.env / env_file.
unset CONTAINER_HOST

if [[ -z "${INITIAL_PASSWORD:-}" || "$INITIAL_PASSWORD" == "ganti-password-login-pertama" ]]; then
  echo "❌ INITIAL_PASSWORD is still empty/placeholder." >&2
  exit 1
fi
if [[ -z "${DOMAIN:-}" ]]; then
  echo "❌ DOMAIN in .env is still empty." >&2
  exit 1
fi

HOST_DATA_DIR="${HOST_DATA_DIR:-$SCRIPT_DIR/data}"
PORT="${PORT:-20128}"
LIVE_WS_PORT="${LIVE_WS_PORT:-20132}"

# ponytail: auto-derive live-WS exposure vars from DOMAIN so the user only sets
# DOMAIN in .env. Persist to .env so the container (reading via EnvironmentFile
# / env_file) sees them. The WS server image default binds 127.0.0.1 — unreachable
# from host port publish, so override to 0.0.0.0.
ensure_live_ws_env() {
  local name="$1" val="$2"
  if [[ -z "${!name:-}" ]]; then
    if grep -q "^${name}=" "$ENV_FILE"; then
      sed -i "s#^${name}=.*#${name}=${val}#" "$ENV_FILE"
    else
      echo "${name}=${val}" >> "$ENV_FILE"
    fi
    printf -v "$name" '%s' "$val"
    echo "ℹ️  ${name} auto-set to ${val}"
  fi
}
ensure_live_ws_env LIVE_WS_HOST 0.0.0.0
ensure_live_ws_env LIVE_WS_ALLOWED_ORIGINS "https://${DOMAIN}"
ensure_live_ws_env NEXT_PUBLIC_LIVE_WS_PUBLIC_URL "wss://${DOMAIN}/live-ws"

# --- Auto-detect base domain for cert path, if CERT_BASE_DOMAIN is empty ---
if [[ -z "${CERT_BASE_DOMAIN:-}" ]]; then
  CERT_BASE_DOMAIN="$(awk -F. '{ if (NF<=2) print $0; else print $(NF-1)"."$NF }' <<< "$DOMAIN")"
  echo "ℹ️  CERT_BASE_DOMAIN auto-detected from DOMAIN: ${CERT_BASE_DOMAIN}"
fi

mkdir -p "$HOST_DATA_DIR"
[[ "$CONTAINER_CMD" == "podman" ]] && mkdir -p "$QUADLET_DIR"

# ==================== Podman path ====================
if [[ "$CONTAINER_CMD" == "podman" ]]; then

  # Fix rootless Podman permissions: the 'node' user in the OmniRoute image is UID 1000,
  # BUT under rootless podman container-UID-1000 maps to a subordinate UID on the host
  # (not host UID 1000). So `podman unshare chown 1000:1000` MUST run every deploy
  # (idempotent) so the container can write to the bind mount. Without this,
  # OmniRoute falls back to /home/node/.omniroute (ephemeral overlay) -> settings
  # vanish on restart & /app/data stays empty. Guard `stat -c %u != 1000` skipped
  # this when the host user is UID 1000 (most common case) -> bug.
  podman unshare chown -R 1000:1000 "$HOST_DATA_DIR"
  echo "🔧 Permission $HOST_DATA_DIR chowned to 1000:1000 (UID of 'node' user in container)"

  rendered="$(sed \
    -e "s#__PORT__#${PORT}#g" \
    -e "s#__LIVE_WS_PORT__#${LIVE_WS_PORT}#g" \
    -e "s#__HOST_DATA_DIR__#${HOST_DATA_DIR}#g" \
    -e "s#__ENV_FILE__#${ENV_FILE}#g" \
    "$TMPL_FILE")"
  echo "$rendered" > "$QUADLET_FILE"
  echo "✅ Quadlet written to $QUADLET_FILE"

  cp "$NETWORK_FILE" "$QUADLET_DIR/omniroute.network"

  if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
    loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"
    echo "🔓 Linger enabled for user $USER"
  fi

  systemctl --user daemon-reload

  if ! systemctl --user cat omniroute.service >/dev/null 2>&1; then
    echo "❌ Unit omniroute.service not generated from the Quadlet." >&2
    echo "   Check: podman --version (needs >=4.4), and ensure /usr/lib/systemd/user-generators/podman-user-generator exists." >&2
    exit 1
  fi

  systemctl --user restart omniroute.service

# ==================== Docker path ====================
else

  # Fix permissions: the image runs as user 'node' (UID 1000). Docker does not use
  # user namespaces, so container UID 1000 = host UID 1000. If the host user is not
  # UID 1000, the container cannot write to $HOST_DATA_DIR -> DB is never created.
  if [[ "$(stat -c '%u' "$HOST_DATA_DIR")" != "1000" ]]; then
    sudo chown 1000:1000 "$HOST_DATA_DIR"
    echo "🔧 Permission $HOST_DATA_DIR chowned to 1000:1000 (UID of 'node' user in container)"
  fi

  rendered="$(sed \
    -e "s#__PORT__#${PORT}#g" \
    -e "s#__LIVE_WS_PORT__#${LIVE_WS_PORT}#g" \
    -e "s#__HOST_DATA_DIR__#${HOST_DATA_DIR}#g" \
    -e "s#__ENV_FILE__#${ENV_FILE}#g" \
    "$COMPOSE_TMPL")"

  echo "$rendered" > "$COMPOSE_FILE"
  echo "✅ docker-compose.yml written to $COMPOSE_FILE"

  docker compose -f "$COMPOSE_FILE" up -d --build

fi

echo -n "⏳ Waiting for OmniRoute to be ready"
ready=false
for _ in $(seq 1 20); do
  curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${PORT}" && { ready=true; break; }
  echo -n "."; sleep 3
done
echo ""
[[ "$ready" == true ]] && echo "🚀 Container running on 127.0.0.1:${PORT}" \
  || echo "⚠️  Not ready yet, check container logs."

# --- Setup nginx reverse proxy ---
CERT_DIR="/etc/ssl/${CERT_BASE_DOMAIN}"
if [[ ! -f "$CERT_DIR/cert.pem" || ! -f "$CERT_DIR/privkey.pem" ]]; then
  echo "⚠️  Cert not found at $CERT_DIR (cert.pem/privkey.pem). Skipping nginx setup."
  echo "   Container deploy succeeded; re-run this script after the cert is ready."
  exit 0
fi

CF_AUTH_ORIGIN_PULLS="${CF_AUTH_ORIGIN_PULLS:-false}"
if [[ "$CF_AUTH_ORIGIN_PULLS" == "true" && ! -f "$CERT_DIR/cloudflare_ca.pem" ]]; then
  echo "⚠️  CF_AUTH_ORIGIN_PULLS=true but $CERT_DIR/cloudflare_ca.pem is missing. Continuing without AOP."
  CF_AUTH_ORIGIN_PULLS=false
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "⚠️  nginx not found, skipping reverse proxy setup."
  exit 0
fi

if [[ -d /etc/nginx/sites-enabled ]]; then
  NGINX_CONF="/etc/nginx/sites-available/omniroute.conf"
  NGINX_LINK="/etc/nginx/sites-enabled/omniroute.conf"
else
  NGINX_CONF="/etc/nginx/conf.d/omniroute.conf"
  NGINX_LINK=""
fi

sudo mkdir -p "$(dirname "$NGINX_CONF")"
rendered="$(sed \
  -e "s#__DOMAIN__#${DOMAIN}#g" \
  -e "s#__CERT_BASE_DOMAIN__#${CERT_BASE_DOMAIN}#g" \
  -e "s#__PORT__#${PORT}#g" \
  -e "s#__LIVE_WS_PORT__#${LIVE_WS_PORT}#g" \
  "$NGINX_TMPL")"

if [[ "$CF_AUTH_ORIGIN_PULLS" == "true" ]]; then
  rendered="$(sed '/#__AOP_START__/d; /#__AOP_END__/d' <<< "$rendered")"
  echo "🔒 Authenticated Origin Pulls active (Cloudflare client cert required)"
else
  rendered="$(sed '/#__AOP_START__/,/#__AOP_END__/d' <<< "$rendered")"
  echo "ℹ️  Authenticated Origin Pulls disabled — ensure DNS is proxied (orange cloud) + SSL mode Full/Full strict in Cloudflare"
fi

echo "$rendered" | sudo tee "$NGINX_CONF" >/dev/null

if [[ -n "$NGINX_LINK" ]]; then
  sudo ln -sf "$NGINX_CONF" "$NGINX_LINK"
fi

if sudo nginx -t; then
  sudo systemctl reload nginx
  echo "✅ Reverse proxy active: https://${DOMAIN}"
else
  echo "❌ Invalid nginx config, check $NGINX_CONF manually. Reload aborted." >&2
  exit 1
fi

echo ""
if [[ "$CONTAINER_CMD" == "podman" ]]; then
  echo "   Container status : systemctl --user status omniroute"
  echo "   Container logs   : journalctl --user -u omniroute -f"
  echo "   Update image     : podman pull docker.io/diegosouzapw/omniroute:latest && systemctl --user restart omniroute"
else
  echo "   Container status : docker compose -f $COMPOSE_FILE ps"
  echo "   Container logs   : docker compose -f $COMPOSE_FILE logs -f"
  echo "   Update image     : docker compose -f $COMPOSE_FILE pull && docker compose -f $COMPOSE_FILE up -d"
fi
