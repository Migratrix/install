#Requires -Version 5
<#
.SYNOPSIS
  One-shot local setup for the Migratrix agent (Windows).

.DESCRIPTION
  Prepares the working directory for `docker compose up`, tailored to a TLS mode:
    localhost  mkcert-trusted cert for agent.localhost   (default on a desktop Windows: the agent is reached
               by a browser on this same machine only)
    managed    Migratrix issues a subdomain + cert when the agent registers
    custom     your domain; cert uploaded in Settings > Agents > Configure Agent, pushed on register
    ip         direct IP;  cert uploaded in Settings > Agents > Configure Agent, pushed on register

  On Windows Server there is no default: choose -Mode managed, custom or ip.

  Lays down .\certs, .\traefik\dynamic\tls.yml and .env. For localhost it installs
  mkcert + the trusted cert; for the other modes the agent provisions the cert
  after it connects and the installer opens the HTTPS port in Windows Firewall.

  Needs Administrator rights (hosts file, trust store, firewall). Started without them it asks for elevation,
  waits for the elevated run, shows its output here and returns its exit code.

  The agent key: -ApiKey, or the MIGRATRIX_API_KEY environment variable, or - with neither - the installer asks
  for it without echoing it.

  Image versions: the installer writes the released image tags (versions.env, downloaded and checked by the
  bootstrap) into .env. They are fixed tags - nothing here follows "latest" - so the machine stays on them until
  the installer is run again with -Upgrade, which keeps the key, the mode and the host of the install, writes
  the newly released tags, pulls them and restarts the containers. -Upgrade needs no Administrator rights.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1 -Mode custom -HostName agent.acme.com
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1 -Upgrade
#>
[CmdletBinding()]
param(
    [ValidateSet("", "localhost", "managed", "custom", "ip")]
    [string]$Mode = "",
    [string]$HostName = "",
    # The agent key from Settings > Agents in the Platform. Left out: MIGRATRIX_API_KEY, or a hidden prompt.
    [string]$ApiKey = "",
    # The orchestrator the agent connects to (default: Migratrix SaaS; on-premise: your own orchestrator's URL).
    [string]$OrchestratorUrl = "",
    # Registry read token, when Migratrix gave you one. Without it the images are pulled anonymously.
    [string]$GithubToken = "",
    [string]$GithubUser = "migratrix-bot",
    # Do not pull the images now (local builds, or Docker not running yet).
    [switch]$NoPull,
    # Do not add the Windows Firewall rule for the HTTPS port (modes managed / custom / ip).
    [switch]$NoFirewall,
    # An installed agent: write the released image versions, pull them and restart; key, mode and host are kept.
    [switch]$Upgrade,
    # Internal (the elevated run): where the first run left the key and token, where to write the output, and
    # who started the install.
    [string]$SecretsFile = "",
    [string]$LogFile = "",
    [string]$InstallUser = ""
)

$ErrorActionPreference = 'Stop'

# S-1-5-32-544 = Administrators, S-1-5-18 = SYSTEM (names differ per Windows language, the ids do not).
function Protect-File([string]$Path, [string]$User) {
    $grants = @('*S-1-5-32-544:F', '*S-1-5-18:F')
    if ($User) { $grants = @("${User}:F") + $grants }
    & icacls $Path /inheritance:r /grant:r @grants | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not restrict access to $Path (icacls exit $LASTEXITCODE)" }
}

# The last value of a key in a KEY=value file; empty when the file or the key is not there.
function Get-FileValue([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return "" }
    $line = Get-Content $Path | Where-Object { $_ -match "^$Key=" } | Select-Object -Last 1
    if ($null -eq $line) { return "" }
    return ([string]$line -replace "^$Key=", '').Trim()
}

