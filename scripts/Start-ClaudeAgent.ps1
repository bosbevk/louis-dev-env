<#
.SYNOPSIS
    Start (or resume) a Claude Code agent in a hardened Docker container for a git repository.

.DESCRIPTION
    Each agent gets its own git worktree (<repo>\.worktrees\<name>) on branch agent/<name>,
    its own container and its own config volume, so several agents can work on the same
    repository in parallel without overwriting each other.

    Only the agent's worktree and the repository's .git directory are mounted; .git\config
    and .git\hooks are mounted read-only so an agent cannot plant code that would later run
    on the host. No host credentials (~/.ssh, ~/.claude, cloud keys) are mounted.

.EXAMPLE
    .\Start-ClaudeAgent.ps1 -Path C:\src\myrepo -Name auth-refactor
.EXAMPLE
    .\Start-ClaudeAgent.ps1 -Path . -SkipPermissions -AllowDomain api.nuget.org,www.nuget.org
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    # Agent name: lowercase letters, digits and dashes. Prompted for when omitted.
    [string]$Name,
    # Branch/commit a NEW agent starts from. Omit to choose from the repo's start points (repos.json).
    [string]$Base,
    # Branch name for a NEW agent (default: from the start point, or defaultBranch in repos.json).
    [string]$Branch,
    # Run Claude with --dangerously-skip-permissions. Refused when the firewall is disabled.
    [switch]$SkipPermissions,
    # Enable experimental agent teams and run Claude inside tmux (split-pane teammates).
    [switch]$Team,
    # Open a bash shell instead of Claude.
    [switch]$Shell,
    # Mount the folder itself instead of a worktree (all agents share one working tree).
    [switch]$Shared,
    # Always show the repository picker (also shown automatically when -Path is not a repository).
    [switch]$PickRepo,
    # Extra egress domains for this session only.
    [string[]]$AllowDomain = @(),
    # Disable the egress firewall (not recommended).
    [switch]$NoFirewall,
    [switch]$Rebuild,
    [string]$Memory = '8g',
    [string]$Cpus = '4',
    # Do not wait for Enter before exiting (the context menu leaves this off so errors stay visible).
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAgent.Common.ps1')

function Read-AgentName([string]$Root) {
    $existing = @(if ($Root) { Get-AgentWorktrees $Root })
    if ($existing.Count -gt 0) {
        Write-Host ''
        Write-Host 'Existing agents in this repository:'
        for ($i = 0; $i -lt $existing.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $existing[$i]) }
    }
    Write-Host ''
    $answer = Read-Host 'Agent name (new name, number to resume, Enter = auto)'
    if (-not $answer) { return 'agent-' + (Get-Date -Format 'MMdd-HHmmss') }
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $existing.Count) { return $existing[$n - 1] }
    return $answer.Trim().ToLowerInvariant()
}

function Read-Choice([string]$Prompt, [int]$Max, [int]$Default = 1) {
    while ($true) {
        $a = Read-Host "$Prompt [$Default]"
        if (-not $a) { return $Default }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Max) { return $n }
        Write-Warn "Enter a number between 1 and $Max."
    }
}

function Expand-BranchTemplate([string]$Template, [string]$AgentName, [string]$Picked, [string]$Suffix) {
    return $Template.Replace('{name}', $AgentName).Replace('{picked}', $Picked).Replace('{pickedSuffix}', $Suffix)
}

# Fetch origin/<x> on the host (your credentials) so the agent starts from the latest remote state.
function Update-RemoteRef([string]$Root, [string]$Ref) {
    if ($Ref -match '^origin/(.+)$') {
        Write-Info "Fetching $Ref ..."
        & git -C $Root fetch --quiet origin "$($Matches[1])"
        if ($LASTEXITCODE -ne 0) { Write-Warn "Fetch of $Ref failed; using the last fetched state." }
    }
}

