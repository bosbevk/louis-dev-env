<#
.SYNOPSIS
    Store a long-lived Claude Code OAuth token for agent containers, encrypted with Windows DPAPI.

.DESCRIPTION
    1. On the host run:  claude setup-token   and copy the token it prints.
    2. Run this script and paste the token (input is hidden).

    The token is encrypted for the current Windows user only
    (%LOCALAPPDATA%\claude-agent\oauth-token.dpapi). Start-ClaudeAgent.ps1 passes it to the
    container as CLAUDE_CODE_OAUTH_TOKEN by name, so it never appears on a command line.
    Note: anything running inside a container can read that variable; only use trusted repos.

.EXAMPLE
    .\Set-ClaudeToken.ps1
.EXAMPLE
    .\Set-ClaudeToken.ps1 -Clear
#>
[CmdletBinding()]
param([switch]$Clear)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAgent.Common.ps1')

if ($Clear) {
    Remove-Item $script:TokenFile -ErrorAction SilentlyContinue
    Write-Info 'Stored token removed.'
    return
}

$secure = Read-Host 'Paste the token from "claude setup-token"' -AsSecureString
if ($secure.Length -lt 20) { throw 'That does not look like a token.' }

New-Item -ItemType Directory -Force (Split-Path $script:TokenFile) | Out-Null
$secure | ConvertFrom-SecureString | Set-Content -Path $script:TokenFile -NoNewline

# Restrict the file to the current user.
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
Set-Acl -Path $script:TokenFile -AclObject $acl

Write-Info "Token stored (DPAPI, current user only): $($script:TokenFile)"
