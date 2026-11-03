#!/usr/bin/env bash
# Default-deny egress firewall for a Claude agent container.
# Adapted from https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
# Runs as root from entrypoint.sh, before privileges are dropped.
set -euo pipefail
IFS=$'\n\t'

ALLOWLIST=/etc/claude-agent/allowed-domains.txt
EXTRA_DOMAINS="${CLAUDE_AGENT_EXTRA_DOMAINS:-}"   # comma separated, set by the launcher
SET=allowed-domains

log() { echo "[firewall] $*"; }

# 1. Keep Docker's embedded DNS NAT rules (only present on user-defined networks).
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy "$SET" 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# 2. DNS only to the resolvers in resolv.conf (limits DNS tunnelling to other servers).
mapfile -t RESOLVERS < <(awk '/^nameserver/ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf)
for ns in "${RESOLVERS[@]}"; do
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 3. Build the allowlist.
ipset create "$SET" hash:net

add_cidr() { ipset add "$SET" "$1" -exist; }

mapfile -t DOMAINS < <(grep -vE '^\s*(#|$)' "$ALLOWLIST" | tr -d '\r' | awk '{print $1}')
if [ -n "$EXTRA_DOMAINS" ]; then
    IFS=',' read -r -a EXTRA <<< "$EXTRA_DOMAINS"
    DOMAINS+=("${EXTRA[@]}")
fi

for d in "${DOMAINS[@]}"; do
    d="$(echo "$d" | xargs)"
    [ -z "$d" ] && continue
    if [ "$d" = "@github" ]; then
        log "fetching GitHub IP ranges"
        meta=$(curl -fsS --max-time 15 https://api.github.com/meta) || { log "ERROR: cannot reach api.github.com/meta"; exit 1; }
        while read -r cidr; do add_cidr "$cidr"; done < <(echo "$meta" | jq -r '(.web + .api + .git)[]' | grep -E '^[0-9.]+/[0-9]+$' | sort -u)
        continue
    fi
    if ! [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]]; then log "skipping invalid entry: $d"; continue; fi
    ips=$(dig +short A "$d" | grep -E '^[0-9.]+$' || true)
    if [ -z "$ips" ]; then log "WARNING: could not resolve $d"; continue; fi
    while read -r ip; do add_cidr "$ip"; done <<< "$ips"
done

# 4. Default deny. REJECT (not DROP) so blocked requests fail fast instead of hanging.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A OUTPUT -m set --match-set "$SET" dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Block IPv6 entirely so it cannot be used to bypass the IPv4 rules.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F 2>/dev/null || true
    ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    ip6tables -P INPUT DROP   2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP  2>/dev/null || true
fi

# 5. Verify.
if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
    log "ERROR: firewall verification failed - example.com is reachable"; exit 1
fi
if ! curl -sS --max-time 10 -o /dev/null https://api.anthropic.com; then
    log "ERROR: firewall verification failed - api.anthropic.com is NOT reachable"; exit 1
fi
log "active: $(ipset list "$SET" | grep -cE '^[0-9]') allowed networks, everything else rejected"