# Ask where a new agent starts. Returns @{ Base; Branch }.
function Select-StartPoint([string]$Root, [string]$AgentName) {
    $cfg = Get-RepoConfig $Root
    $current = (& git -C $Root rev-parse --abbrev-ref HEAD).Trim()
    $options = @($cfg.StartPoints) + @(
        [pscustomobject]@{ label = "Current branch ($current)";       base = 'HEAD';  branch = $cfg.DefaultBranch },
        [pscustomobject]@{ label = 'Pick a branch...';                 pick = '*';     branch = $cfg.DefaultBranch },
        [pscustomobject]@{ label = 'Type a branch, tag or commit...';  ask = $true;    branch = $cfg.DefaultBranch }
    )

    Write-Host ''
    Write-Host "Start agent '$AgentName' from:"
    for ($i = 0; $i -lt $options.Count; $i++) {
        $o = $options[$i]
        $pickPat = Get-Prop $o 'pick'
        $from = if ($pickPat -eq '*') { 'any branch' } elseif ($pickPat) { "a $pickPat branch" } elseif (Get-Prop $o 'ask') { 'you type it' } else { Get-Prop $o 'base' }
        $br = Expand-BranchTemplate (Get-Prop $o 'branch' $cfg.DefaultBranch) $AgentName '<picked>' '<picked>'
        Write-Host ("  [{0}] {1,-34} -> {2,-40} (from {3})" -f ($i + 1), (Get-Prop $o 'label'), $br, $from)
    }
    $o = $options[(Read-Choice 'Choice' $options.Count) - 1]
    $template = Get-Prop $o 'branch' $cfg.DefaultBranch

    if (Get-Prop $o 'pick') {
        $pattern = Get-Prop $o 'pick'
        $listPattern = if ($pattern -eq '*') { '' } else { $pattern }   # '*' = every branch, at any depth
        if ($cfg.Fetch) { Write-Info 'Fetching origin ...'; & git -C $Root fetch --quiet --prune origin }
        $picked = Select-Branch $Root $listPattern "Branches$(if ($listPattern) { " matching $listPattern" }) (newest first)"
        if (-not $picked) { throw 'No branch selected.' }

        $rx = '^' + [regex]::Escape($pattern).Replace('\*', '(.*)') + '$'
        $suffix = if ($listPattern -and $picked.Name -match $rx -and $Matches.Count -gt 1) { $Matches[1] } else { $picked.Name }
        $newBranch = Expand-BranchTemplate $template $AgentName $picked.Name $suffix

        # New branch from the picked one, or let the agent work directly on it.
        $usedBy = (Get-CheckedOutBranches $Root)[$picked.Name]
        Write-Host ''
        Write-Host "How should the agent use $($picked.Name)?"
        Write-Host "  [1] New branch $newBranch from it (recommended)"
        if ($usedBy) {
            Write-Host "  [2] Work directly on it - not possible, it is checked out in $usedBy" -ForegroundColor DarkGray
            $mode = 1
        } else {
            Write-Host "  [2] Work directly on $($picked.Name) (the agent's commits go straight onto it)"
            $mode = Read-Choice 'Choice' 2
        }
        if ($mode -eq 2) { return @{ Base = $picked.Ref; Branch = $picked.Name } }
        return @{ Base = $picked.Ref; Branch = $newBranch }
    }

    $base = if (Get-Prop $o 'ask') { (Read-Host 'Branch or commit to start from (e.g. origin/master)').Trim() } else { Get-Prop $o 'base' }
    if (-not $base) { throw 'No start point given.' }
    if ($cfg.Fetch) { Update-RemoteRef $Root $base }
    return @{ Base = $base; Branch = (Expand-BranchTemplate $template $AgentName $base $base) }
}

