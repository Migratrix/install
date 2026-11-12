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
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) -ApiKey <key from Settings - Agents>
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) -Mode custom -HostName agent.acme.com
  # Without -ApiKey the installer asks for the key and does not echo it.

.NOTES
  Overridable via env: MIGRATRIX_BASE_URL, MIGRATRIX_DIR
  The downloaded files are checked against SHA256SUMS from the same place: a truncated or mixed-up download
  stops the install. (Same origin, so this is an integrity check of the transfer, not a signature.)
#>
[CmdletBinding()]
param(
    # Left out: localhost on a desktop Windows; Windows Server has no default and the installer asks for one.
    [ValidateSet("", "localhost", "managed", "custom", "ip")]
    [string]$Mode = "",
    [string]$HostName = "",
    # Left out: the installer reads MIGRATRIX_API_KEY, or asks for the key without echoing it.
    [string]$ApiKey = "",
    [string]$OrchestratorUrl = "",
    [string]$GithubToken = "",
    [string]$GithubUser = "migratrix-bot",
    [switch]$NoPull,
    [switch]$NoFirewall
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

# --- integrity: every fetched file must match the published checksum ----------
$sumsFile = Join-Path $env:TEMP ("migratrix-sums-" + [guid]::NewGuid().ToString('N') + ".txt")
try {
    Invoke-WebRequest -UseBasicParsing "$Base/SHA256SUMS" -OutFile $sumsFile
} catch {
    throw "Could not download $Base/SHA256SUMS; the downloaded files cannot be checked. Nothing was installed."
}
$sums = @{}
Get-Content $sumsFile | ForEach-Object {
    $parts = $_ -split '\s+', 2
    if ($parts.Count -eq 2) { $sums[$parts[1].TrimStart('*').Trim()] = $parts[0].ToLowerInvariant() }
}
Remove-Item -Force -ErrorAction SilentlyContinue $sumsFile
function Verify($name, $path) {
    $got = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
    if (-not $sums.ContainsKey($name) -or $sums[$name] -ne $got) {
        throw "$name does not match its published checksum (download damaged or changed). Nothing was installed."
    }
}
Verify 'docker-compose.yml'    'docker-compose.yml'
Verify '.env.example'          '.env.example'
Verify 'migratrix-install.ps1' 'scripts\migratrix-install.ps1'
Write-Host "  checksums ok"

Write-Host "Running installer..."
# Only the options that have a value: Windows PowerShell drops empty arguments to a native command, which would
# shift the ones after them. The key and the registry token go to the installer in its environment, not on its
# command line (process list).
$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts\migratrix-install.ps1',
    '-GithubUser', $GithubUser)
if ($Mode)            { $installArgs += @('-Mode', $Mode) }
if ($HostName)        { $installArgs += @('-HostName', $HostName) }
if ($OrchestratorUrl) { $installArgs += @('-OrchestratorUrl', $OrchestratorUrl) }
if ($NoPull)          { $installArgs += '-NoPull' }
if ($NoFirewall)      { $installArgs += '-NoFirewall' }
$hadKey = $env:MIGRATRIX_API_KEY
$hadToken = $env:MIGRATRIX_GITHUB_TOKEN
try {
    if ($ApiKey)      { $env:MIGRATRIX_API_KEY = $ApiKey }
    if ($GithubToken) { $env:MIGRATRIX_GITHUB_TOKEN = $GithubToken }
    & powershell @installArgs
    $code = $LASTEXITCODE
} finally {
    $env:MIGRATRIX_API_KEY = $hadKey
    $env:MIGRATRIX_GITHUB_TOKEN = $hadToken
}
# Run as a file: the exit code is the installer's. Run as the documented one-liner (a script block in the user's
# own PowerShell window), "exit" would close that window with the installer's messages in it.
if ($PSCommandPath) { exit $code }
$global:LASTEXITCODE = $code
if ($code -ne 0) { Write-Host "The Migratrix installer failed (exit code $code). See the messages above." -ForegroundColor Red }
