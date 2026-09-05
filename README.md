# RedisCloud

Docker-based Redis runtime for production and staging. Host automation (`magic.sh`) installs Docker, brings Redis up, tunes kernel overcommit for Redis, and can configure host Nginx **stream** (TCP proxy) alongside the published Redis port.

**Host OS:** Ubuntu/Debian (EC2 `ubuntu` or the user you SSH in as).  
**Compose CLI:** `docker compose` (V2 plugin) preferred; `docker-compose` (V1 standalone) used as fallback. Both work through `run_compose`.

---

## Architecture

```
Clients / app servers
   │
   ▼
Host :REDIS_PORT  ────────────────────────────────┐
   published by Docker as ${REDIS_PORT}:6379       │
   (0.0.0.0 by default — firewall recommended)     │
                                                   │
   optional: Nginx stream                          │
   /etc/nginx/stream-conf.d/${ENV}_${APP_NAME}_${REDIS_PORT}.conf
   listen REDIS_PORT → proxy_pass 127.0.0.1:REDIS_PORT
                                                   │
                                                   ▼
                              Redis container
                              ${ENV}_${APP_NAME}_redis
                              image: redis:${REDIS_VERSION}
                              │
                              ├── redis.conf  (ro mount)
                              ├── requirepass / maxmemory (CLI flags from .env)
                              └── ./data → /data  (AOF + RDB)
```

| Resource | Name / path |
|---|---|
| Container | `${ENV}_${APP_NAME}_redis` |
| Network | `${ENV}_${APP_NAME}_network` (bridge) |
| Config | `./redis.conf` → `/usr/local/etc/redis/redis.conf` (read-only) |
| Data | `./data` → `/data` (bind mount; gitignored) |
| Stream config | `/etc/nginx/stream-conf.d/${ENV}_${APP_NAME}_${REDIS_PORT}.conf` |

**Auth model:** password is passed as `redis-server … --requirepass ${REDIS_PASSWORD}`. The same value is set as `REDISCLI_AUTH` so healthchecks and in-container `redis-cli` work without repeating `-a`.

**Docker privileges:** scripts run as the login user. If the session is not yet in the `docker` group, they call `sudo docker` / `sudo docker compose` (passwordless on typical EC2 `ubuntu`). Do not use `newgrp` (it can hang the installer).

---

## Quick start

```bash
cp .env.example .env
# edit .env — REDIS_PASSWORD, REDIS_PORT, APP_NAME, ENV, memory limits
chmod +x magic.sh
./magic.sh
```

Typical first-host order:

1. **Install Docker & Docker Compose**
2. **Docker Compose Up**
3. **Create NGINX Server Block** (optional; only if you use the stream template)

After Docker install, log out and back in once if you want `docker` without sudo. Until then, `magic.sh` already falls back to `sudo docker`.

---

## magic.sh options

| Option | What it does |
|---|---|
| Install Docker & Docker Compose | `apt install docker.io docker-compose`; enable/start Docker; add login user to `docker` group |
| Docker Compose Up | `vm.overcommit_memory=1`; ensure Nginx/stream readiness; `compose up -d --remove-orphans` |
| Docker Compose Recreate (pull + force-recreate) | `pull` + `up -d --force-recreate` after `.env` / `redis.conf` / image tag changes. Does **not** delete `./data` |
| Docker Compose Down | Stop this project's containers only. Does **not** delete images or `./data` |
| Docker PS | `docker ps` |
| Goto Bash | Interactive `sh` as root in `${ENV}_${APP_NAME}_redis` |
| Delete All Unused Docker Images | `docker image prune -a -f` (images only — never volumes / `./data`) |
| Set Swap Memory | Create `/swapfile` (`1G`, `512M`, …); `M` and `G` sizes calculated correctly |
| Create NGINX Server Block | Install Nginx with stream if needed; write TCP proxy from `bash/reverse_proxy.conf`; asks before overwrite |
| Delete NGINX Server Block | Remove stream config from `stream-conf.d` and reload Nginx |
| Quit | Exit |

---

## Project layout

