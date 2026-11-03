# syntax=docker/dockerfile:1.7
#
# Claude Code agent image.
#
# Safety model (see README.md):
#   * The container starts as root ONLY to install the egress firewall, then
#     entrypoint.sh drops to the unprivileged `agent` user with every
#     capability removed from the bounding set and no_new_privs set.
#   * No sudo is installed, so the agent cannot undo the firewall.
#   * Organisation policy lives in /etc/claude-code/managed-settings.json,
#     which has the highest precedence and is read-only to the agent.

FROM ubuntu:24.04

# "stable", "latest" or an exact version such as "2.1.300" for reproducible builds.
ARG CLAUDE_VERSION=stable
# Optional .NET SDK, e.g. --build-arg DOTNET_CHANNEL=10.0  (empty = not installed).
ARG DOTNET_CHANNEL=
ARG USERNAME=agent
ARG USER_UID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TERM=xterm-256color \
    COLORTERM=truecolor

# Base tooling. git comes from the git-core PPA because the worktrees are
# created with --relative-paths, which needs git >= 2.48 (24.04 ships 2.43).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg software-properties-common \
 && add-apt-repository -y ppa:git-core/ppa \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        git git-lfs tmux iptables ipset dnsutils jq ripgrep less procps \
        unzip zip nano util-linux bash-completion libicu74 \
 && apt-get purge -y software-properties-common \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# Optional .NET SDK.
RUN if [ -n "$DOTNET_CHANNEL" ]; then \
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
     && bash /tmp/dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir /usr/share/dotnet \
     && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
     && rm /tmp/dotnet-install.sh; \
    fi
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

# Unprivileged user (replaces the stock `ubuntu` user that owns UID 1000).
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd --create-home --shell /bin/bash --uid "$USER_UID" "$USERNAME" \
 && mkdir -p "/home/$USERNAME/.claude" /workspace \
 && chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" /workspace

# System-wide git config:
#   safe.directory  - bind mounts from Windows show up with a foreign owner
#   autocrlf=input  - the host checks out with CRLF; this keeps `git status` clean
#                     and makes commits from the container LF-normalised
#   filemode=false  - Windows bind mounts report every file as executable
#   checkStat/trustctime/untrackedCache - Windows and Linux record different stat data for
#                     the same files; without these, every `git status` re-reads every file
#                     (measured: ~4 min -> ~20 s on a 13.5k-file repo)
#   useRelativePaths - worktrees Claude creates inside the container (claude --worktree,
#                     subagent isolation: worktree) stay valid on the host, so a host-side
#                     `git worktree prune` does not delete them
#   excludesFile    - keeps those .claude/worktrees/ out of `git status`
RUN git config --system safe.directory '*' \
 && git config --system core.autocrlf input \
 && git config --system core.filemode false \
 && git config --system core.checkStat minimal \
 && git config --system core.trustctime false \
 && git config --system core.untrackedCache true \
 && git config --system worktree.useRelativePaths true \
 && printf '.claude/worktrees/\n' > /etc/gitignore-agent \
 && git config --system core.excludesFile /etc/gitignore-agent \
 && git config --system init.defaultBranch main

# Claude Code (native installer), installed as the agent user.
USER $USERNAME
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_VERSION"
USER root

ENV PATH=/home/$USERNAME/.local/bin:$PATH \
    CLAUDE_CONFIG_DIR=/home/$USERNAME/.claude \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1

# Policy, firewall and entrypoint (root-owned, not writable by the agent).
COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY allowed-domains.txt   /etc/claude-agent/allowed-domains.txt
COPY init-firewall.sh      /usr/local/sbin/init-firewall.sh
COPY entrypoint.sh         /usr/local/sbin/entrypoint.sh
RUN chmod 0644 /etc/claude-code/managed-settings.json /etc/claude-agent/allowed-domains.txt \
 && chmod 0755 /usr/local/sbin/init-firewall.sh /usr/local/sbin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["claude"]
