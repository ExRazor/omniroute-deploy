# omniroute-deploy

Minimal server deployment for [OmniRoute](https://github.com/diegosouzapw/OmniRoute) — the free AI gateway that routes 250+ providers through one `/v1` endpoint with auto-fallback, combos, and stacked token compression.

This repo contains only the deploy/undeploy scripts, templates, and env contract to run OmniRoute on a Linux server behind nginx. Built for podman (default) and docker.

## What it deploys

- OmniRoute container (`docker.io/diegosouzapw/omniroute:latest`)
- nginx reverse proxy with TLS + SSE-friendly `/` location and WebSocket `/live-ws` location (for Combo Studio live view)
- Optional Cloudflare Authenticated Origin Pulls (mTLS)

Not included (stripped as unnecessary for a pure proxy/route setup):
- Redis sidecar (dashboard perf cache)
- Headroom sidecar (extra compression proxy — OmniRoute already ships RTK + Caveman)
- Split API port mode

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
2. Auto-generates `JWT_SECRET` and `API_KEY_SECRET` if empty
3. Syncs `CONTAINER_HOST` in `.env` to the detected engine
4. Auto-derives Live-WS vars from `DOMAIN` (`LIVE_WS_HOST`, `LIVE_WS_ALLOWED_ORIGINS`, `NEXT_PUBLIC_LIVE_WS_PUBLIC_URL`)
5. Fixes bind-mount permissions (rootless podman `unshare chown` or docker `sudo chown 1000:1000`)
6. Renders the quadlet (podman) or `docker-compose.yml` (docker) from templates
7. Starts the container, waits for health
8. Writes the nginx config and reloads (if cert is present)

## Configuration

All runtime knobs live in `.env`. See [`.env.example`](.env.example) for the full contract and inline docs. Key vars:

| Variable | Required | Description |
|---|---|---|
| `INITIAL_PASSWORD` | yes | First-login admin password; must not be the placeholder |
| `DOMAIN` | yes | Public subdomain serving OmniRoute |
| `JWT_SECRET` | auto | Auto-generated if empty |
| `API_KEY_SECRET` | auto | Auto-generated if empty |
| `STORAGE_ENCRYPTION_KEY` | auto | SQLite at-rest key; auto-generated on first boot if empty |
| `PORT` | default `20128` | OmniRoute main port (loopback only, nginx fronts it) |
| `LIVE_WS_PORT` | default `20132` | Combo Studio live WebSocket port |
| `HOST_DATA_DIR` | default `./data` | Host path bind-mounted to `/app/data` |
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
systemctl --user status omniroute
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
    ├── omniroute.container.tmpl       # podman quadlet template
    ├── omniroute.network              # podman network quadlet
    ├── docker-compose.yml.tmpl        # docker compose template
    └── omniroute.nginx.tmpl           # nginx vhost template
```

## Notes

- `CONTAINER_HOST` in `.env` is OmniRoute's own var (tells the image entrypoint which runtime it's under). It collides with podman's same-named remote-client env var, so `deploy.sh` unsets it in its own shell after syncing — the container still receives it via `EnvironmentFile`/`env_file`.
- Rootless podman needs `podman unshare chown 1000:1000 ./data` every deploy because container UID 1000 maps to a subordinate UID on the host. Docker skips this — its UID mapping is 1:1.
- `stop-timeout=40s` (podman) / `stop_grace_period: 40s` (docker) gives SQLite WAL time to checkpoint on shutdown.

## License

Deployment scripts only. OmniRoute itself is © its upstream authors — see [diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute).
