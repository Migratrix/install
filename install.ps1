#Requires -Version 5
<#
.SYNOPSIS
  Migratrix bootstrap (Windows) — PUBLIC one-liner entrypoint.

.DESCRIPTION
  Downloads the compose file, the .env template and the real installer into a
  working directory, then hands off to the installer. The installer pulls the
  container images (ghcr.io): anonymously, or with -GithubToken when Migratrix gave
  you a registry token.

.EXAMPLE
  # Because args must pass through iex, create a scriptblock from the download:
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) `
      -HostName agent.acme.com -ApiKey mgx_xxx -GithubToken ghp_xxx

.NOTES
  Overridable via env: MIGRATRIX_BASE_URL, MIGRATRIX_DIR
#>
[CmdletBinding()]
param(
    [ValidateSet("localhost", "managed", "custom", "ip")]
    [string]$Mode = "localhost",
    [string]$HostName = "",
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$OrchestratorUrl = "",
    [string]$GithubToken = "",
    [string]$GithubUser = "migratrix-bot",
    [switch]$NoPull
)

$ErrorActionPreference = 'Stop'

$Base    = if ($env:MIGRATRIX_BASE_URL) { $env:MIGRATRIX_BASE_URL } else { "https://get.migratrix.com" }
$WorkDir = if ($env:MIGRATRIX_DIR)      { $env:MIGRATRIX_DIR }      else { Join-Path $HOME 'migratrix' }

Write-Host "Migratrix bootstrap"
Write-Host "  source:      $Base"
Write-Host "  working dir: $WorkDir"

New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'scripts') | Out-Null
Set-Location $WorkDir

function Fetch($name, $dest) {
    Invoke-WebRequest -UseBasicParsing "$Base/$name" -OutFile $dest
    Write-Host "  fetched $name"
}
Fetch 'docker-compose.yml'    'docker-compose.yml'
Fetch '.env.example'          '.env.example'
Fetch 'migratrix-install.ps1' 'scripts\migratrix-install.ps1'

Write-Host "Running installer..."
# Only the options that have a value: Windows PowerShell drops empty arguments to a native command, which would
# shift the ones after them.
$installArgs = @('-ExecutionPolicy', 'Bypass', '-File', 'scripts\migratrix-install.ps1',
    '-Mode', $Mode, '-ApiKey', $ApiKey, '-GithubUser', $GithubUser)
if ($HostName)        { $installArgs += @('-HostName', $HostName) }
if ($OrchestratorUrl) { $installArgs += @('-OrchestratorUrl', $OrchestratorUrl) }
if ($GithubToken)     { $installArgs += @('-GithubToken', $GithubToken) }
if ($NoPull)          { $installArgs += '-NoPull' }
& powershell @installArgs
exit $LASTEXITCODE
