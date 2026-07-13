# syntax=docker/dockerfile:1

FROM caddy:2.11.4-builder-alpine@sha256:8e89605351333ad2cc2f3bcc95275a2ccc427f88914050e86a5fde0fd77a63c4 AS builder

# renovate: datasource=github-releases depName=lucaslorentz/caddy-docker-proxy
ARG CADDY_DOCKER_PROXY_VERSION=v2.13.1
# renovate: datasource=github-tags depName=caddy-dns/cloudflare
ARG CADDY_DNS_CLOUDFLARE_VERSION=v0.2.4

RUN xcaddy build \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2@${CADDY_DOCKER_PROXY_VERSION} \
    --with github.com/caddy-dns/cloudflare@${CADDY_DNS_CLOUDFLARE_VERSION}

FROM caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648

# The base image is pinned by digest for reproducibility, but that freezes
# whatever Alpine packages were current when upstream built it. Pulling
# fresh packages here keeps OS-level CVEs (e.g. c-ares, busybox) patched on
# every build instead of waiting on upstream to re-cut the base image.
RUN apk --no-cache upgrade

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
