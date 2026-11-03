# Shared helpers for the Claude agent scripts. Dot-source this file.
Set-StrictMode -Version Latest

$script:ImageName   = 'claude-agent:latest'
$script:DockerDir   = Join-Path (Split-Path $PSScriptRoot -Parent) 'docker'
$script:TokenFile   = Join-Path $env:LOCALAPPDATA 'claude-agent\oauth-token.dpapi'
$script:WorktreeDir = '.worktrees'
# Personal config (gitignored); falls back to the committed example.
$script:ConfigFile  = Join-Path (Split-Path $PSScriptRoot -Parent) 'repos.json'
$script:ExampleConfigFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'repos.example.json'
if (-not (Test-Path $script:ConfigFile)) { $script:ConfigFile = $script:ExampleConfigFile }
$script:MetaDir     = Join-Path $env:LOCALAPPDATA 'claude-agent\agents'

# StrictMode-safe property read on objects from ConvertFrom-Json.
function Get-Prop($obj, [string]$name, $default = $null) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $default }
}

# Returns @{ Fetch; StartPoints; DefaultBranch } for a repository (from repos.json, or generic defaults).
function Get-RepoConfig([string]$Root) {
    $cfg = $null
    if (Test-Path $script:ConfigFile) { $cfg = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json }
    $repoCfg = $null
    $repos = Get-Prop $cfg 'repos'
    if ($repos) {
        $leaf = Split-Path $Root -Leaf
        foreach ($p in $repos.PSObject.Properties) {
            if ($p.Name -ieq $Root -or $p.Name -ieq $leaf) { $repoCfg = $p.Value; break }
        }
    }
    return @{
        Fetch         = [bool](Get-Prop $repoCfg 'fetch' $false)
        StartPoints   = @(Get-Prop $repoCfg 'startPoints' @())
        # A repo-level "defaultBranch" overrides the global one.
        DefaultBranch = [string](Get-Prop $repoCfg 'defaultBranch' (Get-Prop $cfg 'defaultBranch' 'agent/{name}'))
    }
}

