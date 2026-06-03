#Requires -Version 5
<#
.SYNOPSIS
  One-shot local setup for the Migratrix agent (Windows).

.DESCRIPTION
  Installs mkcert (via Chocolatey or winget) if missing, installs its local CA
  into the trust stores, generates a TLS cert for HostName into .\certs, points
  Traefik's file provider (traefik-tls.yml) at it, adds a hosts-file entry, and
  writes HostName + API key into .env (consumed by both compose files).

  Re-runs automatically elevated (Administrator) because the hosts file and the
  machine trust store require it.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\migratrix-install.ps1 -ApiKey mgx_xxx
  powershell -ExecutionPolicy Bypass -File scripts\migratrix-install.ps1 -HostName agent.acme.com -ApiKey mgx_xxx -GithubToken ghp_xxx
#>
[CmdletBinding()]
param(
    [string]$HostName = "agent.localhost",
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$GithubToken = "",
    [string]$GithubUser = "migratrix-bot"
)

$ErrorActionPreference = 'Stop'

# --- self-elevate (hosts file + machine trust store need admin) ------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argLine = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -HostName `"$HostName`" -ApiKey `"$ApiKey`" -GithubToken `"$GithubToken`" -GithubUser `"$GithubUser`""
    Start-Process powershell -ArgumentList $argLine -Verb RunAs
    exit
}

$RepoRoot = Split-Path $PSScriptRoot -Parent
$CertsDir = Join-Path $RepoRoot 'certs'
$TlsFile  = Join-Path $RepoRoot 'traefik-tls.yml'
$EnvFile  = Join-Path $RepoRoot '.env'

# --- 1. ensure mkcert is installed -----------------------------------------
if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    Write-Host "mkcert not found - attempting to install..."
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        choco install mkcert -y
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id FiloSottile.mkcert --accept-source-agreements --accept-package-agreements
    } else {
        throw "Neither Chocolatey nor winget found. Install mkcert manually: https://github.com/FiloSottile/mkcert#installation"
    }
    # refresh PATH for the current session so the freshly installed mkcert is found
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}
if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    throw "mkcert still not on PATH after install"
}

# --- 2. install the local CA into the trust stores -------------------------
mkcert -install

# --- 3. generate a cert for HostName ---------------------------------------
New-Item -ItemType Directory -Force -Path $CertsDir | Out-Null
$CertPem = Join-Path $CertsDir "$HostName.pem"
$KeyPem  = Join-Path $CertsDir "$HostName-key.pem"
mkcert -cert-file $CertPem -key-file $KeyPem $HostName "*.localhost" localhost 127.0.0.1 ::1
Write-Host "Generated $CertPem"

# --- 4. point Traefik's file provider at the new cert ----------------------
@"
tls:
  certificates:
    - certFile: /certs/$HostName.pem
      keyFile: /certs/$HostName-key.pem
"@ | Set-Content -Path $TlsFile -Encoding ascii
Write-Host "Updated $TlsFile"

# --- 5. hosts entry (Windows does not auto-resolve *.localhost) ------------
$HostsFile = "$env:windir\System32\drivers\etc\hosts"
$pattern = "\b" + [regex]::Escape($HostName) + "\b"
if (-not (Select-String -Path $HostsFile -Pattern $pattern -Quiet)) {
    Add-Content -Path $HostsFile -Value "`r`n127.0.0.1`t$HostName"
    Write-Host "Added 127.0.0.1 $HostName to hosts"
}

# --- 6. write env ----------------------------------------------------------
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
Set-EnvVar 'AGENT_HOST' $HostName
Set-EnvVar 'MIGRATRIX_API_KEY' $ApiKey
Write-Host "Updated $EnvFile (AGENT_HOST, MIGRATRIX_API_KEY)"

# --- 7. log in to ghcr.io (only when a token is supplied) ------------------
if ($GithubToken) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "-GithubToken given but docker is not installed"
    }
    $GithubToken | docker login ghcr.io -u $GithubUser --password-stdin
    Write-Host "Logged in to ghcr.io as $GithubUser"
} else {
    Write-Host "No -GithubToken supplied - skipping ghcr.io login (fine for local builds)"
}

Write-Host ""
Write-Host "Done. Bring the stack up with one of:" -ForegroundColor Green
Write-Host "   Production:  docker compose up -d"
Write-Host "   Local dev:   docker compose -f docker-compose.local.yml up -d --build"
Write-Host ""
Write-Host "   Agent will be reachable at: https://$HostName"
