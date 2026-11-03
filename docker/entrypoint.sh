#!/usr/bin/env bash
# Runs as root: install firewall, prepare the config volume, then drop to `agent`
# with an empty capability bounding set and no_new_privs, and exec the command.
set -euo pipefail

AGENT=agent
AGENT_HOME=/home/$AGENT
CFG="${CLAUDE_CONFIG_DIR:-$AGENT_HOME/.claude}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[entrypoint] ERROR: must start as root so the firewall can be installed (do not pass --user)." >&2
    exit 1
fi

if [ "${CLAUDE_AGENT_FIREWALL:-1}" = "1" ]; then
    /usr/local/sbin/init-firewall.sh
else
    echo "[entrypoint] WARNING: egress firewall DISABLED for this container." >&2
fi

# Fresh named volumes are root-owned.
mkdir -p "$CFG"
chown "$AGENT:$AGENT" "$CFG"

# Skip the first-run theme/login wizard; auth comes from CLAUDE_CODE_OAUTH_TOKEN
# or an interactive /login whose credentials stay in this agent's own volume.
if [ ! -f "$CFG/.claude.json" ]; then
    echo '{"hasCompletedOnboarding": true, "theme": "dark"}' > "$CFG/.claude.json"
    chown "$AGENT:$AGENT" "$CFG/.claude.json"
    chmod 600 "$CFG/.claude.json"
fi

if [ -n "${CLAUDE_AGENT_BRANCH:-}" ]; then
    echo "[entrypoint] agent '${CLAUDE_AGENT_NAME:-?}' on branch ${CLAUDE_AGENT_BRANCH} in $(pwd)"
fi

exec setpriv \
    --reuid="$AGENT" --regid="$AGENT" --init-groups \
    --inh-caps=-all --bounding-set=-all --no-new-privs \
    -- env HOME="$AGENT_HOME" USER="$AGENT" LOGNAME="$AGENT" SHELL=/bin/bash "$@"
