# Caddy Gateway

[![CI](https://github.com/spilbros/caddy-docker-gateway/actions/workflows/ci.yml/badge.svg)](https://github.com/spilbros/caddy-docker-gateway/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A centralized HTTP(S) ingress gateway for self-hosted infrastructure.

`caddy-docker-gateway` is a custom build of [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
with the [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) plugin.

It provides:

* automatic reverse proxy configuration through Docker labels;
* wildcard TLS certificates using Cloudflare DNS-01 challenge;
* a single public entry point for multiple isolated Docker Compose stacks.

The gateway acts as shared infrastructure. Applications such as
`gitea-dockerized`, `meshctl`, and other services consume it without being
tightly coupled to its deployment.

---

## Features

* **Single ingress point**

  Only ports `80` and `443` are exposed on the host.
  All public services are routed through a single Caddy instance.

* **Docker label-based discovery**

  New services can be published by adding Docker labels.
  No manual Caddyfile editing is required.

* **Wildcard TLS**

  A single wildcard certificate:

  ```
  *.example.com
  ```

  covers all service subdomains.

* **Hardened Docker API access**

  Caddy never touches the Docker socket directly. All Docker API calls go
  through a read-only [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
  that exposes only container/network metadata and events on an internal,
  egress-free network. See [Security](#security).

* **Project independence**

  Each application remains fully standalone and can still be deployed with its own internal Caddy instance.
  When running inside this infrastructure, the built-in proxy can simply be disabled.

---

## Requirements

* Docker Engine
* Docker Compose v2
* A domain managed by Cloudflare
* A Cloudflare API token with DNS edit permissions

---

## Architecture

```
                         Internet
                            │
                       80/443 (host)
                            │
                    ┌───────▼────────┐      ┌──────────────────┐
                    │  caddy-proxy   │      │ docker-socket-   │
                    │                │──────│ proxy            │
                    │ Wildcard TLS   │ tcp  │                  │
                    │ DNS-01 (CF)    │ 2375 │ /var/run/docker. │
                    └───────┬────────┘      │ sock (ro)        │
                            │               └──────────────────┘
                            │            (docker_socket_net, internal)
                            │
                 caddy_proxy_net (external)
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
 ┌──────▼──────┐     ┌──────▼──────┐     ┌──────▼──────┐
 │   Gitea     │     │  Headscale  │     │    3x-ui    │
 │             │     │             │     │             │
 │ application │     │ application │     │ application │
 └─────────────┘     └─────────────┘     └─────────────┘
```

Each service runs inside its own Compose stack.

The only shared component is the external Docker network:

```
caddy_proxy_net
```

This allows `caddy-proxy` to discover and reach containers by name regardless of which repository
or directory manages the service.

---

## Security

Design decisions and their rationale:

* **Docker socket isolation.**
  Mounting `/var/run/docker.sock` into an internet-facing container is
  equivalent to giving it root on the host. Here the socket is mounted only
  into `docker-socket-proxy`, which:

  * allows exclusively the read-only endpoints `caddy-docker-proxy` needs
    (`CONTAINERS`, `NETWORKS`, `INFO`, events/ping/version);
  * blocks **all** mutating requests (`POST=0`);
  * lives on `docker_socket_net` — an `internal: true` network with no
    gateway, unreachable from application stacks and from the internet.

  Even a full compromise of the Caddy container yields read-only metadata
  access, not host control.

* **Least-privilege Cloudflare token.**
  A scoped API token (`Zone > DNS > Edit` on a single zone) instead of the
  Global API Key. See [Cloudflare API Token](#cloudflare-api-token).

* **Supply-chain pinning.**
  Base images are pinned by tag **and** digest, xcaddy plugins by exact
  version. [Renovate](renovate.json) keeps the pins fresh via PRs, and
  [CI](.github/workflows/ci.yml) lints, builds, smoke-tests plugin presence,
  and scans the image with Trivy before anything lands on `main`.

* **Container hardening.**
  `no-new-privileges` on both containers, log rotation capped at 3×10 MB.

**Accepted trade-offs** (reasonable for single-host, self-hosted scale):

* `CLOUDFLARE_API_TOKEN` is passed as an environment variable and is visible
  via `docker inspect` to anyone who already has Docker access — which on a
  single-host setup is equivalent to root anyway.
* The gateway is a single point of failure by design. There is no HA story;
  if you need one, this project is the wrong tool.

---

## Deployment

Clone the repository:

```bash
git clone <repository-url> ~/caddy-docker-gateway
cd ~/caddy-docker-gateway
```

Create environment configuration:

```bash
cp .env.example .env
nano .env
```

Required variables:

```env
CLOUDFLARE_API_TOKEN=
ACME_EMAIL=
BASE_DOMAIN=
```

Optional IPv6 support:

```env
ENABLE_IPV6=false
```

Set to `true` if Caddy should see real client IP addresses for IPv6 visitors
instead of Docker's gateway address.

Start the gateway:

```bash
docker compose up -d --build
```

Monitor startup:

```bash
docker logs -f caddy-proxy
```

The first startup performs:

1. custom Caddy image build;
2. plugin initialization;
3. wildcard certificate issuance.

---

## Verify Installation

Check that the gateway responds:

```bash
curl -Iv https://example.com
```

Expected output:

* successful TLS verification;
* certificate issued by Let's Encrypt.

Container health is also tracked by Docker itself (the Compose file defines a
healthcheck against Caddy's admin endpoint):

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

To verify generated routes:

```bash
docker exec caddy-proxy cat /config/caddy/Caddyfile.autosave
```

---

## Cloudflare API Token

Use a **Scoped API Token** instead of a Global API Key.

Required permissions:

```
Zone
 └── DNS
     └── Edit
```

Resource scope:

```
Include → example.com
```

---

## IPv6 Support

IPv6 support is disabled by default.

When enabled:

```env
ENABLE_IPV6=true
```

Docker Compose recreates the external network with IPv6 enabled.

No manual network creation is required.

This allows Caddy to receive real IPv6 client addresses instead of Docker's
gateway address.

---

## Adding a New Service

No changes are required in `caddy-docker-gateway`.

Add the shared network and Caddy labels to the service:

```yaml
services:
  my-service:
    image: my-image

    networks:
      - caddy_proxy_net

    labels:
      caddy: my-service.example.com
      caddy.reverse_proxy: "{{upstreams 8080}}"


networks:
  caddy_proxy_net:
    external: true
```

Deploy:

```bash
docker compose up -d
```

The service will automatically become available at:

```
https://my-service.example.com
```

The existing wildcard certificate already covers the new hostname.

---

## Integrating Existing Projects

Projects with their own Caddy instance can remain completely standalone.

When deployed inside this infrastructure, create a local:

```
docker-compose.override.yml
```

and disable the internal proxy:

```yaml
services:
  caddy:
    profiles:
      - disabled

  application:
    networks:
      - caddy_proxy_net

    labels:
      caddy: app.example.com
      caddy.reverse_proxy: "{{upstreams 3000}}"


networks:
  caddy_proxy_net:
    external: true
```

The override file should remain local and not be committed.

---

## Troubleshooting

### Inspect generated Caddy configuration

`caddy-docker-proxy` generates the final configuration automatically:

```bash
docker exec caddy-proxy cat /config/caddy/Caddyfile.autosave
```

### Verify Docker network membership

```bash
docker network inspect caddy_proxy_net
```

All services that should be proxied must appear in the network members list.

### Check Docker API connectivity

Caddy talks to Docker through the socket proxy. If routes are not being
generated, verify the proxy is up and reachable:

```bash
docker logs docker-socket-proxy
docker exec caddy-proxy wget -qO- http://docker-socket-proxy:2375/_ping
```

Expected output: `OK`.

---

## Maintenance

* **CI** ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs on every
  push and PR: hadolint, `docker compose config` validation, image build,
  plugin smoke test, Trivy vulnerability scan (fails on HIGH/CRITICAL).
* **Renovate** ([renovate.json](renovate.json)) opens PRs for base image
  digests, the socket-proxy image, GitHub Actions, and the xcaddy plugin
  versions pinned in the [Dockerfile](Dockerfile).

---

## Technology Stack

* [Caddy](https://caddyserver.com/) 2.11
* [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
  Docker labels → automatic Caddy configuration
* [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare)
  DNS-01 challenge provider for wildcard certificates
* [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
  least-privilege gateway to the Docker API
* [xcaddy](https://github.com/caddyserver/xcaddy)
  Custom Caddy binary builder

---

## Related Projects

* `gitea-dockerized` — self-hosted Gitea deployment
* `meshctl` — Headscale deployment with CLI tooling and ACL management

---

## License

[MIT](LICENSE)
