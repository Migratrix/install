#Requires -Version 5
<#
.SYNOPSIS
  One-shot local setup for the Migratrix agent (Windows).

.DESCRIPTION
  Prepares the working directory for `docker compose up`, tailored to a TLS mode:
    localhost  mkcert-trusted cert for agent.localhost           (default; local dev)
    managed    Migratrix issues a subdomain + cert when the agent registers
    custom     your domain; cert uploaded in Account Settings, pushed on register
    ip         direct IP;  cert uploaded in Account Settings, pushed on register

  Lays down .\certs, .\traefik\dynamic\tls.yml and .env. For localhost it installs
  mkcert + the trusted cert; for the other modes the agent provisions the cert
  after it connects. Re-runs elevated (Administrator) for the hosts file / trust store.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1 -ApiKey mgx_xxx
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1 -Mode custom -HostName agent.acme.com -ApiKey mgx_xxx -GithubToken ghp_xxx
#>
[CmdletBinding()]
param(
    [ValidateSet("localhost", "managed", "custom", "ip")]
    [string]$Mode = "localhost",
    [string]$HostName = "",
    [Parameter(Mandatory = $true)][string]$ApiKey,
    # The orchestrator the agent connects to (default: Migratrix SaaS; on-premise: your own orchestrator's URL).
    [string]$OrchestratorUrl = "",
    # Registry read token, when Migratrix gave you one. Without it the images are pulled anonymously.
    [string]$GithubToken = "",
    [string]$GithubUser = "migratrix-bot",
    # Do not pull the images now (local builds, or Docker not running yet).
    [switch]$NoPull
)

$ErrorActionPreference = 'Stop'

# --- host defaulting / validation per mode ---------------------------------
switch ($Mode) {
    "localhost" { if (-not $HostName) { $HostName = "agent.localhost" } }
    { $_ -in "custom", "ip" } { if (-not $HostName) { throw "-HostName is required for -Mode $Mode" } }
    "managed" { } # hostname assigned by Migratrix at registration
}

# --- self-elevate (hosts file + machine trust store need admin) ------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argLine = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode `"$Mode`" -HostName `"$HostName`" -ApiKey `"$ApiKey`" -OrchestratorUrl `"$OrchestratorUrl`" -GithubToken `"$GithubToken`" -GithubUser `"$GithubUser`""
    if ($NoPull) { $argLine += " -NoPull" }
    Start-Process powershell -ArgumentList $argLine -Verb RunAs
    exit
}

$RepoRoot   = Split-Path $PSScriptRoot -Parent
$CertsDir   = Join-Path $RepoRoot 'certs'
$DynamicDir = Join-Path $RepoRoot 'traefik\dynamic'
$TlsFile    = Join-Path $DynamicDir 'tls.yml'
$EnvFile    = Join-Path $RepoRoot '.env'
New-Item -ItemType Directory -Force -Path $CertsDir, $DynamicDir | Out-Null

function Write-Tls([string]$CertFile) {
    $key = $CertFile -replace '\.pem$', '-key.pem'
    @"
tls:
  certificates:
    - certFile: /certs/$CertFile
      keyFile: /certs/$key
"@ | Set-Content -Path $TlsFile -Encoding ascii
}

# --- TLS bootstrap (mode-specific) -----------------------------------------
if ($Mode -eq "localhost") {
    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
        Write-Host "mkcert not found - attempting to install..."
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install mkcert -y
        } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install -e --id FiloSottile.mkcert --accept-source-agreements --accept-package-agreements
        } else {
            throw "Neither Chocolatey nor winget found. Install mkcert manually: https://github.com/FiloSottile/mkcert#installation"
        }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) { throw "mkcert still not on PATH after install" }

    mkcert -install
    # Real cert as agent.crt/agent.key so the agent adopts it.
    mkcert -cert-file (Join-Path $CertsDir 'agent.crt') -key-file (Join-Path $CertsDir 'agent.key') `
        $HostName "*.localhost" localhost 127.0.0.1 ::1
    Copy-Item (Join-Path $CertsDir 'agent.crt') (Join-Path $CertsDir 'live-bootstrap.pem') -Force
    Copy-Item (Join-Path $CertsDir 'agent.key') (Join-Path $CertsDir 'live-bootstrap-key.pem') -Force
    Write-Tls 'live-bootstrap.pem'
    Write-Host "Generated mkcert certificate for $HostName; wrote $TlsFile"

    # Windows does not auto-resolve *.localhost
    $HostsFile = "$env:windir\System32\drivers\etc\hosts"
    $pattern = "\b" + [regex]::Escape($HostName) + "\b"
    if (-not (Select-String -Path $HostsFile -Pattern $pattern -Quiet)) {
        Add-Content -Path $HostsFile -Value "`r`n127.0.0.1`t$HostName"
        Write-Host "Added 127.0.0.1 $HostName to hosts"
    }
} else {
    # managed/custom/ip: the agent generates a temporary self-signed cert on
    # first boot and hot-swaps the real one after it connects. No hosts entry:
    # custom/managed use real DNS, ip is an address.
    Write-Host "No local certificate for mode '$Mode' - the agent provisions it after it connects."
}

