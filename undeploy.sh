#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Podman-only paths
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/omniroute.container"
REDIS_QUADLET="$QUADLET_DIR/omniroute-redis.container"
NETWORK_QUADLET="$QUADLET_DIR/omniroute.network"

# --- Engine detection ---
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
else
  echo "❌ podman or docker not found." >&2
  exit 1
fi

PURGE_DATA=false
PURGE_NGINX=false
REMOVE_IMAGES=false
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --purge-data)     PURGE_DATA=true ;;
    --purge-nginx)   PURGE_NGINX=true ;;
    --remove-images) REMOVE_IMAGES=true ;;
    --yes|-y)        ASSUME_YES=true ;;
    --all)           PURGE_DATA=true; PURGE_NGINX=true; REMOVE_IMAGES=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  read -rp "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HOST_DATA_DIR="${HOST_DATA_DIR:-$SCRIPT_DIR/data}"
DOMAIN="${DOMAIN:-}"

# ==================== Podman path ====================
if [[ "$CONTAINER_CMD" == "podman" ]]; then

  if systemctl --user list-unit-files 2>/dev/null | grep -q omniroute.service; then
    systemctl --user stop omniroute.service 2>/dev/null || true
    systemctl --user disable omniroute.service 2>/dev/null || true
    echo "🛑 Service omniroute stopped & disabled"
  fi
  if systemctl --user list-unit-files 2>/dev/null | grep -q omniroute-redis.service; then
    systemctl --user stop omniroute-redis.service 2>/dev/null || true
    systemctl --user disable omniroute-redis.service 2>/dev/null || true
    echo "🛑 Service omniroute-redis stopped & disabled"
  fi

  if [[ -f "$QUADLET_FILE" || -f "$REDIS_QUADLET" || -f "$NETWORK_QUADLET" ]]; then
    rm -f "$QUADLET_FILE" "$REDIS_QUADLET" "$NETWORK_QUADLET"
    systemctl --user daemon-reload
    echo "🗑️  Quadlets removed: omniroute, omniroute-redis, network"
  fi

  podman rm -f omniroute >/dev/null 2>&1 && echo "🗑️  Container omniroute removed" || true
  podman rm -f redis >/dev/null 2>&1 && echo "🗑️  Container redis removed" || true

  if [[ "$REMOVE_IMAGES" == true ]]; then
    podman rmi -f docker.io/diegosouzapw/omniroute:latest >/dev/null 2>&1 \
      && echo "🗑️  Image omniroute removed" || true
    podman image prune -f >/dev/null 2>&1 || true
  fi

# ==================== Docker path ====================
else

  if [[ -f "$COMPOSE_FILE" ]]; then
    down_opts="down"
    [[ "$REMOVE_IMAGES" == true ]] && down_opts="down --rmi all"
    docker compose -f "$COMPOSE_FILE" $down_opts
    rm -f "$COMPOSE_FILE"
    echo "🗑️  docker-compose.yml removed"
  else
    echo "ℹ️  No docker-compose.yml found."
  fi

fi

# --- Purge data (optional) ---
if [[ "$PURGE_DATA" == true ]]; then
  if confirm "Delete data at $HOST_DATA_DIR (database, provider, combo, api key)?"; then
    rm -rf "$HOST_DATA_DIR"
    echo "🗑️  Data removed: $HOST_DATA_DIR"
  fi
fi

# --- Purge nginx config (optional) ---
if [[ "$PURGE_NGINX" == true ]]; then
  CONF_A="/etc/nginx/sites-available/omniroute.conf"
  LINK_A="/etc/nginx/sites-enabled/omniroute.conf"
  CONF_B="/etc/nginx/conf.d/omniroute.conf"

  found=false
  [[ -f "$CONF_A" || -L "$LINK_A" || -f "$CONF_B" ]] && found=true

  if [[ "$found" == true ]]; then
    if confirm "Delete nginx config for ${DOMAIN:-omniroute}?"; then
      sudo rm -f "$LINK_A" "$CONF_A" "$CONF_B"
      if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "🗑️  nginx config removed & nginx reloaded"
      else
        echo "⚠️  nginx -t failed after removing config, check manually before reload." >&2
      fi
    fi
  else
    echo "ℹ️  No omniroute nginx config found."
  fi
fi

echo "✅ Undeploy complete."
[[ "$PURGE_DATA" == false ]]    && echo "   (data still present, use --purge-data to remove)"
[[ "$PURGE_NGINX" == false ]]  && echo "   (nginx config still present, use --purge-nginx to remove)"
[[ "$REMOVE_IMAGES" == false ]] && echo "   (images still present, use --remove-images to remove)"