# Branches matching a pattern such as 'feature/*' (or all branches when the pattern is empty),
# local and origin, newest first, de-duplicated (local wins over origin when equally new).
# Returns objects @{ Name (without origin/); Ref (what to branch from); Remote; When }.
function Get-MatchingBranches([string]$Root, [string]$Pattern, [int]$Max = 20) {
    $refs = if ($Pattern) { @("refs/heads/$Pattern", "refs/remotes/origin/$Pattern") } else { @('refs/heads', 'refs/remotes/origin') }
    $lines = & git -C $Root for-each-ref --sort=-committerdate --format='%(refname)|%(committerdate:relative)' @refs
    $seen = @{}; $result = @()
    foreach ($line in $lines) {
        $ref, $when = $line -split '\|', 2
        if ($ref -match '^refs/heads/(.+)$') { $name = $Matches[1]; $use = $name; $remote = $false }
        elseif ($ref -match '^refs/remotes/origin/(.+)$') { $name = $Matches[1]; $use = "origin/$name"; $remote = $true }
        else { continue }
        if ($name -eq 'HEAD' -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $result += [pscustomobject]@{ Name = $name; Ref = $use; Remote = $remote; When = $when }
        if ($Max -gt 0 -and $result.Count -ge $Max) { break }
    }
    return $result
}

# Branches checked out in any worktree (git refuses to check out the same branch twice).
function Get-CheckedOutBranches([string]$Root) {
    $map = @{}; $path = $null
    foreach ($l in (& git -C $Root worktree list --porcelain)) {
        if ($l -like 'worktree *') { $path = $l.Substring(9) }
        elseif ($l -like 'branch refs/heads/*') { $map[$l.Substring(18)] = $path }
    }
    return $map
}

# Generic console picker: type a number to choose, text to filter, Enter to clear, q to cancel.
# $Label renders one item; $Match returns the text the filter searches. Returns the item or $null.
function Select-FromList([object[]]$Items, [scriptblock]$Label, [scriptblock]$Match, [string]$Title, [int]$Show = 25) {
    $filter = ''
    while ($true) {
        $list = @(if ($filter) { $Items | Where-Object { (& $Match $_) -like "*$filter*" } } else { $Items })
        Write-Host ''
        Write-Host "$Title$(if ($filter) { " (filter: '$filter')" }):"
        $max = [Math]::Min($list.Count, $Show)
        for ($i = 0; $i -lt $max; $i++) { Write-Host ("  [{0,2}] {1}" -f ($i + 1), (& $Label $list[$i])) }
        if ($list.Count -gt $Show) { Write-Host "  ... $($list.Count - $Show) more - type part of a name to filter" -ForegroundColor DarkGray }
        if ($list.Count -eq 0) { Write-Warn "Nothing matches '$filter'." }
        $a = (Read-Host 'Number, text to filter, Enter = clear filter, q = cancel').Trim()
        if ($a -eq 'q') { return $null }
        $n = 0
        if ([int]::TryParse($a, [ref]$n)) {
            if ($n -ge 1 -and $n -le $max) { return $list[$n - 1] }
            Write-Warn "Enter a number between 1 and $max."; continue
        }
        $filter = $a
        if ($filter) {
            # A filter that leaves exactly one item selects it directly.
            $only = @($Items | Where-Object { (& $Match $_) -like "*$filter*" })
            if ($only.Count -eq 1) { Write-Info "Selected: $(& $Label $only[0])"; return $only[0] }
        }
    }
}

# Pick any branch (local or origin) of a repository. Returns the Get-MatchingBranches object or $null.
function Select-Branch([string]$Root, [string]$Pattern = '', [string]$Title = 'Pick a branch (newest first)') {
    $branches = @(Get-MatchingBranches $Root $Pattern 0)
    if ($branches.Count -eq 0) { throw "No branches found$(if ($Pattern) { " matching '$Pattern'" })." }
    $out = Get-CheckedOutBranches $Root
    $label = {
        param($b)
        $tags = @()
        if ($b.Remote) { $tags += 'remote' }
        if ($out.ContainsKey($b.Name)) { $tags += 'checked out' }
        "{0,-60} {1,-16}{2}" -f $b.Name, $b.When, $(if ($tags) { " [$($tags -join ', ')]" } else { '' })
    }.GetNewClosure()
    return Select-FromList $branches $label { param($b) $b.Name } $Title
}

$script:RecentFile = Join-Path $env:LOCALAPPDATA 'claude-agent\recent-repos.json'

function Get-RecentRepos {
    if (-not (Test-Path $script:RecentFile)) { return @() }
    try { return @(Get-Content $script:RecentFile -Raw | ConvertFrom-Json) } catch { return @() }
}
function Add-RecentRepo([string]$Root) {
    $list = @($Root) + @(Get-RecentRepos | Where-Object { $_ -ine $Root }) | Select-Object -First 15
    New-Item -ItemType Directory -Force (Split-Path $script:RecentFile) | Out-Null
    ConvertTo-Json @($list) | Set-Content $script:RecentFile
}

# Git repositories under the given folders (a folder that is a repo is not descended into).
function Find-GitRepos([string[]]$Roots, [int]$Depth = 2) {
    $found = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($r in $Roots) { if ($r -and (Test-Path $r -PathType Container)) { $queue.Enqueue(@((Resolve-Path $r).Path, 0)) } }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue(); $dir = $item[0]; $level = $item[1]
        if (Test-Path (Join-Path $dir '.git') -PathType Container) { $found.Add($dir); continue }
        if ($level -ge $Depth) { continue }
        Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(\.|node_modules$|bin$|obj$|AppData$|packages$)' } |
            ForEach-Object { $queue.Enqueue(@($_.FullName, ($level + 1))) }
    }
    return $found.ToArray()
}