# --- env -------------------------------------------------------------------
$EnvExample = Join-Path $RepoRoot '.env.example'
if ((-not (Test-Path $EnvFile)) -and (Test-Path $EnvExample)) {
    Copy-Item $EnvExample $EnvFile
    Write-Host "Seeded $EnvFile from .env.example"
}
function Set-EnvVar([string]$Key, [string]$Value) {
    $lines = @()
    if (Test-Path $EnvFile) {
        $lines = @(Get-Content $EnvFile | Where-Object { $_ -notmatch "^$Key=" })
    }
    $lines += "$Key=$Value"
    Set-Content -Path $EnvFile -Value $lines -Encoding ascii
}
Set-EnvVar 'MIGRATRIX_MODE' $Mode
if ($HostName) { Set-EnvVar 'AGENT_HOST' $HostName }
Set-EnvVar 'MIGRATRIX_API_KEY' $ApiKey
if ($OrchestratorUrl) { Set-EnvVar 'MIGRATRIX_ORCHESTRATOR_URL' $OrchestratorUrl.TrimEnd('/') }
# The Risk Assessment API's GitHub webhook secret: generated once, kept on later runs (GitHub holds the same value).
if (-not (Select-String -Path $EnvFile -Pattern '^MIGRATRIX_GITHUB_WEBHOOK_SECRET=.+' -Quiet)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    Set-EnvVar 'MIGRATRIX_GITHUB_WEBHOOK_SECRET' (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    Write-Host "Generated MIGRATRIX_GITHUB_WEBHOOK_SECRET in $EnvFile (use it as the GitHub webhook secret)"
}
Write-Host "Updated $EnvFile (MIGRATRIX_MODE=$Mode)"

# --- registry login (only with a real token) ------------------------------
# The registry the compose file pulls from (REGISTRY in .env, e.g. ghcr.io/migratrix/).
$RegistryPrefix = (Get-Content $EnvFile | Where-Object { $_ -match '^REGISTRY=' } | Select-Object -Last 1) -replace '^REGISTRY=', ''
$RegistryHost = if ($RegistryPrefix) { ($RegistryPrefix -split '/')[0] } else { 'ghcr.io' }
if ($GithubToken -match 'xxxx' -or $GithubToken -match '^<.*>$') {
    throw "-GithubToken is a placeholder; leave it out to pull anonymously, or pass the token Migratrix gave you"
}
if ($GithubToken) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "-GithubToken given but docker is not installed" }
    $GithubToken | docker login $RegistryHost -u $GithubUser --password-stdin | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$RegistryHost refused the registry token given with -GithubToken (expired or wrong?). Run the installer again with a valid token, or without -GithubToken to pull anonymously."
    }
    Write-Host "Logged in to $RegistryHost as $GithubUser"
} else {
    Write-Host "No -GithubToken: not logging in to $RegistryHost; the images are pulled anonymously"
}

# --- pull the images ---------------------------------------------------------
if (-not $NoPull) {
    $dockerUp = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        docker info *> $null
        $dockerUp = ($LASTEXITCODE -eq 0)
    }
    if (-not $dockerUp) {
        Write-Host "Docker is not installed or not running: the images are pulled when you run docker compose up -d"
    } else {
        Push-Location $RepoRoot
        try { docker compose pull } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) {
            $what = if ($RegistryPrefix) { $RegistryPrefix } else { $RegistryHost }
            if ($GithubToken) {
                throw "Could not pull the Migratrix images from $what. The registry refused the token given with -GithubToken, or the images do not exist there."
            }
            throw "Could not pull the Migratrix images from $what. The registry refused anonymous access. If Migratrix gave you a registry token, run the installer again with -GithubToken <token>; otherwise contact Migratrix support."
        }
    }
}

Write-Host ""
Write-Host "Done (mode: $Mode). Start the agent:" -ForegroundColor Green
Write-Host "   cd `"$RepoRoot`""
Write-Host "   docker compose up -d"
Write-Host ""
switch ($Mode) {
    "localhost" { Write-Host "   Agent will be reachable at: https://$HostName" }
    { $_ -in "custom", "ip" } { Write-Host "   Reachable at: https://$HostName once the agent applies its certificate." }
    "managed" { Write-Host "   Migratrix will assign a subdomain + certificate after the agent connects." }
}