try {
    Assert-Docker

    if ($SkipPermissions -and $NoFirewall) {
        throw '-SkipPermissions requires the egress firewall. Remove -NoFirewall.'
    }

    $target = (Resolve-Path $Path).Path
    $repo = if ($PickRepo) { $null } else { Get-RepoInfo $target }
    if (-not $repo -and -not $Shared) {
        # Not inside a repository (or -PickRepo): offer the repos under this folder and repoRoots.
        $picked = Select-Repo @($target) 'Start an agent in which repository?'
        if (-not $picked) { throw 'No repository selected.' }
        $target = $picked
        $repo = Get-RepoInfo $target
        $Host.UI.RawUI.WindowTitle = "Claude agent: $(Split-Path $target -Leaf)"
    }
    if ($repo) { Add-RecentRepo $repo.Root }

    $root = if ($repo) { $repo.Root } else { $target }
    $slug = Get-RepoSlug $root

    if (-not $Name) { $Name = Read-AgentName $(if ($repo -and -not $Shared) { $root } else { $null }) }
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]{0,39}$') { throw "Invalid agent name '$Name' (use a-z, 0-9 and '-', max 40 chars)." }

    $container = Get-ContainerName $slug $Name
    $volume    = Get-VolumeName $slug $Name

    # Already running? Offer a second shell instead of a conflicting container.
    $running = & docker ps --filter "name=^/$container$" --format '{{.Names}}'
    if ($running) {
        Write-Warn "Agent '$Name' is already running in container $container."
        $ans = Read-Host 'Open another shell in it? [Y/n]'
        if ($ans -notmatch '^(n|no)$') { & docker exec -it -u agent $container bash }
        return
    }

    # Image.
    & docker image inspect $script:ImageName *> $null
    if ($Rebuild -or $LASTEXITCODE -ne 0) {
        Write-Info "Building image $($script:ImageName) ..."
        & docker build --pull -t $script:ImageName $script:DockerDir
        if ($LASTEXITCODE -ne 0) { throw 'docker build failed.' }
    }

    # Mounts.
    $mounts = @()
    $branch = $null
    if ($Shared) {
        $workdir = '/workspace/repo'
        $mounts += '-v', "${root}:$workdir"
        if ($repo) {
            $mounts += '-v', "$(Join-Path $repo.GitDir 'config'):$workdir/.git/config:ro"
            $mounts += '-v', "$(Join-Path $repo.GitDir 'hooks'):$workdir/.git/hooks:ro"
        }
        Write-Warn 'Shared mode: this agent edits the folder directly; other agents in shared mode see the same files.'
    } else {
        & git -C $root rev-parse --verify --quiet HEAD *> $null
        if ($LASTEXITCODE -ne 0) { throw 'The repository has no commits yet. Make an initial commit first.' }

        $wtRel  = "$($script:WorktreeDir)/$Name"
        $wtPath = Join-Path $root ($wtRel -replace '/', '\')

        # Keep .worktrees out of `git status` without touching the tracked .gitignore.
        $exclude = Join-Path $repo.GitDir 'info\exclude'
        if (-not (Test-Path $exclude)) { New-Item -ItemType File -Force $exclude | Out-Null }
        if (-not (Select-String -Path $exclude -SimpleMatch "/$($script:WorktreeDir)/" -Quiet)) {
            Add-Content -Path $exclude -Value "/$($script:WorktreeDir)/"
        }

        $meta = Get-AgentMeta $slug $Name
        if (Test-Path (Join-Path $wtPath '.git')) {
            # Resume: the worktree already knows its branch.
            $branch = Get-WorktreeBranch $wtPath
            if (-not $Base) { $Base = Get-Prop $meta 'base' }
            Write-Info "Resuming agent '$Name' on $branch"
        } else {
            if ($meta -and -not $Base -and -not $Branch) {
                # Worktree was removed but we remember the branch: re-attach to it.
                $Base = Get-Prop $meta 'base'; $Branch = Get-Prop $meta 'branch'
            }
            if (-not $Base) {
                $sp = Select-StartPoint $root $Name
                $Base = $sp.Base
                if (-not $Branch) { $Branch = $sp.Branch }
            }
            if (-not $Branch) { $Branch = Expand-BranchTemplate (Get-RepoConfig $root).DefaultBranch $Name $Base $Base }
            $branch = $Branch

            & git -C $root check-ref-format --branch $branch *> $null
            if ($LASTEXITCODE -ne 0) { throw "'$branch' is not a valid branch name." }
            & git -C $root rev-parse --verify --quiet "$Base^{commit}" *> $null
            if ($LASTEXITCODE -ne 0) { throw "Start point '$Base' does not exist (fetch it first?)." }

            & git -C $root show-ref --verify --quiet "refs/heads/$branch"
            $branchExisted = ($LASTEXITCODE -eq 0)
            if ($branchExisted -and -not $meta) {
                $ans = Read-Host "Branch $branch already exists. Let the agent continue on it? [Y/n]"
                if ($ans -match '^(n|no)$') { throw 'Aborted. Choose another agent name.' }
            }
            try {
                if ($branchExisted) {
                    Write-Info "Creating worktree $wtRel on existing branch $branch ..."
                    Invoke-Git $root worktree add -q --relative-paths $wtRel $branch | Out-Null
                } else {
                    Write-Info "Creating worktree $wtRel on new branch $branch (from $Base) ..."
                    # Working directly on a remote-only branch: create the local branch tracking origin.
                    $track = if ($Base -eq "origin/$branch") { '--track' } else { '--no-track' }
                    Invoke-Git $root worktree add -q --relative-paths $track -b $branch $wtRel $Base | Out-Null
                }
                $created = if ($meta) { [bool](Get-Prop $meta 'createdBranch' $false) } else { -not $branchExisted }
                Set-AgentMeta $slug $Name @{ base = $Base; branch = $branch; createdBranch = $created; created = (Get-Date -Format s) }
            } catch {
                # Roll back so a retry starts clean: drop the half-made worktree and the branch we just created.
                & git -C $root -c core.longpaths=true worktree remove --force $wtRel *> $null
                if (Test-Path $wtPath) { Remove-Item $wtPath -Recurse -Force -ErrorAction SilentlyContinue }
                & git -C $root worktree prune *> $null
                if (-not $branchExisted) { & git -C $root branch -D $branch *> $null }
                throw
            }
        }

        # Same relative layout inside the container so the relative gitdir links resolve.
        $workdir = "/workspace/repo/$wtRel"
        $mounts += '-v', "$($repo.GitDir):/workspace/repo/.git"
        $mounts += '-v', "$(Join-Path $repo.GitDir 'config'):/workspace/repo/.git/config:ro"
        $mounts += '-v', "$(Join-Path $repo.GitDir 'hooks'):/workspace/repo/.git/hooks:ro"
        $mounts += '-v', "${wtPath}:$workdir"
    }
    $mounts += '-v', "${volume}:/home/agent/.claude"

    # Environment. Secrets are passed by name only (-e VAR), never on the command line.
    $envArgs = @(
        '-e', "CLAUDE_AGENT_NAME=$Name",
        '-e', "CLAUDE_AGENT_FIREWALL=$(if ($NoFirewall) { '0' } else { '1' })"
    )
    if ($branch) { $envArgs += '-e', "CLAUDE_AGENT_BRANCH=$branch" }
    if ($AllowDomain.Count -gt 0) { $envArgs += '-e', "CLAUDE_AGENT_EXTRA_DOMAINS=$($AllowDomain -join ',')" }
    if ($Team) { $envArgs += '-e', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1' }

    $gitName  = & git config --get user.name
    $gitEmail = & git config --get user.email
    if ($gitName)  { $envArgs += '-e', "GIT_AUTHOR_NAME=$gitName",  '-e', "GIT_COMMITTER_NAME=$gitName" }
    if ($gitEmail) { $envArgs += '-e', "GIT_AUTHOR_EMAIL=$gitEmail", '-e', "GIT_COMMITTER_EMAIL=$gitEmail" }

    $token = Get-StoredToken
    if ($token) {
        $env:CLAUDE_CODE_OAUTH_TOKEN = $token     # process-scoped; docker reads it via -e NAME
        $envArgs += '-e', 'CLAUDE_CODE_OAUTH_TOKEN'
    } else {
        Write-Warn 'No stored token. Run scripts\Set-ClaudeToken.ps1 once, or use /login inside the container (saved in this agent''s volume).'
    }

    # Command.
    $claudeCmd = @('claude')
    if ($SkipPermissions) { $claudeCmd += '--dangerously-skip-permissions' }
    if ($Team) { $claudeCmd += '--teammate-mode', 'tmux' }
    $cmd = if ($Shell) { @('bash', '-l') }
           elseif ($Team) { @('tmux', 'new-session', '-A', '-s', 'agent') + $claudeCmd }
           else { $claudeCmd }

    $runArgs = @(
        'run', '--rm', '-it', '--init',
        '--name', $container, '--hostname', $Name,
        '--label', 'claude-agent=1', '--label', "claude-agent.repo=$slug", '--label', "claude-agent.name=$Name",
        # Least privilege: only what the root entrypoint needs (firewall + dropping to `agent`).
        '--cap-drop', 'ALL',
        '--cap-add', 'NET_ADMIN', '--cap-add', 'NET_RAW',
        '--cap-add', 'SETUID', '--cap-add', 'SETGID', '--cap-add', 'SETPCAP',
        '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER',
        '--security-opt', 'no-new-privileges',
        '--memory', $Memory, '--cpus', $Cpus, '--pids-limit', '2048',
        '-w', $workdir
    ) + $mounts + $envArgs + @($script:ImageName) + $cmd

    Write-Info "Starting $container  (firewall: $(if ($NoFirewall) {'OFF'} else {'on'}), permissions: $(if ($SkipPermissions) {'SKIPPED'} else {'prompt'}))"
    $Host.UI.RawUI.WindowTitle = "Claude agent: $Name ($(Split-Path $root -Leaf))"
    & docker @runArgs
    $exit = $LASTEXITCODE

    if ($branch) {
        Write-Host ''
        Write-Info "Agent '$Name' stopped. Its work is on branch $branch :"
        $range = if ($Base) { "$Base..$branch" } else { '-5', $branch }
        & git -C $root --no-pager log --oneline @range 2>$null | Select-Object -First 15
        & git -C $wtPath -c core.longpaths=true status --short
        Write-Host ''
        if ($Base) { Write-Host "  Review : git diff $Base...$branch" }
        Write-Host "  Resume : Start-ClaudeAgent.ps1 -Path `"$root`" -Name $Name"
        Write-Host "  Remove : Remove-ClaudeAgent.ps1 -Path `"$root`" -Name $Name"
    }
    if ($exit -ne 0 -and -not $NoPause) { Write-Warn "docker exited with code $exit" }
}
catch {
    Write-Host ''
    Write-Host "[claude-agent] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exit = 1
}
finally {
    Remove-Item Env:\CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
}
exit $exit
