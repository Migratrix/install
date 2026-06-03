#Requires -Version 5
<#
.SYNOPSIS
  Migratrix bootstrap (Windows) — PUBLIC one-liner entrypoint.

.DESCRIPTION
  Downloads the compose file, the .env template and the real installer into a
  working directory, then hands off to the installer. The container images stay
  private (ghcr.io) and are gated by -GithubToken.

.EXAMPLE
  # Because args must pass through iex, create a scriptblock from the download:
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) `
      -HostName agent.acme.com -ApiKey mgx_xxx -GithubToken ghp_xxx

.NOTES
  Overridable via env: MIGRATRIX_BASE_URL, MIGRATRIX_DIR
#>
[CmdletBinding()]
param(
    [string]$HostName = "agent.localhost",
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$GithubToken = "",
    [string]$GithubUser = "migratrix-bot"
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
& powershell -ExecutionPolicy Bypass -File 'scripts\migratrix-install.ps1' `
    -HostName $HostName -ApiKey $ApiKey -GithubToken $GithubToken -GithubUser $GithubUser
