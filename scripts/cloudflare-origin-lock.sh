#!/usr/bin/env bash
# Lock inbound 80/443 to Cloudflare IP ranges only, so the origin cannot be
# reached directly by IP (defeats the Cloudflare WAF/rate-limit bypass).
#
# Use this ONLY if every public hostname on this host is Cloudflare-proxied
# (orange cloud). Hosts that MUST be direct (e.g. a Headscale/Tailscale control
# server, which cannot be proxied by Cloudflare) need their own allow rule or a
# separate port — otherwise this script will lock them out.
#
# Idempotent. Requires: nft (nftables), curl. Run as root.
#   sudo bash scripts/cloudflare-origin-lock.sh
#
# To also allow direct access to specific ports (e.g. Headscale on 443 from
# anywhere is contradictory — instead expose Headscale on a dedicated port and
# list it here):
#   EXTRA_ALLOW_PORTS="41641" sudo bash scripts/cloudflare-origin-lock.sh
set -euo pipefail

PORTS="${PORTS:-80,443}"
EXTRA_ALLOW_PORTS="${EXTRA_ALLOW_PORTS:-}"
TABLE="inet cf_origin_lock"

echo "[*] Fetching Cloudflare IP ranges..."
V4=$(curl -fsS https://www.cloudflare.com/ips-v4)
V6=$(curl -fsS https://www.cloudflare.com/ips-v6)
[ -n "$V4" ] || { echo "failed to fetch ipv4 ranges"; exit 1; }

echo "[*] (Re)building nftables table: $TABLE"
nft delete table $TABLE 2>/dev/null || true
nft add table $TABLE
nft add set $TABLE cf4 '{ type ipv4_addr; flags interval; }'
nft add set $TABLE cf6 '{ type ipv6_addr; flags interval; }'
nft add element $TABLE cf4 "{ $(echo "$V4" | paste -sd, ) }"
nft add element $TABLE cf6 "{ $(echo "$V6" | paste -sd, ) }"

nft add chain $TABLE input '{ type filter hook input priority -10; policy accept; }'
# Allow established, loopback, and Docker bridges (internal container traffic).
nft add rule $TABLE input ct state established,related accept
nft add rule $TABLE input iif lo accept
nft add rule $TABLE input iifname "docker*" accept
nft add rule $TABLE input iifname "br-*" accept

# Allow the protected ports only from Cloudflare.
nft add rule $TABLE input tcp dport "{ $PORTS }" ip saddr @cf4 accept
nft add rule $TABLE input tcp dport "{ $PORTS }" ip6 saddr @cf6 accept
if [ -n "$EXTRA_ALLOW_PORTS" ]; then
  nft add rule $TABLE input tcp dport "{ $EXTRA_ALLOW_PORTS }" accept
fi
# Drop any other attempt at the protected ports (non-Cloudflare direct hits).
nft add rule $TABLE input tcp dport "{ $PORTS }" drop

echo "[*] Done. Non-Cloudflare traffic to $PORTS is now dropped."
echo "    Verify from an outside host:  curl --resolve host:443:<ORIGIN_IP> https://host/"
echo "    (should hang/refuse). Persist with: nft list ruleset > /etc/nftables.conf"