```
RedisCloud/
├── magic.sh                 Menu entrypoint (set -euo pipefail)
├── docker-compose.yml       Redis service definition
├── redis.conf               Server config (mounted read-only)
├── .env.example             Copy to .env (gitignored)
├── data/                    Persistence directory (AOF/RDB) — gitignored
├── README.md                This document
└── bash/
    ├── utility.sh           Env loader, prompts, swap, overcommit
    ├── docker.sh            run_docker / run_compose, install, up/down/recreate, prune
    ├── nginx.sh             Host Nginx + stream inject / create / delete
    └── reverse_proxy.conf   Nginx stream template
```

---

## Environment reference

All keys live in RedisCloud `.env` (never commit it). Values are loaded with a safe `KEY=VALUE` parser (not shell-sourced).

| Variable | Default | Purpose |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `prod_abc` | Compose project name |
| `APP_NAME` | `abc` | Used in container / network / stream config names |
| `ENV` | `prod` | Used in container / network / stream config names |
| `REDIS_PORT` | `6379` | Host port mapped to container `6379` |
| `MEMORY_LIMIT` | `512M` | Docker `mem_limit` for the container |
| `REDIS_MAXMEMORY` | `400mb` | Redis `maxmemory` CLI flag (keep **below** `MEMORY_LIMIT`) |
| `REDIS_VERSION` | `7.2-alpine` | Image tag: `redis:${REDIS_VERSION}` |
| `REDIS_PASSWORD` | *(required)* | `--requirepass` and `REDISCLI_AUTH` |

### When to Up vs Recreate

| Change | Menu action |
|---|---|
| Routine restart / container stopped | **Docker Compose Up** |
| `REDIS_PASSWORD`, `REDIS_MAXMEMORY`, `MEMORY_LIMIT`, `REDIS_VERSION` | **Docker Compose Recreate** |
| Edits to `redis.conf` | **Docker Compose Recreate** (config is mounted; Redis must restart to reload) |

---

## How the stack works

### Compose service (`docker-compose.yml`)

- **Image:** official `redis:${REDIS_VERSION}` (default Alpine).
- **Command:** `redis-server /usr/local/etc/redis/redis.conf --requirepass … --maxmemory …`  
  Password and maxmemory come from `.env` so they can change without editing `redis.conf`.
- **Ports:** `${REDIS_PORT}:6379` on all host interfaces (same contract as existing production clients). Restrict with host firewall/`ufw`.
- **mem_limit:** Docker hard memory cap (`MEMORY_LIMIT`). Prefer this over Swarm-only `deploy.resources`.
- **Healthcheck:** `redis-cli ping` every 30s (auth via `REDISCLI_AUTH`).
- **Logging:** `json-file`, `max-size=10m`, `max-file=3` to avoid disk fill.
- **Restart:** `unless-stopped`.

### `redis.conf` (in-container)

| Area | Behavior |
|---|---|
| Network | `bind 0.0.0.0`, `port 6379`, `protected-mode yes` |
| Security | `FLUSHALL`, `FLUSHDB`, `CONFIG`, `SHUTDOWN` renamed to empty (disabled) |
| Memory | `maxmemory-policy allkeys-lru`; lazyfree eviction/expire enabled. Actual `maxmemory` bytes come from CLI/`REDIS_MAXMEMORY` |
| Persistence | RDB `save 3600 1` + AOF `appendonly yes` / `appendfsync everysec` under `/data` |
| Clients | `maxclients 20000` |
| Process | `daemonize no` (required under Docker) |

Do not enable renamed commands in production without a deliberate security review.

### Kernel: `vm.overcommit_memory`

**Docker Compose Up** and **Recreate** call `fix_memory_overcommit`, which sets `vm.overcommit_memory=1` immediately and persists it in `/etc/sysctl.conf`. Redis recommends this to avoid background save / fork issues under memory pressure.

### Host Nginx stream (optional)

`bash/nginx.sh`:

1. Installs `nginx-extras` when Nginx is missing (stream module required).
2. Ensures `/etc/nginx/stream-conf.d/` exists and that `nginx.conf` includes a `stream { include … }` block.
3. Renders `bash/reverse_proxy.conf` → `/etc/nginx/stream-conf.d/${ENV}_${APP_NAME}_${REDIS_PORT}.conf`.
4. Asks before overwriting an existing stream file; runs `nginx -t` then reload (restart fallback).

