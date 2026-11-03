# Parallel Claude Code agents in Docker (Windows)

This repo runs several Claude Code sessions in parallel on the **same repository**. Each session runs in its own hardened container and its own git worktree. You start a session from the Explorer right-click menu.

```
<repo>\                      main checkout (yours, not mounted into containers)
<repo>\.git\                 shared by all agents (config + hooks mounted read-only)
<repo>\.worktrees\auth\      agent "auth"  -> branch agent/auth  -> container claude-<repo>-<hash>-auth
<repo>\.worktrees\billing\   agent "billing" -> branch agent/billing -> ...
```

## Quick start

```powershell
# 1. One-time: sign in with your Claude subscription and store the token (optional, see Setup)
claude setup-token
scripts\Set-ClaudeToken.ps1

# 2. One-time: add the Explorer right-click menu
pwsh -File scripts\Install-ContextMenu.ps1
```

3. In Explorer, right-click inside any git repository and choose **Show more options**, then **Claude agent (Docker)**, then **New agent**.
4. Type a name such as `auth`, or press Enter for an automatic name. Then choose where it starts, for example **New work from production** (see [Choosing where an agent starts](#choosing-where-an-agent-starts-per-repository)). A Windows Terminal tab opens with Claude running in a sandbox on its own branch.
5. Repeat for more agents. When an agent is done, review and merge on the host:
   ```powershell
   git diff main...agent/auth
   git merge agent/auth
   ```
6. Right-click, then **Claude agent (Docker)**, then **Clean up agents...** to remove finished agents.

The repository needs at least one commit. The first launch builds the Docker image, which takes a few minutes.

The design follows the Claude Code docs: [dev containers](https://code.claude.com/docs/en/devcontainer), [running agents in parallel](https://code.claude.com/docs/en/agents), [agent teams](https://code.claude.com/docs/en/agent-teams) and [network requirements](https://code.claude.com/docs/en/network-config). It also follows the worktree-per-agent pattern from the [Warp guide](https://docs.warp.dev/guides/agent-workflows/how-to-run-multiple-ai-coding-agents/).

## Setup (once)

1. Install Docker Desktop (Linux containers), Git 2.48 or later and Windows Terminal.
2. Authenticate with your **Claude subscription** (Pro/Max). No API key is needed. Pick one:
   - **Sign in once (recommended for many agents):** run `claude setup-token` on the host. It opens the browser, you sign in with your subscription account, and it prints a long-lived OAuth token tied to that subscription. Usage counts against your plan, not API billing. Then run `scripts\Set-ClaudeToken.ps1` and paste the token. It is stored DPAPI-encrypted for your Windows user, and every agent starts already signed in.
   - **Per-agent login:** start an agent and run `/login`. Choose your Claude account, open the URL in your browser and paste the code back. The login is kept in that agent's own Docker volume, so you repeat it for each new agent name.
3. Install the right-click menu and the Start Menu shortcut with `pwsh -File scripts\Install-ContextMenu.ps1`. To remove them, add `-Uninstall`. The installer also creates your personal `repos.json` from `repos.example.json`. That file is gitignored. Edit it to list your repository folders and per-repository branch conventions (see [below](#choosing-where-an-agent-starts-per-repository)).
4. Optionally pre-build the image with `docker build -t claude-agent:latest docker` (add `--build-arg DOTNET_CHANNEL=10.0` to include the .NET SDK). The launcher builds the image automatically if it is missing. `-Rebuild` forces a rebuild, which is also how Claude Code gets updated, because auto-update is off inside containers.

## Use

Right-click a repository folder, or the empty space inside one. On Windows 11, choose **Show more options**, then **Claude agent (Docker)**:

| Entry | What it does |
|---|---|
| New agent | Prompts for a name (or picks an existing agent to resume) and where to start from, creates the worktree and branch, and starts Claude with normal permission prompts. Outside a repository it shows the repo picker first |
| New agent (pick repo)... | Same, but always starts with the [repo picker](#picking-a-repository) |
| New agent (unattended) | Same, with `--dangerously-skip-permissions`. Only allowed while the firewall is on |
| New agent team (tmux) | Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and runs Claude in tmux so teammates get split panes |
| Shell in agent container | A bash shell in the same sandbox |
| Clean up agents... | Removes worktrees and volumes, and optionally merged branches |

You can also run it from the command line:

```powershell
scripts\Start-ClaudeAgent.ps1 -Path C:\src\repo -Name auth -AllowDomain pypi.org
scripts\Remove-ClaudeAgent.ps1 -Path C:\src\repo -Name auth -DeleteBranch
```

Every right-click opens a new Windows Terminal tab, so you can run as many agents as you like. Each one is a separate container on a separate branch.

### Picking a repository

You don't have to browse to the repository first. The repo picker opens from:
- the **Claude agent** shortcut in the Start Menu,
- **New agent (pick repo)...** in the right-click menu,
- **New agent** or **Clean up agents...** on any folder that isn't a repository itself, such as `C:\Repositories` or the desktop.

```
Start an agent in which repository?:
  [ 1] my-api                     C:\Repositories  [recent, 2 agents]
  [ 2] my-web-app                 C:\Repositories
  [ 3] shared-lib                 C:\Users\me\source\repos
  ...
Number, text to filter, Enter = clear filter, q = cancel: web
```

Type a number to pick a repository. Type part of a name to filter the list, and a filter that matches only one repository selects it straight away. Repositories you used recently are listed first. The picker scans the `repoRoots` folders in `repos.json` (environment variables such as `%USERPROFILE%` work), plus the folder you right-clicked (one level deep).

### Choosing where an agent starts (per repository)

When you create a new agent, the launcher asks where to start from. The choices come from your `repos.json` in this project, so nothing is added to your repositories and agents can't change the file. With the `example-service` entry from `repos.example.json` it looks like this:

```
Start agent 'pricing-fix' from:
  [1] New work from production     -> work/pricing-fix                    (from origin/production)
  [2] Task on an existing feature  -> <picked>/pricing-fix                (from a feature/* branch)
  [3] New feature from production  -> feature/pricing-fix                 (from origin/production)
  [4] Current branch (main)        -> agent/pricing-fix                   (from HEAD)
  [5] Pick a branch...             -> agent/pricing-fix                   (from any branch)
  [6] Type a branch, tag or commit -> agent/pricing-fix                   (from you type it)
Choice [1]:
```

**Pick a branch...** lists every local and `origin` branch, newest first. Type a number, or part of a name to filter (`login`, `1234`, `release/`). Branches checked out elsewhere are marked. After you pick one, you choose how the agent uses it:

```
How should the agent use feature/checkout-redesign?
  [1] New branch agent/pricing-fix from it (recommended)
  [2] Work directly on feature/checkout-redesign (the agent's commits go straight onto it)
```

Option 2 isn't offered for a branch that is checked out in another worktree, such as your main checkout, because git doesn't allow the same branch to be checked out twice. Picking a feature through **Task on an existing feature** asks the same question.

- Press **Enter** for the first option, which is the repository's default.
- **Task on an existing feature** lists the `feature/*` branches (local and `origin`, newest first). After you pick `feature/checkout-redesign`, the agent works on `checkout-redesign/pricing-fix`, branched from that feature.
- With `"fetch": true`, the host fetches the start point from `origin` first, using your own git credentials (GitHub, Azure DevOps, GitLab and so on). That way agents start from the latest state. Agents themselves never get those credentials.
- Repositories without an entry get **Current branch**, **Pick a branch** and **Type a branch**. New branches are named with `defaultBranch`, `agent/{name}` unless you set one. A repository can override it, for example `"defaultBranch": "dev/{name}"`.
- **Resume** (pick an existing agent by number) skips this question. The agent continues on its own branch.
- From the command line you can skip the menu with `-Base origin/production -Branch work/my-fix`.

Add a repository by copying the `example-service` block in `repos.json`. The key can be the folder name or the full path. Placeholders: `{name}` is the agent name, `{picked}` is the chosen branch, and `{pickedSuffix}` is the part matched by `*`.

### Working rules for parallel agents

- Give each agent a clear area of ownership in its first prompt, for example: *"You own src/auth/ and tests/auth/. Don't edit src/billing/. Run the tests before you finish. Report changed files and risks."*
- Agents commit only to their own branch. **Review and merge on the host**, one branch at a time (e.g. `git diff origin/main...agent/auth`), and re-run the full test suite after each merge.
- Clean up only deletes branches the agent created, and only when they are merged or have no commits. A branch you chose to continue on is never deleted.
- Agents cannot push. Pushing, PRs and anything that needs your credentials happen on the host, after review.

## Safety model

| Control | How |
|---|---|
| Least privilege | Root runs only long enough to install the firewall. Then `setpriv` drops to the `agent` user with an empty capability bounding set and `no_new_privs`. There is no sudo. The container uses `--cap-drop ALL` plus a minimal add-list, and `--security-opt no-new-privileges` |
| Egress firewall | Default deny (iptables + ipset), allowing only `docker/allowed-domains.txt`. DNS is limited to the container's resolvers and IPv6 is blocked. It verifies itself at start and the container refuses to start if the check fails |
| No host secrets | `~/.ssh`, `~/.claude`, cloud credentials and the Docker socket are never mounted. Each agent has its own config volume. The token is passed by variable name, not on the command line |
| Host-execution guard | `.git/config` and `.git/hooks` are mounted read-only, so an agent cannot plant hooks, `core.fsmonitor` or `core.hooksPath` that would later run on your machine |
| Blast radius | An agent only sees its own worktree plus `.git`, never your main checkout. CPU, memory and PID limits apply |
| Policy | `/etc/claude-code/managed-settings.json` (highest precedence) denies reading `.env` files and keys, and denies `git push`, `git config` and `git remote` |
| Reproducibility | Pin `CLAUDE_VERSION` in the Dockerfile. Auto-update and telemetry are off |

**Limits you should know about.** These come from the [dev container docs](https://code.claude.com/docs/en/devcontainer):

- An agent running with skip-permissions can still exfiltrate anything inside its container, including the OAuth token, to an allowed domain. Only run trusted repositories.
- The agent writes to files that you later open on the host. Review diffs before running build scripts, `.vscode`/`.idea` run configs or `.claude/settings.json` hooks from an agent branch.
- Firewall IPs are resolved when the container starts. CDN-backed hosts can change IPs during very long sessions. If that happens, restart the agent.

## Large repositories

- **Long paths:** the launcher runs git with `core.longpaths=true`, so a worktree under `.worktrees\<name>\` works even when files go past the 260-character Windows limit. Inside the container these are ordinary Linux paths.
- **`git status` speed:** Docker Desktop reads Windows files slowly, and Windows and Linux record different file metadata, so git would re-read every file on each `git status`. The image sets `core.checkStat=minimal`, `core.trustctime=false` and `core.untrackedCache=true`. On a 13.5k-file repository this took `git status` from about 4 minutes to about 20 seconds; the first run in a new worktree is slower.

## Files

```
docker/Dockerfile              Ubuntu 24.04, git (PPA), tmux, Claude Code native install, optional .NET
docker/entrypoint.sh           firewall -> config volume -> drop privileges -> exec
docker/init-firewall.sh        default-deny egress firewall
docker/allowed-domains.txt     egress allowlist (edit, then rebuild)
docker/managed-settings.json   Claude Code managed policy
repos.example.json             example repo roots, start points and branch naming
repos.json                     your personal copy (gitignored; created by Install-ContextMenu.ps1)
scripts/Start-ClaudeAgent.ps1  launcher (worktree + container)
scripts/Remove-ClaudeAgent.ps1 cleanup
scripts/Set-ClaudeToken.ps1    store a setup-token with DPAPI
scripts/Install-ContextMenu.ps1 Explorer menu (HKCU)
```
