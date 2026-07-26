# omniroute-deploy

Minimal server deployment for [OmniRoute](https://github.com/diegosouzapw/OmniRoute) — the free AI gateway that routes 250+ providers through one `/v1` endpoint with auto-fallback, combos, and stacked token compression.

This repo contains only the deploy/undeploy scripts, templates, and env contract to run OmniRoute on a Linux server behind nginx. Built for podman (default) and docker.

## Architecture

- **OmniRoute** (`docker.io/diegosouzapw/omniroute:latest`) — the gateway. Only port `20128` is exposed/published. `/live-ws` (Combo Studio) is an internal WS daemon (loopback `20132`) proxied through the main port by OmniRoute itself; nginx just needs upgrade headers on that path.
- **Redis sidecar** (`redis:8-alpine`) — backs the distributed rate limiter and shared cache. Upstream guidance: *"Disabling Redis is not recommended (rate limiter will degrade to in-memory fallback)."* Runs as a second service (compose) / second quadlet (podman) on the shared `omniroute-net`; OmniRoute reaches it at `redis://redis:6379`. Data persists under `HOST_DATA_DIR/redis`.
- **nginx reverse proxy** — TLS termination, SSE-friendly `/` (streaming chat completions), and a dedicated `/live-ws` location with WebSocket upgrade headers.
- Optional **Cloudflare Authenticated Origin Pulls** (mTLS).

Intentionally not included (stripped as unnecessary for this topology):
- Headroom sidecar (extra compression proxy — OmniRoute already ships RTK + Caveman)
- Split API port mode (nginx fronts a single port)

## Requirements

- Linux server, rootless user with `sudo` for nginx/cert ops
- `podman >= 4.4` (preferred) or `docker` (+ user in `docker` group)
- `openssl`, `curl`, `nginx`
- TLS cert at `/etc/ssl/<base-domain>/{cert.pem,privkey.pem}` (Cloudflare Origin cert works)
- Optional: `cloudflare_ca.pem` at the same path for Authenticated Origin Pulls

## Quick start

```bash
git clone git@github.com:ExRazor/omniroute-deploy.git
cd omniroute-deploy
cp .env.example .env
# edit .env: set INITIAL_PASSWORD and DOMAIN
./deploy.sh
```

On first run, `deploy.sh`:
1. Detects podman/docker
2. Auto-generates `JWT_SECRET`, `API_KEY_SECRET`, and `OMNIROUTE_WS_BRIDGE_SECRET` if empty
3. Syncs `CONTAINER_HOST` in `.env` to the detected engine
4. Auto-derives `LIVE_WS_ALLOWED_ORIGINS` and `NEXT_PUBLIC_BASE_URL` from `DOMAIN`
5. Fixes bind-mount permissions — `1000:1000` for OmniRoute data, `999:999` for the Redis subdir (rootless podman `unshare chown` or docker `sudo chown`)
6. Renders the quadlets (podman: omniroute + omniroute-redis) or `docker-compose.yml` (docker) from templates
7. Starts the containers, waits for health
8. Writes the nginx config and reloads (if cert is present)

## Configuration

All runtime knobs live in `.env`. See [`.env.example`](.env.example) for the full contract and inline docs. Key vars:

| Variable | Required | Description |
|---|---|---|
| `INITIAL_PASSWORD` | yes | First-login admin password; must not be the placeholder |
| `DOMAIN` | yes | Public subdomain serving OmniRoute |
| `JWT_SECRET` | auto | Auto-generated if empty |
| `API_KEY_SECRET` | auto | Auto-generated if empty |
| `OMNIROUTE_WS_BRIDGE_SECRET` | auto | WebSocket bridge shared secret; auto-generated if empty |
| `STORAGE_ENCRYPTION_KEY` | auto | SQLite at-rest key; auto-generated on first boot if empty |
| `PORT` | default `20128` | OmniRoute port (loopback only, nginx fronts it) |
| `REDIS_URL` | default `redis://redis:6379` | Override only to point at an external Redis |
| `AUTH_COOKIE_SECURE` | default `true` | Must be true behind HTTPS (set by this repo) |
| `NEXT_PUBLIC_BASE_URL` | auto | Public origin for OAuth/dashboard links; auto-set from `DOMAIN` |
| `LIVE_WS_ALLOWED_ORIGINS` | auto | Live-WS origin allow-list; auto-set from `DOMAIN` |
| `NEXT_PUBLIC_LIVE_WS_PUBLIC_URL` | auto | Public WS URL for Combo Studio; auto-set from `DOMAIN` |
| `HOST_DATA_DIR` | default `./data` | Host path bind-mounted to `/app/data` (Redis data under `<HOST_DATA_DIR>/redis`) |
| `CERT_BASE_DOMAIN` | auto | Base domain for cert path; auto-detected from `DOMAIN` |
| `CF_AUTH_ORIGIN_PULLS` | default `false` | Require Cloudflare client cert (mTLS) |

## Operations

```bash
# redeploy / pick up .env changes
./deploy.sh

# stop + remove container/quadlet/compose, keep data & nginx config
./undeploy.sh

# full teardown
./undeploy.sh --all

# selective
./undeploy.sh --purge-data      # delete ./data
./undeploy.sh --purge-nginx     # remove nginx config
./undeploy.sh --remove-images   # also remove the omniroute image
```

Status & logs:

```bash
# podman
systemctl --user status omniroute omniroute-redis
journalctl --user -u omniroute -f

# docker
docker compose -f docker-compose.yml ps
docker compose -f docker-compose.yml logs -f
```

Update image:

```bash
# podman
podman pull docker.io/diegosouzapw/omniroute:latest && systemctl --user restart omniroute
# docker
docker compose -f docker-compose.yml pull && docker compose -f docker-compose.yml up -d
```

## Repo layout

```
.
├── deploy.sh                          # main deploy script (podman + docker)
├── undeploy.sh                        # teardown script
├── .env.example                       # env contract (copy to .env)
└── container/
    ├── omniroute.container.tmpl       # podman quadlet template (OmniRoute)
    ├── omniroute-redis.container.tmpl # podman quadlet template (Redis sidecar)
    ├── omniroute.network              # podman network quadlet
    ├── docker-compose.yml.tmpl        # docker compose template (OmniRoute + Redis)
    └── omniroute.nginx.tmpl           # nginx vhost template
```

## Notes

- `CONTAINER_HOST` in `.env` is OmniRoute's own var (tells the image entrypoint which runtime it's under). It collides with podman's same-named remote-client env var, so `deploy.sh` unsets it in its own shell after syncing — the container still receives it via `EnvironmentFile`/`env_file`.
- Rootless podman needs `podman unshare chown` every deploy because container UIDs map to subordinate UIDs on the host: `1000:1000` for OmniRoute's `node` user, `999:999` for the Redis subdir. Docker skips the unshare (1:1 UID mapping) but still chowns if the host dir isn't already owned by the right UID.
- `stop-timeout=40s` (podman) / `stop_grace_period: 40s` (docker) gives SQLite WAL and Redis RDB time to checkpoint on shutdown.

## License

Deployment scripts only. OmniRoute itself is © its upstream authors — see [diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute).