function Install-Migratrix {
    $RepoRoot     = Split-Path $PSScriptRoot -Parent
    $EnvFile      = Join-Path $RepoRoot '.env'
    $VersionsFile = Join-Path $RepoRoot 'versions.env'

    # --- the released image versions -------------------------------------------
    # Read before anything is written: a set that is missing or not made of fixed tags stops the install.
    $imageKeys = @('AGENT_TAG', 'RISK_TAG', 'SQLGLOT_TAG', 'JAVA_ANALYZER_TAG', 'PYTHON_ANALYZER_TAG')
    if (-not (Test-Path $VersionsFile)) {
        throw "$VersionsFile (the released image versions) is missing. Run the install command again: & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) ..."
    }
    $released = @{}
    foreach ($key in $imageKeys) {
        $value = Get-FileValue $VersionsFile $key
        # A version X.Y.Z, or the commit an image was built from. Never a tag that moves.
        if ($value -cnotmatch '^(v?[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{40})$') {
            throw "$key in $VersionsFile is '$value', not a released version. Run the install command again; if it repeats, contact Migratrix support. Nothing was installed."
        }
        $released[$key] = $value
    }

    # --- upgrade: the settings of the install that is already here ---------------
    if ($Upgrade) {
        if ($Mode -or $HostName -or $ApiKey -or $OrchestratorUrl) {
            throw "-Upgrade keeps the settings of the install; leave out -Mode, -HostName, -ApiKey and -OrchestratorUrl"
        }
        $script:ApiKey   = Get-FileValue $EnvFile 'MIGRATRIX_API_KEY'
        $savedMode       = Get-FileValue $EnvFile 'MIGRATRIX_MODE'
        $script:HostName = Get-FileValue $EnvFile 'AGENT_HOST'
        if (-not $ApiKey -or $savedMode -notin @('localhost', 'managed', 'custom', 'ip')) {
            throw "There is no installed agent in $RepoRoot to upgrade (no .env with a key and a mode). Run the installer without -Upgrade to install one."
        }
        $script:Mode = $savedMode
    }

    # --- secrets handed over by the non-elevated run ---------------------------
    if ($SecretsFile) {
        if (-not (Test-Path $SecretsFile)) { throw "The installer's hand-over file is missing; run the installer again." }
        $handed = Get-Content -Raw -Path $SecretsFile | ConvertFrom-Json
        Remove-Item -Force $SecretsFile
        if ($handed.ApiKey)      { $script:ApiKey = [string]$handed.ApiKey }
        if ($handed.GithubToken) { $script:GithubToken = [string]$handed.GithubToken }
    }

    # --- mode: no default on a server -----------------------------------------
    if (-not $Mode) {
        $isServer = $false
        try { $isServer = ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) } catch { }
        if ($isServer) {
            throw @"
This is Windows Server: the default mode (localhost) would give an agent that only a browser on this machine could reach. Choose how the agent is reached:
  -Mode managed                           Migratrix assigns a public name and certificate
  -Mode custom -HostName <your domain>    your own name; upload its certificate in Settings > Agents
  -Mode ip -HostName <address>            this machine's address; upload its certificate in Settings > Agents
(-Mode localhost still installs the local-only setup, if that is what you want.)
"@
        }
        $script:Mode = "localhost"
    }

    # --- host defaulting / validation per mode ---------------------------------
    switch ($Mode) {
        "localhost" { if (-not $HostName) { $script:HostName = "agent.localhost" } }
        { $_ -in "custom", "ip" } { if (-not $HostName) { throw "-HostName is required for -Mode $Mode" } }
        "managed" { } # hostname assigned by Migratrix at registration
    }

    # --- the agent key: option, environment, or a prompt that does not echo -----
    if (-not $ApiKey -and $env:MIGRATRIX_API_KEY) { $script:ApiKey = $env:MIGRATRIX_API_KEY }
    if (-not $GithubToken -and $env:MIGRATRIX_GITHUB_TOKEN) { $script:GithubToken = $env:MIGRATRIX_GITHUB_TOKEN }
    if (-not $ApiKey -and [Environment]::UserInteractive -and -not $SecretsFile) {
        $secure = Read-Host -AsSecureString "Migratrix agent API key (Settings > Agents in the Platform; input is hidden)"
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $ApiKey) { throw "No agent API key: pass -ApiKey, or set MIGRATRIX_API_KEY" }

    # Placeholders copied from an example are refused before anything is installed or written.
    if ($ApiKey -match 'xxxx' -or $ApiKey -match '^<.*>$' -or $ApiKey -eq 'mgx_xxx') {
        throw "The API key is a placeholder; copy the real key from Settings > Agents in the Platform"
    }
    if ($GithubToken -match 'xxxx' -or $GithubToken -match '^<.*>$') {
        throw "-GithubToken is a placeholder; leave it out to pull anonymously, or pass the token Migratrix gave you"
    }

    # --- self-elevate (hosts file, machine trust store and firewall need admin) --
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    # An upgrade touches none of them: it writes .env, pulls and restarts, as the user who installed.
    if (-not $isAdmin -and -not $Upgrade) {
        $script:InstallExit = Invoke-Elevated $identity.Name
        return
    }
    if (-not $InstallUser) { $script:InstallUser = $identity.Name }

    $CertsDir   = Join-Path $RepoRoot 'certs'
    $DynamicDir = Join-Path $RepoRoot 'traefik\dynamic'
    $TlsFile    = Join-Path $DynamicDir 'tls.yml'
    New-Item -ItemType Directory -Force -Path $CertsDir, $DynamicDir | Out-Null

    # --- TLS bootstrap (mode-specific) -----------------------------------------
    if ($Upgrade) {
        Write-Host "Upgrade: the certificate and the settings of the install (mode: $Mode) are kept."
    } elseif ($Mode -eq "localhost") {
        if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
            Write-Host "mkcert not found - attempting to install..."
            if (Get-Command choco -ErrorAction SilentlyContinue) {
                choco install mkcert -y
            } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
                winget install -e --id FiloSottile.mkcert --accept-source-agreements --accept-package-agreements
            } else {
                # Windows Server ships neither package manager (onboarding trials AGI-04).
                throw @"
Mode localhost needs mkcert, and this machine has neither Chocolatey nor winget to install it with. Either:
  - choose a mode that needs no local certificate: -Mode managed, -Mode custom -HostName <your domain> or -Mode ip -HostName <address> (the right choice on a server), or
  - download mkcert-<version>-windows-amd64.exe from https://github.com/FiloSottile/mkcert/releases, save it as mkcert.exe in a folder on PATH (for example C:\Windows), and run the installer again.
"@
            }
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('Path', 'User')
        }
        if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) { throw "mkcert still not on PATH after install; open a new PowerShell window and run the installer again" }

        mkcert -install
        # Real cert as agent.crt/agent.key so the agent adopts it.
        mkcert -cert-file (Join-Path $CertsDir 'agent.crt') -key-file (Join-Path $CertsDir 'agent.key') `
            $HostName "*.localhost" localhost 127.0.0.1 ::1
        Copy-Item (Join-Path $CertsDir 'agent.crt') (Join-Path $CertsDir 'live-bootstrap.pem') -Force
        Copy-Item (Join-Path $CertsDir 'agent.key') (Join-Path $CertsDir 'live-bootstrap-key.pem') -Force
        @"
tls:
  certificates:
    - certFile: /certs/live-bootstrap.pem
      keyFile: /certs/live-bootstrap-key.pem
"@ | Set-Content -Path $TlsFile -Encoding ascii
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
    if (-not (Test-Path $EnvFile)) { New-Item -ItemType File -Path $EnvFile | Out-Null }
    # .env holds the agent key: the installing user, Administrators and SYSTEM only (SEC-06).
    Protect-File $EnvFile $InstallUser

    function Set-EnvVar([string]$Key, [string]$Value) {
        $lines = @(Get-Content $EnvFile | Where-Object { $_ -notmatch "^$Key=" })
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
    # The released image versions. What ran before is kept for the summary of an upgrade.
    $versionsChanged = $false
    $versionLines = @()
    foreach ($key in $imageKeys) {
        $new = $released[$key]
        $old = Get-FileValue $EnvFile $key
        if ($old -eq $new) {
            $versionLines += "   $key=$new (unchanged)"
        } else {
            $versionsChanged = $true
            $was = if ($old) { " (was $old)" } else { "" }
            $versionLines += "   $key=$new$was"
            Set-EnvVar $key $new
        }
    }
    Write-Host "Updated $EnvFile (MIGRATRIX_MODE=$Mode; readable by $InstallUser and Administrators only)"
    Write-Host "Image versions:"
    $versionLines | ForEach-Object { Write-Host $_ }

    # --- Windows Firewall: the HTTPS port, for a browser on another machine ------
    $HttpsPort = (Get-Content $EnvFile | Where-Object { $_ -match '^HTTPS_PORT=\d+' } | Select-Object -Last 1) -replace '^HTTPS_PORT=', ''
    if (-not $HttpsPort) { $HttpsPort = '443' }
    $firewallNote = ""
    if ($Upgrade) {
        # The rule of the install is kept as it is.
    } elseif ($Mode -ne "localhost" -and -not $NoFirewall) {
        $ruleName = "Migratrix Agent (HTTPS $HttpsPort)"
        try {
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
                    -LocalPort ([int]$HttpsPort) -Profile Any | Out-Null
                Write-Host "Windows Firewall: opened inbound TCP $HttpsPort (rule '$ruleName')"
            } else {
                Write-Host "Windows Firewall: rule '$ruleName' already exists"
            }
        } catch {
            $firewallNote = "Windows Firewall rule not added ($($_.Exception.Message)). Open inbound TCP $HttpsPort yourself, or the agent cannot be reached from another machine."
            Write-Warning $firewallNote
        }
    } elseif ($Mode -ne "localhost") {
        $firewallNote = "-NoFirewall: inbound TCP $HttpsPort must be open in Windows Firewall for the agent to be reached from another machine."
    }

    # --- registry login (only with a real token) ------------------------------
    # The registry the compose file pulls from (REGISTRY in .env, e.g. ghcr.io/migratrix/).
    $RegistryPrefix = (Get-Content $EnvFile | Where-Object { $_ -match '^REGISTRY=' } | Select-Object -Last 1) -replace '^REGISTRY=', ''
    $RegistryHost = if ($RegistryPrefix) { ($RegistryPrefix -split '/')[0] } else { 'ghcr.io' }
    # A login to the registry that Docker already holds on this machine (docker login done earlier).
    $dockerConfigDir = if ($env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { Join-Path $env:USERPROFILE '.docker' }
    $dockerConfig = Join-Path $dockerConfigDir 'config.json'
    $storedLogin = (Test-Path $dockerConfig) -and
        [bool](Select-String -Path $dockerConfig -SimpleMatch ('"' + $RegistryHost + '"') -Quiet)
    if ($GithubToken) {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "-GithubToken given but docker is not installed" }
        $GithubToken | docker login $RegistryHost -u $GithubUser --password-stdin | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "$RegistryHost refused the registry token given with -GithubToken (expired or wrong?). Run the installer again with a valid token, or without -GithubToken to pull anonymously."
        }
        Write-Host "Logged in to $RegistryHost as $GithubUser"
    } elseif ($storedLogin) {
        Write-Host "No -GithubToken: the images are pulled with the $RegistryHost login already stored on this machine"
    } else {
        Write-Host "No -GithubToken: not logging in to $RegistryHost; the images are pulled anonymously"
    }

    # --- pull the images ---------------------------------------------------------
    if (-not $NoPull) {
        $dockerUp = $false
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            # Through cmd: with $ErrorActionPreference = 'Stop', PowerShell 5 turns a redirected stderr line of a
            # native command into a terminating error, so a Docker that is not running ended the install here.
            cmd /c "docker info >nul 2>&1"
            $dockerUp = ($LASTEXITCODE -eq 0)
        }
        if (-not $dockerUp -and $Upgrade) {
            throw "Docker is not installed or not running, so the new images were not pulled and the containers still run the versions they had. .env already names the new versions: start Docker and run 'docker compose pull' and 'docker compose up -d' in $RepoRoot."
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
                if ($storedLogin) {
                    throw "Could not pull the Migratrix images from $what. The registry refused the $RegistryHost login stored on this machine, or the images do not exist there. If Migratrix gave you a registry token, run the installer again with -GithubToken <token>."
                }
                throw "Could not pull the Migratrix images from $what. The registry refused anonymous access. If Migratrix gave you a registry token, run the installer again with -GithubToken <token>; otherwise contact Migratrix support."
            }
        }
    }

    # --- upgrade: restart on the new images ---------------------------------------
    if ($Upgrade) {
        Write-Host ""
        if ($NoPull) {
            Write-Host ".env names the released versions (-NoPull: nothing was pulled or restarted). To move the containers to them:" -ForegroundColor Green
            Write-Host "   cd `"$RepoRoot`""
            Write-Host "   docker compose pull"
            Write-Host "   docker compose up -d"
            $script:InstallExit = 0
            return
        }
        Push-Location $RepoRoot
        try { docker compose up -d --remove-orphans } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) {
            throw "The new images were pulled but the containers could not be restarted; see the message above. Run 'docker compose up -d' in $RepoRoot once it is solved."
        }
        if ($versionsChanged) {
            Write-Host "Upgraded. The agent restarts and reconnects by itself; Settings > Agents on the Platform shows its version." -ForegroundColor Green
        } else {
            Write-Host "Already on the released versions; nothing to upgrade." -ForegroundColor Green
        }
        Write-Host "   docker compose logs -f agent   shows the agent starting."
        $script:InstallExit = 0
        return
    }

    Write-Host ""
    Write-Host "Done (mode: $Mode). Start the agent:" -ForegroundColor Green
    Write-Host "   cd `"$RepoRoot`""
    Write-Host "   docker compose up -d"
    Write-Host ""
    switch ($Mode) {
        "localhost" { Write-Host "   Agent will be reachable at: https://$HostName - from a browser on this machine only." }
        { $_ -in "custom", "ip" } { Write-Host "   Reachable at: https://$HostName once the agent applies its certificate." }
        "managed" { Write-Host "   Migratrix will assign a subdomain + certificate after the agent connects." }
    }
    if ($firewallNote) { Write-Host "   $firewallNote" }
    Write-Host ""
    Write-Host "   Then check that the agent connected - a wrong key or an unreachable orchestrator is said there, in words:"
    Write-Host "   docker compose logs -f agent"
    Write-Host "   and on the Platform: Settings > Agents shows the agent as Connected."
    Write-Host ""
    Write-Host "   The agent stays on the versions installed now. To move it to a newer release, run the install command"
    Write-Host "   again with -Upgrade in place of its other options."
    $script:InstallExit = 0
}

# Runs this script again as Administrator, waits for it, shows what it wrote and returns its exit code. The key
# and the registry token travel in a file only this user and Administrators can read, never on the command line
# (onboarding trials SEC-06); the elevated run deletes it. The elevated window closes when it ends, so its output
# is written to a log that is shown here (AGI-04: the first window used to report success whatever happened).
function Invoke-Elevated([string]$User) {
    $id = [guid]::NewGuid().ToString('N')
    $secrets = Join-Path $env:TEMP "migratrix-install-$id.json"
    $log = Join-Path $env:TEMP "migratrix-install-$id.log"
    New-Item -ItemType File -Path $secrets -Force | Out-Null
    Protect-File $secrets $User
    @{ ApiKey = $ApiKey; GithubToken = $GithubToken } | ConvertTo-Json | Set-Content -Path $secrets -Encoding UTF8

    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode `"$Mode`" -GithubUser `"$GithubUser`"" +
               " -SecretsFile `"$secrets`" -LogFile `"$log`" -InstallUser `"$User`""
    if ($HostName)        { $argLine += " -HostName `"$HostName`"" }
    if ($OrchestratorUrl) { $argLine += " -OrchestratorUrl `"$OrchestratorUrl`"" }
    if ($NoPull)          { $argLine += " -NoPull" }
    if ($NoFirewall)      { $argLine += " -NoFirewall" }

    Write-Host "The installer needs Administrator rights: approve the Windows prompt. Waiting for the elevated run..."
    try {
        $process = Start-Process powershell -ArgumentList $argLine -Verb RunAs -Wait -PassThru
    } catch {
        Remove-Item -Force -ErrorAction SilentlyContinue $secrets, $log
        throw "The installer was not run: the request for Administrator rights was declined or failed ($($_.Exception.Message)). Nothing was installed."
    }

    if (Test-Path $log) {
        Get-Content $log | ForEach-Object { Write-Host $_ }
        Remove-Item -Force -ErrorAction SilentlyContinue $log
    } else {
        Write-Warning "The elevated run left no output."
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $secrets

    return [int]$process.ExitCode
}

# --- run ---------------------------------------------------------------------
if ($LogFile) {
    # The elevated run: what the installer says also goes to the log that the first window shows. (No stream
    # redirection: with $ErrorActionPreference = 'Stop' a redirected stderr line of docker would end the run.)
    function Write-Host {
        param([Parameter(Position = 0)]$Object, $ForegroundColor)
        Add-Content -Path $LogFile -Value "$Object"
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    }
    function Write-Warning {
        param([Parameter(Position = 0)][string]$Message)
        Add-Content -Path $LogFile -Value "WARNING: $Message"
        Microsoft.PowerShell.Utility\Write-Warning $Message
    }
}

$script:InstallExit = 1
try {
    # Out-Host: what mkcert, choco and docker print is shown as it comes, not collected as the function's result.
    Install-Migratrix | Out-Host
} catch {
    $message = "ERROR: $($_.Exception.Message)"
    if ($LogFile) { Add-Content -Path $LogFile -Value $message }
    Microsoft.PowerShell.Utility\Write-Host $message -ForegroundColor Red
    $script:InstallExit = 1
} finally {
    if ($SecretsFile) { Remove-Item -Force -ErrorAction SilentlyContinue $SecretsFile }
}
exit $script:InstallExit
