<#
.SYNOPSIS
    Remove a Claude agent: its worktree, its config volume and (optionally) its branch.

.DESCRIPTION
    Refuses to remove a worktree with uncommitted changes, and only deletes the branch when it
    is already merged into the current HEAD, unless -Force is given.

.EXAMPLE
    .\Remove-ClaudeAgent.ps1 -Path C:\src\myrepo -Name auth-refactor -DeleteBranch
.EXAMPLE
    .\Remove-ClaudeAgent.ps1 -Path C:\src\myrepo          # interactive picker
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [string[]]$Name,
    [switch]$All,
    [switch]$DeleteBranch,
    [switch]$Force,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAgent.Common.ps1')

try {
    $target = (Resolve-Path $Path).Path
    $repo = Get-RepoInfo $target
    if (-not $repo) {
        $picked = Select-Repo @($target) 'Clean up agents in which repository?'
        if (-not $picked) { return }
        $target = $picked; $repo = Get-RepoInfo $target
    }
    $root = $repo.Root
    $slug = Get-RepoSlug $root
    $agents = @(if ($repo) { Get-AgentWorktrees $root })

    if ($All) { $Name = $agents }
    if (-not $Name) {
        if ($agents.Count -eq 0) { Write-Info 'No agent worktrees in this repository.'; return }
        Write-Host 'Agents:'
        for ($i = 0; $i -lt $agents.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $agents[$i]) }
        $sel = Read-Host 'Numbers to remove (comma separated, "all", Enter = cancel)'
        if (-not $sel) { return }
        $Name = if ($sel -eq 'all') { $agents } else { $sel -split ',' | ForEach-Object { $agents[[int]$_.Trim() - 1] } }
        if (-not $DeleteBranch) { $DeleteBranch = (Read-Host 'Also delete the agents'' branches if they are merged or empty? [y/N]') -match '^(y|yes)$' }
    }

    $hasDocker = $true
    try { Assert-Docker } catch { $hasDocker = $false; Write-Warn "$($_.Exception.Message) Skipping container/volume cleanup." }

    foreach ($n in $Name) {
        Write-Info "Removing agent '$n'"
        $container = Get-ContainerName $slug $n
        if ($hasDocker) {
            if (& docker ps -q --filter "name=^/$container$") {
                if (-not $Force) { Write-Warn "  container $container is running - stop it first or use -Force"; continue }
                & docker stop $container | Out-Null
            }
        }

        $meta = Get-AgentMeta $slug $n
        if ($repo) {
            $wt = "$($script:WorktreeDir)/$n"
            $wtPath = Join-Path $root ($wt -replace '/', '\')
            $branch = Get-WorktreeBranch $wtPath
            if (-not $branch) { $branch = Get-Prop $meta 'branch' }
            if (Test-Path $wtPath) {
                # The container is not running (checked above), so any lock left behind is stale.
                & git -C $root worktree unlock $wt 2>$null
                $wtArgs = @('-c', 'core.longpaths=true', 'worktree', 'remove') + $(if ($Force) { @('--force') } else { @() }) + @($wt)
                & git -C $root @wtArgs
                if ($LASTEXITCODE -ne 0) { Write-Warn '  worktree has uncommitted changes - commit them or use -Force'; continue }
            }
            if ($DeleteBranch -and $branch) {
                if (-not (Get-Prop $meta 'createdBranch' $false)) {
                    Write-Info "  branch $branch kept (it existed before this agent)"
                } else {
                    # Safe to delete when merged into HEAD, or when it has no commits beyond its start point.
                    $base = Get-Prop $meta 'base'
                    $ahead = if ($base) { (& git -C $root rev-list --count "$base..$branch" 2>$null) } else { $null }
                    if ($Force -or $ahead -eq '0') { & git -C $root branch -D $branch | Out-Null; $ok = ($LASTEXITCODE -eq 0) }
                    else { & git -C $root branch -d $branch 2>$null | Out-Null; $ok = ($LASTEXITCODE -eq 0) }
                    if ($ok) { Write-Info "  branch $branch deleted" }
                    else { Write-Warn "  branch $branch kept: it has unmerged commits (review it, or use -Force)" }
                }
            }
        }
        Remove-AgentMeta $slug $n

        if ($hasDocker) {
            $vol = Get-VolumeName $slug $n
            if (& docker volume ls -q --filter "name=^$vol$") { & docker volume rm $vol | Out-Null; Write-Info "  volume $vol removed" }
        }
    }
    if ($repo) { & git -C $root worktree prune }
}
catch {
    Write-Host "[claude-agent] ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
}