# All repositories the picker offers: recent first, then everything under repoRoots / -Roots.
function Get-KnownRepos([string[]]$ExtraRoots = @()) {
    $cfg = $null
    if (Test-Path $script:ConfigFile) { $cfg = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json }
    $roots = @(Get-Prop $cfg 'repoRoots' @() | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
    $depth = [int](Get-Prop $cfg 'repoScanDepth' 2)
    # The folder you right-clicked is scanned one level deep only, and never your profile or a drive root (too slow).
    $extra = @($ExtraRoots | Where-Object { $_ -and $_ -ine $env:USERPROFILE -and $_ -notmatch '^[A-Za-z]:\\?$' -and ($roots -notcontains $_) })
    $recent = @(Get-RecentRepos | Where-Object { Test-Path (Join-Path $_ '.git') -PathType Container })
    $scanned = @(@(Find-GitRepos $extra 1) + @(Find-GitRepos $roots $depth) | Sort-Object { Split-Path $_ -Leaf })
    $seen = @{}; $all = @()
    foreach ($p in $recent + $scanned) {
        $k = $p.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $all += [pscustomobject]@{ Path = $p; Name = (Split-Path $p -Leaf); Recent = ($recent -contains $p); Agents = @(Get-AgentWorktrees $p).Count }
    }
    return $all
}

# Console picker. Type a number, or text to filter the list. Returns the chosen path or $null.
function Select-Repo([string[]]$ExtraRoots = @(), [string]$Title = 'Pick a repository') {
    $all = @(Get-KnownRepos $ExtraRoots)
    if ($all.Count -eq 0) { throw "No git repositories found. Add folders to 'repoRoots' in $($script:ConfigFile)." }
    $label = {
        param($r)
        $tags = @()
        if ($r.Recent) { $tags += 'recent' }
        if ($r.Agents -gt 0) { $tags += "$($r.Agents) agent$(if ($r.Agents -ne 1) { 's' })" }
        "{0,-40} {1}{2}" -f $r.Name, (Split-Path $r.Path -Parent), $(if ($tags) { "  [$($tags -join ', ')]" } else { '' })
    }
    $picked = Select-FromList $all $label { param($r) $r.Path } $Title 50
    if ($picked) { return $picked.Path } else { return $null }
}

function Get-AgentMeta([string]$Slug, [string]$Agent) {
    $f = Join-Path $script:MetaDir "$Slug-$Agent.json"
    if (Test-Path $f) { return Get-Content $f -Raw | ConvertFrom-Json }
    return $null
}
function Set-AgentMeta([string]$Slug, [string]$Agent, [hashtable]$Data) {
    New-Item -ItemType Directory -Force $script:MetaDir | Out-Null
    $Data | ConvertTo-Json | Set-Content (Join-Path $script:MetaDir "$Slug-$Agent.json")
}
function Remove-AgentMeta([string]$Slug, [string]$Agent) {
    Remove-Item (Join-Path $script:MetaDir "$Slug-$Agent.json") -ErrorAction SilentlyContinue
}

# Copy gitignored files listed in the repo's .worktreeinclude into a new worktree, the same way
# Claude Code's --worktree does: only files that match a pattern AND are gitignored are copied,
# and existing files are never overwritten. Read from the main checkout, which agents cannot edit.
function Copy-WorktreeIncludes([string]$Root, [string]$WorktreePath) {
    $inc = Join-Path $Root '.worktreeinclude'
    if (-not (Test-Path $inc -PathType Leaf)) { return }
    $ignored = @{}
    foreach ($f in (& git -C $Root -c core.quotePath=false ls-files --others --ignored --exclude-standard)) { $ignored[$f] = $true }
    $wanted = @(& git -C $Root -c core.quotePath=false ls-files --others --ignored "--exclude-from=$inc" | Where-Object { $ignored.ContainsKey($_) })
    $copied = 0
    foreach ($f in $wanted) {
        $dst = Join-Path $WorktreePath $f
        if (Test-Path -LiteralPath $dst) { continue }
        New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Root $f) -Destination $dst
        $copied++
    }
    if ($copied) { Write-Info "Copied $copied gitignored file(s) listed in .worktreeinclude" }
}

function Get-WorktreeBranch([string]$WorktreePath) {
    $b = & git -C $WorktreePath branch --show-current 2>$null
    if ($LASTEXITCODE -eq 0 -and $b) { return $b.Trim() }
    return $null
}

function Write-Info($msg) { Write-Host "[claude-agent] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[claude-agent] $msg" -ForegroundColor Yellow }

# Usage: Invoke-Git <repo> <git args...>   (plain function so flags like -b pass through untouched)
function Invoke-Git {
    $repoPath = $args[0]
    $gitArgs = @($args | Select-Object -Skip 1)
    $out = & git -C $repoPath -c core.longpaths=true @gitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed:`n$($out -join "`n")" }
    return $out
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker is not on PATH. Install Docker Desktop.' }
    & docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker engine is not running. Start Docker Desktop and try again.' }
}

# Returns @{ Root; GitDir } for a normal (non-worktree, non-bare) repository, or $null.
function Get-RepoInfo([string]$Path) {
    $top = & git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
    $root = (Resolve-Path ($top -replace '/', '\')).Path
    $gitDir = Join-Path $root '.git'
    if (-not (Test-Path $gitDir -PathType Container)) {
        throw "'$root' is itself a worktree or submodule. Run this from the main checkout."
    }
    return @{ Root = $root; GitDir = $gitDir }
}

# Stable, docker-safe identifier per repository: <folder-name>-<hash of full path>.
function Get-RepoSlug([string]$Root) {
    $name = ($(Split-Path $Root -Leaf).ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $name) { $name = 'repo' }
    if ($name.Length -gt 24) { $name = $name.Substring(0, 24).Trim('-') }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant()))[0..3] | ForEach-Object { $_.ToString('x2') })
    return "$name-$hash"
}

function Get-AgentWorktrees([string]$Root) {
    $dir = Join-Path $Root $script:WorktreeDir
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem $dir -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') -PathType Leaf } | ForEach-Object Name)
}

function Get-ContainerName([string]$Slug, [string]$Agent) { "claude-$Slug-$Agent" }
function Get-VolumeName([string]$Slug, [string]$Agent)    { "claude-cfg-$Slug-$Agent" }

function Get-StoredToken {
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) { return $env:CLAUDE_CODE_OAUTH_TOKEN }
    if (-not (Test-Path $script:TokenFile)) { return $null }
    $secure = Get-Content $script:TokenFile -Raw | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
