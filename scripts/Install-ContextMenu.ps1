<#
.SYNOPSIS
    Add a "Claude agent (Docker)" submenu to the Explorer right-click menu for folders and
    folder backgrounds. Per-user (HKCU), no admin rights needed.

.DESCRIPTION
    On Windows 11 the entry is under "Show more options" (or Shift+Right-click).
    Re-run after moving this folder. Remove with -Uninstall.
#>
[CmdletBinding()]
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$keyName = 'ClaudeAgentDocker'
$roots = @(
    'HKCU:\Software\Classes\Directory\shell',             # right-click a folder
    'HKCU:\Software\Classes\Directory\Background\shell'   # right-click inside a folder
)

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude agent.lnk'

foreach ($r in $roots) {
    $k = Join-Path $r $keyName
    if (Test-Path $k) { Remove-Item $k -Recurse -Force }
}
if (Test-Path $shortcut) { Remove-Item $shortcut -Force }
if ($Uninstall) { Write-Host 'Context menu and Start Menu shortcut removed.'; return }

$projectDir = Split-Path $PSScriptRoot -Parent
$personalCfg = Join-Path $projectDir 'repos.json'
if (-not (Test-Path $personalCfg)) {
    Copy-Item (Join-Path $projectDir 'repos.example.json') $personalCfg
    Write-Host "Created $personalCfg from the example - edit it to add your repositories."
}

$start  = Join-Path $PSScriptRoot 'Start-ClaudeAgent.ps1'
$remove = Join-Path $PSScriptRoot 'Remove-ClaudeAgent.ps1'

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }
$wt = (Get-Command wt -ErrorAction SilentlyContinue).Source
$claudeIcon = (Get-Command claude -ErrorAction SilentlyContinue).Source
$icon = if ($claudeIcon -and $claudeIcon -like '*.exe') { "`"$claudeIcon`",0" } else { "`"$pwsh`",0" }

function New-Command([string]$Script, [string]$ExtraArgs, [string]$Title) {
    $ps = "`"$pwsh`" -NoLogo -ExecutionPolicy RemoteSigned -File `"$Script`" -Path `"%V`" $ExtraArgs".Trim()
    if ($wt) { return "`"$wt`" -w 0 new-tab --title `"$Title`" -d `"%V`" $ps" }
    return $ps
}

$entries = @(
    @{ Key = '10new';   Label = 'New agent';                              Cmd = (New-Command $start  ''                  'Claude agent') },
    @{ Key = '15pick';  Label = 'New agent (pick repo)...';               Cmd = (New-Command $start  '-PickRepo'         'Claude agent') },
    @{ Key = '20yolo';  Label = 'New agent (unattended, skip permissions)'; Cmd = (New-Command $start  '-SkipPermissions'  'Claude agent (unattended)') },
    @{ Key = '30team';  Label = 'New agent team (tmux)';                  Cmd = (New-Command $start  '-Team'             'Claude agent team') },
    @{ Key = '40shell'; Label = 'Shell in agent container';               Cmd = (New-Command $start  '-Shell'            'Claude agent shell') },
    @{ Key = '90clean'; Label = 'Clean up agents...';                     Cmd = (New-Command $remove ''                  'Claude agent cleanup') }
)

foreach ($r in $roots) {
    $menu = Join-Path $r $keyName
    New-Item -Path $menu -Force | Out-Null
    New-ItemProperty -Path $menu -Name 'MUIVerb'     -Value 'Claude agent (Docker)' -Force | Out-Null
    New-ItemProperty -Path $menu -Name 'SubCommands' -Value ''                      -Force | Out-Null
    New-ItemProperty -Path $menu -Name 'Icon'        -Value $icon                   -Force | Out-Null
    foreach ($e in $entries) {
        $item = Join-Path $menu "shell\$($e.Key)"
        New-Item -Path "$item\command" -Force | Out-Null
        New-ItemProperty -Path $item -Name 'MUIVerb' -Value $e.Label -Force | Out-Null
        Set-Item -Path "$item\command" -Value $e.Cmd
    }
}

# Start Menu shortcut: opens the repository picker.
$psArgs = "-NoLogo -ExecutionPolicy RemoteSigned -File `"$start`" -PickRepo"
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
if ($wt) { $lnk.TargetPath = $wt; $lnk.Arguments = "-w 0 new-tab --title `"Claude agent`" `"$pwsh`" $psArgs" }
else     { $lnk.TargetPath = $pwsh; $lnk.Arguments = $psArgs }
$lnk.WorkingDirectory = $env:USERPROFILE
$lnk.Description = 'Start a Claude Code agent in Docker (pick a repository)'
$lnk.IconLocation = ($icon -replace '"', '')
$lnk.Save()

Write-Host 'Context menu installed: right-click a folder (Windows 11: "Show more options") > Claude agent (Docker).'
Write-Host "Start Menu shortcut: 'Claude agent' (opens the repository picker)."
Write-Host "Shell: $pwsh"
if (-not $wt) { Write-Host 'Windows Terminal not found; sessions open in a plain console window.' }