Template behavior:

```nginx
upstream {{ENV}}_{{APP_NAME}} {
    server 127.0.0.1:{{REDIS_PORT}};
}
server {
    listen {{REDIS_PORT}};
    proxy_pass {{ENV}}_{{APP_NAME}};
    …
}
```

**Operational note:** Docker already publishes `${REDIS_PORT}` on the host. A stream `listen` on the **same** port as the Redis publish cannot both bind successfully. Use the stream block only when your topology needs it (e.g. different port strategy later). Do **not** change `REDIS_PORT` or bind mode cold on a live production host without a maintenance window and client retest.

### Compose CLI resolution (`run_compose`)

Order of attempts:

1. `docker compose …` (current user)
2. `docker-compose …` (current user)
3. `sudo docker compose …`
4. `sudo docker-compose …`

---

## Production notes

- Run `./magic.sh` as the SSH user (`ubuntu`), not as a custom app user, unless that user has passwordless sudo.
- **Compose Down never passes `--volumes` or `--rmi`.** Persistence is the `./data` bind mount; deleting it is a manual operator action only.
- Image prune is host-wide unused images only; it does not prune volumes or `./data`.
- Keep `REDIS_MAXMEMORY` < `MEMORY_LIMIT` so Redis can LRU-evict before the cgroup OOM-kills the container.
- Rotate / protect `REDIS_PASSWORD`; Recreate after rotation so the container and healthcheck pick up the new secret.
- Prefer **Up** for routine restarts; use **Recreate** when config or image tag changes.
- Firewall: allow Redis only from known app CIDRs. Do not leave `REDIS_PORT` open to `0.0.0.0/0` unless intentional.
- Back up `./data` (AOF + RDB) with host-level backup; stop or `BGSAVE` carefully if you need a consistent filesystem snapshot.

---

## Client connection

From an application (password required):

```text
host: <server-public-or-private-ip>
port: <REDIS_PORT from .env>
password: <REDIS_PASSWORD from .env>
db: 0   # redis.conf sets databases 1
```

Example `redis-cli` from the host (container running):

```bash
docker exec -it ${ENV}_${APP_NAME}_redis redis-cli ping
# PONG  (uses REDISCLI_AUTH inside the container)
```

From another machine:

```bash
redis-cli -h <host> -p <REDIS_PORT> -a '<REDIS_PASSWORD>' ping
```

---

## Troubleshooting

**`docker: permission denied`**

`magic.sh` should still work via `sudo docker`. To use `docker` directly, log out and back in after install so the `docker` group applies.

**Port already in use on Compose Up**

If this project's Redis container already owns `REDIS_PORT`, Up/Recreate proceeds and recreates as needed. If another process owns the port, stop it or change `REDIS_PORT` (breaking for existing clients — plan a cutover).

**Redis warns about memory overcommit**

Run **Docker Compose Up** (or Recreate), or:

```bash
sudo sysctl -w vm.overcommit_memory=1
```

**Auth / healthcheck failures**

Confirm `REDIS_PASSWORD` in `.env` matches clients, then **Recreate**. Inspect:

```bash
docker inspect --format='{{json .State.Health}}' ${ENV}_${APP_NAME}_redis
docker logs ${ENV}_${APP_NAME}_redis --tail 100
```

**Container OOM / frequent restarts**

Raise `MEMORY_LIMIT` and `REDIS_MAXMEMORY` together (maxmemory still below mem_limit), then Recreate. Check `docker stats` and `dmesg` for OOM killer.

**Data missing after Down**

Down does not delete `./data`. If data is gone, something else removed the bind-mount directory or the process was started from a different working directory / project path. Verify you are in the same RedisCloud checkout that owns `./data`.

**Nginx stream / `nginx -t` fails**

```bash
sudo nginx -t
sudo less /etc/nginx/stream-conf.d/${ENV}_${APP_NAME}_${REDIS_PORT}.conf
sudo systemctl status nginx
```

Ensure `nginx -V 2>&1 | grep stream` shows stream support (`nginx-extras` / `nginx-full`).

**Goto Bash: `bash: not found`**

Alpine images provide `sh` only. The menu uses `sh` deliberately.

---

## License

MIT
