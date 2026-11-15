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

  Outgoing proxy: -Proxy, or HTTPS_PROXY / HTTP_PROXY / NO_PROXY of the environment the installer runs in, are
  written to .env (MIGRATRIX_HTTPS_PROXY, MIGRATRIX_HTTP_PROXY, MIGRATRIX_NO_PROXY) and given to the containers
  that call out (the agent and the Risk Assessment API). The names of the other containers are always added to
  the no-proxy list. Image pulls are made by Docker, which has its own proxy setting. "-Proxy none" removes it.

  A proxy that inspects TLS: -CaFile <PEM> (or MIGRATRIX_EXTRA_CA_FILE) adds the proxy's CA to what the agent
  and the Risk Assessment API trust (certs\extra-ca.pem, joined with the image's own CA list in
  certs\ca-bundle.pem). "-CaFile none" removes it.

  A second agent on a key whose agent is connected is refused and keeps trying: stop the other agent, or run
  the installer again with -Replace, or regenerate the key in Settings > Agents. -Replace makes this
  installation take over from the one that is connected, once (MIGRATRIX_AGENT_REPLACE in .env).

  Exit codes: 0 done; 1 an error (the message says which); 3 the files are prepared but Docker is not installed
  or not running, so nothing was pulled or started (with -Upgrade: .env names the new versions and the containers
  still run the old ones); 4 a port the agent publishes is already in use on this machine (nothing was written).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1 -Mode custom -HostName agent.acme.com
  powershell -ExecutionPolicy Bypass -File migratrix-install.ps1 -Upgrade
#>
# The options (read at the end of this file, before the install starts; see Read-InstallerOptions):
#   -Mode <localhost|managed|custom|ip>
#   -HostName <name>
#   -ApiKey <key>            the agent key from Settings > Agents. Left out: MIGRATRIX_API_KEY, or a hidden prompt.
#   -OrchestratorUrl <url>   the orchestrator the agent connects to (default: Migratrix SaaS)
#   -GithubToken <token>     registry read token, when Migratrix gave you one; without it: anonymous pulls
#   -GithubUser <user>       default migratrix-bot
#   -NoPull                  do not pull the images now
#   -NoFirewall              do not add the Windows Firewall rule for the HTTPS port (modes managed / custom / ip)
#   -Upgrade                 an installed agent: the released versions; key, mode and host are kept
#   -Proxy <url|none>        the outgoing proxy, e.g. http://proxy.example.com:3128. Left out: HTTPS_PROXY /
#                            HTTP_PROXY / NO_PROXY of the environment, or what .env already holds.
#   -NoProxy <list>          hosts reached without the proxy, comma separated
#   -CaFile <pem|none>       the CA of a proxy that inspects TLS. Left out: MIGRATRIX_EXTRA_CA_FILE.
#   -HttpsPort <port>  -AgentPort <port>   the host ports (HTTPS_PORT, 443 by default; AGENT_PORT, 4002)
#   -Replace                 take over, once, from another installation that is connected with the same key
# Internal (the elevated run): -SecretsFile, -LogFile, -InstallUser.
$script:InstallerTokens = $args
# Set from the tokens by Read-Options, below; the names the rest of the script uses.
$Mode = ""; $HostName = ""; $ApiKey = ""; $OrchestratorUrl = ""; $GithubToken = ""; $GithubUser = "migratrix-bot"
$NoPull = $false; $NoFirewall = $false; $Upgrade = $false; $Replace = $false
$Proxy = ""; $NoProxy = ""; $CaFile = ""; $HttpsPort = 0; $AgentPort = 0
$SecretsFile = ""; $LogFile = ""; $InstallUser = ""

# The options are read here, not by a param() block: PowerShell answers a wrong option name, a missing value or a
# port that is not a number itself, before the script runs, with a raw error record ("A parameter cannot be found
# that matches parameter name ...", with a script position). Read here, each of them ends as one line "ERROR: ..."
# with the list of options (INST-2). Names are matched whole, in any letter case; "-Name value" and "-Name:value".
function Read-InstallerOptions([object[]]$Tokens, [string[]]$ValueNames, [string[]]$SwitchNames, [string[]]$Shown) {
    $options = @{}
    $given = @{}
    foreach ($n in $ValueNames) { $options[$n] = '' }
    foreach ($n in $SwitchNames) { $options[$n] = $false }
    $all = @($ValueNames) + @($SwitchNames)
    $hint = "Options: " + ((@($Shown) | ForEach-Object { "-$_" }) -join ', ') + ". Nothing was installed."
    $i = 0
    $count = @($Tokens).Count
    while ($i -lt $count) {
        $token = [string]$Tokens[$i]; $i++
        if ($token -notmatch '^-([A-Za-z]+)(:(.*))?$') {
            throw "Unexpected argument '$token': every option is a dash and a name, then its value. $hint"
        }
        $name = $Matches[1]; $hasInline = [bool]$Matches[2]; $inline = [string]$Matches[3]
        $known = $all | Where-Object { $_ -ieq $name } | Select-Object -First 1
        if (-not $known) { throw "Unknown option -$name. $hint" }
        $given[$known] = $true
        if ($SwitchNames -contains $known) {
            $value = 'true'
            if ($hasInline) {
                if ($inline -ne '') { $value = $inline }
                elseif ($i -lt $count) { $value = [string]$Tokens[$i]; $i++ }
            }
            $options[$known] = ($value -notmatch '^(false|0|\$false)$')
            continue
        }
        if ($hasInline -and $inline -ne '') { $options[$known] = $inline; continue }
        $next = $null
        if ($i -lt $count) { $next = $Tokens[$i] }
        $nextIsOption = ($next -is [string]) -and ($next -match '^-([A-Za-z]+):?$') -and [bool]($all | Where-Object { $_ -ieq $Matches[1] })
        if ($null -eq $next -or $nextIsOption) { throw "Option -$known needs a value. $hint" }
        # An unquoted list (a,b) arrives as an array: it is one comma separated value.
        $options[$known] = if ($next -is [array]) { $next -join ',' } else { [string]$next }
        $i++
    }
    $options['Given'] = $given
    return $options
}

# A port option: empty (not given) is 0; anything else must be a number from 1 to 65535.
function ConvertTo-Port([string]$Option, [string]$Value) {
    if ($Value -eq '') { return 0 }
    if ($Value -notmatch '^[0-9]{1,5}$' -or [int]$Value -lt 1 -or [int]$Value -gt 65535) {
        throw "$Option '$Value' is not a port (a number from 1 to 65535). Nothing was installed."
    }
    return [int]$Value
}

function Read-Options {
    $valueNames  = @('Mode', 'HostName', 'ApiKey', 'OrchestratorUrl', 'GithubToken', 'GithubUser', 'Proxy', 'NoProxy', 'CaFile', 'HttpsPort', 'AgentPort')
    $switchNames = @('NoPull', 'NoFirewall', 'Upgrade', 'Replace')
    $internal    = @('SecretsFile', 'LogFile', 'InstallUser')
    $read = Read-InstallerOptions $script:InstallerTokens ($valueNames + $internal) $switchNames ($valueNames + $switchNames)
    foreach ($name in @('Mode', 'HostName', 'ApiKey', 'OrchestratorUrl', 'GithubToken', 'Proxy', 'NoProxy', 'CaFile', 'SecretsFile', 'LogFile', 'InstallUser') + $switchNames) {
        Set-Variable -Scope Script -Name $name -Value $read[$name]
    }
    if ($read.GithubUser) { $script:GithubUser = $read.GithubUser }
    $script:NoProxyGiven = $read.Given.ContainsKey('NoProxy')
    $script:HttpsPort = ConvertTo-Port '-HttpsPort' $read.HttpsPort
    $script:AgentPort = ConvertTo-Port '-AgentPort' $read.AgentPort
    if ($Mode -and @('localhost', 'managed', 'custom', 'ip') -notcontains $Mode) {
        throw "-Mode '$Mode' is not a mode. Use localhost, managed, custom or ip. Nothing was installed."
    }
}

$ErrorActionPreference = 'Stop'
$script:NoProxyGiven = $false
$script:ProxyResolved = $false
$script:HttpsProxyValue = ""
$script:HttpProxyValue = ""
$script:NoProxyValue = ""
# The exit code of a failure that is not the general 1 (4: a published port is in use).
$script:FailExit = 0

# A proxy URL without its user name and password, for messages.
function Hide-Credentials([string]$Url) { return ($Url -replace '(://)[^/@]*@', '$1***@') }

function Assert-ProxyUrl([string]$What, [string]$Value) {
    if (-not $Value) { return }
    if ($Value -notmatch '^https?://') { throw "$What must be a URL that starts with http:// or https:// (for example http://proxy.example.com:3128)" }
    if ($Value -match '[\s$''"`]') { throw "$What holds a space, a quote or a `$ sign; write such characters of the user name or password percent-encoded (%24 for `$)" }
}

# Whether Docker answers. Through cmd: with $ErrorActionPreference = 'Stop', PowerShell 5 turns a redirected
# stderr line of a native command into a terminating error.
function Test-DockerUp {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    cmd /c "docker info >nul 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Test-PortInUse([int]$Port) {
    try {
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        }
    } catch { }
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return [bool]($listeners | Where-Object { $_.Port -eq $Port })
    } catch { return $false }
}

# Best effort: who holds a port.
function Get-PortHolder([int]$Port, [bool]$DockerUp) {
    if ($DockerUp) {
        $name = cmd /c "docker ps --filter publish=$Port --format {{.Names}} 2>nul" | Select-Object -First 1
        if ($name) { return "the Docker container $name" }
    }
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc) { return "$($proc.ProcessName) (pid $($proc.Id))" }
        }
    } catch { }
    return ""
}

# The folder of ANOTHER installation that a running migratrix-traefik belongs to, read from the container's labels
# (key=value, comma separated, as "docker ps --format {{.Labels}}" prints them); empty when the container is this
# folder's, or does not say. Folders are compared as Windows compares them: full path, any letter case.
function Get-OtherInstallDir([string]$Labels, [string]$RepoRoot) {
    if ($Labels -notmatch '(^|,)com\.docker\.compose\.project\.working_dir=([^,]+)') { return "" }
    $theirs = $Matches[2].Trim()
    try {
        $a = [System.IO.Path]::GetFullPath($theirs).TrimEnd('\', '/')
        $b = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    } catch { return "" }
    if ($a -ieq $b) { return "" }
    return $theirs
}

# S-1-5-32-544 = Administrators, S-1-5-18 = SYSTEM (names differ per Windows language, the ids do not).
function Protect-File([string]$Path, [string]$User) {
    $grants = @('*S-1-5-32-544:F', '*S-1-5-18:F')
    if ($User) { $grants = @("${User}:F") + $grants }
    & icacls $Path /inheritance:r /grant:r @grants | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not restrict access to $Path (icacls exit $LASTEXITCODE)" }
}

# The last value of a key in a KEY=value file; empty when the file or the key is not there.
# KEY=value files are read and written as UTF-8 without a byte-order mark: Windows PowerShell 5 reads with the
# machine's code page by default and "-Encoding ascii" turned every non-ASCII character of .env.example's comments
# into "?" (and a mark at the start of .env would become part of the first key for docker compose).
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Read-Lines([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    return @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).ProviderPath, $script:Utf8NoBom))
}
function Write-Lines([string]$Path, [string[]]$Lines) {
    $full = if (Test-Path $Path) { (Resolve-Path -LiteralPath $Path).ProviderPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    [System.IO.File]::WriteAllLines($full, [string[]]@($Lines), $script:Utf8NoBom)
}

function Get-FileValue([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return "" }
    $line = Read-Lines $Path | Where-Object { $_ -match "^$Key=" } | Select-Object -Last 1
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
        # The proxy was worked out by the first run: the elevated one does not have its environment, and a proxy
        # URL may hold a password, so it does not travel on the command line.
        if ($handed.ProxyResolved) {
            $script:ProxyResolved   = $true
            $script:HttpsProxyValue = [string]$handed.HttpsProxy
            $script:HttpProxyValue  = [string]$handed.HttpProxy
            $script:NoProxyValue    = [string]$handed.NoProxy
        }
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
        # A session that cannot prompt (-NonInteractive, a scheduled task) falls through to the sentence below,
        # not to PowerShell's own "Read and Prompt functionality is not available".
        $secure = $null
        try { $secure = Read-Host -AsSecureString "Migratrix agent API key (Settings > Agents in the Platform; input is hidden)" } catch { }
        if ($secure) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $script:ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
    }
    if (-not $ApiKey) { throw "No agent API key: pass -ApiKey <key>, or set MIGRATRIX_API_KEY (the key is in Settings > Agents in the Platform). Nothing was installed." }

    # Placeholders copied from an example are refused before anything is installed or written.
    if ($ApiKey -match 'xxxx' -or $ApiKey -match '^<.*>$' -or $ApiKey -eq 'mgx_xxx') {
        throw "The API key is a placeholder; copy the real key from Settings > Agents in the Platform"
    }
    if ($GithubToken -match 'xxxx' -or $GithubToken -match '^<.*>$') {
        throw "-GithubToken is a placeholder; leave it out to pull anonymously, or pass the token Migratrix gave you"
    }

    # --- outgoing proxy ----------------------------------------------------------
    # The option, then the environment the installer runs in, then what an earlier run wrote to .env.
    if (-not $ProxyResolved) {
        if ($Proxy -eq 'none') {
            # no proxy: also drops what .env held
        } elseif ($Proxy) {
            $script:HttpsProxyValue = $Proxy; $script:HttpProxyValue = $Proxy
        } else {
            $script:HttpsProxyValue = [string]$env:HTTPS_PROXY
            $script:HttpProxyValue  = [string]$env:HTTP_PROXY
            if (-not $HttpsProxyValue -and -not $HttpProxyValue) {
                $script:HttpsProxyValue = Get-FileValue $EnvFile 'MIGRATRIX_HTTPS_PROXY'
                $script:HttpProxyValue  = Get-FileValue $EnvFile 'MIGRATRIX_HTTP_PROXY'
            }
        }
        Assert-ProxyUrl "The HTTPS proxy" $HttpsProxyValue
        Assert-ProxyUrl "The HTTP proxy" $HttpProxyValue
        if ($HttpsProxyValue -or $HttpProxyValue) {
            $list = if ($NoProxyGiven) { $NoProxy } elseif ($env:NO_PROXY) { [string]$env:NO_PROXY } else { Get-FileValue $EnvFile 'MIGRATRIX_NO_PROXY' }
            $list = $list -replace '[\s$''"`]', ''
            # The other containers are reached by name, never through the proxy.
            $names = @()
            foreach ($name in (@($list -split ',') + @('localhost', '127.0.0.1', 'risk-assessment', 'sqlglot', 'java-analyzer', 'python-analyzer', 'host.docker.internal'))) {
                if ($name -and ($names -notcontains $name)) { $names += $name }
            }
            $script:NoProxyValue = $names -join ','
        }
        $script:ProxyResolved = $true
    }

    # --- extra CA (a proxy that inspects TLS) ------------------------------------
    if (-not $CaFile -and $env:MIGRATRIX_EXTRA_CA_FILE) { $script:CaFile = $env:MIGRATRIX_EXTRA_CA_FILE }
    if ($CaFile -and $CaFile -ne 'none') {
        if (-not (Test-Path -PathType Leaf $CaFile)) { throw "-CaFile: $CaFile does not exist" }
        $script:CaFile = (Resolve-Path $CaFile).Path
        if (-not (Select-String -Path $CaFile -SimpleMatch '-----BEGIN CERTIFICATE-----' -Quiet)) {
            throw "-CaFile: $CaFile is not a PEM certificate file (no '-----BEGIN CERTIFICATE-----' line). A .cer / .der file can be converted with: certutil -encode <file> ca.pem"
        }
    }

    # --- the published ports must be free ----------------------------------------
    # Checked before anything is written. A port held by this installation's own proxy container is fine.
    $httpsPortValue = if ($HttpsPort) { "$HttpsPort" } else { Get-FileValue $EnvFile 'HTTPS_PORT' }
    if ($httpsPortValue -notmatch '^\d+$') { $httpsPortValue = '443' }
    $agentPortValue = if ($AgentPort) { "$AgentPort" } else { Get-FileValue $EnvFile 'AGENT_PORT' }
    if ($agentPortValue -notmatch '^\d+$') { $agentPortValue = '4002' }
    if ($httpsPortValue -eq $agentPortValue) { throw "HTTPS_PORT and AGENT_PORT are both $httpsPortValue; they must differ" }
    $dockerUp = Test-DockerUp
    # "Own" is the container Docker Compose started from THIS folder: a running migratrix-traefik of another
    # installation folder holds its ports against this one (INST-3; the check used to exempt any container of that
    # name). A container that does not say which folder it belongs to is taken as this installation's, as before.
    $ownPorts = ""
    $otherInstallDir = ""
    if ($dockerUp) {
        $labels = [string](cmd /c "docker ps --filter name=migratrix-traefik --format {{.Labels}} 2>nul" | Select-Object -First 1)
        $otherInstallDir = Get-OtherInstallDir $labels $RepoRoot
        if (-not $otherInstallDir) { $ownPorts = [string](cmd /c "docker ps --filter name=migratrix-traefik --format {{.Ports}} 2>nul") }
    }
    $taken = @()
    foreach ($check in @(@('HTTPS_PORT', $httpsPortValue, '-HttpsPort'), @('AGENT_PORT', $agentPortValue, '-AgentPort'))) {
        $key = $check[0]; $port = $check[1]; $option = $check[2]
        if ($ownPorts -match (":" + $port + "->")) { continue }
        if (Test-PortInUse ([int]$port)) {
            $holder = Get-PortHolder ([int]$port) $dockerUp
            $by = if ($holder) { " by $holder" } else { "" }
            $line = "Port $port on this machine is already in use$by. The agent's proxy publishes it ($key). Free the port, or choose another one: run the installer again with $option <port> (it writes $key to $EnvFile)."
            if ($key -eq 'HTTPS_PORT') { $line += " With another HTTPS port the agent's address carries it: https://<host>:<port>." }
            $taken += $line
        }
    }
    if ($taken.Count -gt 0) {
        if ($otherInstallDir) {
            $taken += "Another Migratrix installation on this machine is running, from $otherInstallDir. To work on that one, run the installer there (set MIGRATRIX_DIR to that folder). To replace it with this one, stop it first: run 'docker compose down' in that folder."
        }
        $script:FailExit = 4
        throw (($taken -join " ") + " Nothing was installed or started.")
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
  # Also the default certificate: a client that connects by address sends no server name (N-R2A-1).
  stores:
    default:
      defaultCertificate:
        certFile: /certs/live-bootstrap.pem
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
        $lines = @(Read-Lines $EnvFile | Where-Object { $_ -notmatch "^$Key=" })
        $lines += "$Key=$Value"
        Write-Lines $EnvFile $lines
    }
    function Remove-EnvVar([string]$Key) {
        $lines = @(Read-Lines $EnvFile | Where-Object { $_ -notmatch "^$Key=" })
        Write-Lines $EnvFile $lines
    }
    Set-EnvVar 'MIGRATRIX_MODE' $Mode
    if ($HttpsPort) { Set-EnvVar 'HTTPS_PORT' "$HttpsPort" }
    if ($AgentPort) { Set-EnvVar 'AGENT_PORT' "$AgentPort" }
    # The outgoing proxy of the agent and the Risk Assessment API. Under their own names: docker compose prefers
    # the shell's variables to .env, and a NO_PROXY of the shell would drop the container names added here.
    $proxyNote = ""
    if ($HttpsProxyValue -or $HttpProxyValue) {
        if ($HttpsProxyValue) { Set-EnvVar 'MIGRATRIX_HTTPS_PROXY' $HttpsProxyValue } else { Remove-EnvVar 'MIGRATRIX_HTTPS_PROXY' }
        if ($HttpProxyValue)  { Set-EnvVar 'MIGRATRIX_HTTP_PROXY' $HttpProxyValue }   else { Remove-EnvVar 'MIGRATRIX_HTTP_PROXY' }
        Set-EnvVar 'MIGRATRIX_NO_PROXY' $NoProxyValue
        $proxyNote = Hide-Credentials $(if ($HttpsProxyValue) { $HttpsProxyValue } else { $HttpProxyValue })
        Write-Host "Outgoing proxy for the agent and the Risk Assessment API: $proxyNote"
        Write-Host "   not through the proxy: $NoProxyValue"
        Write-Host "   Image pulls are made by Docker, which does not read this: if the pull below cannot reach the registry,"
        Write-Host "   give Docker the proxy (Docker Desktop: Settings > Resources > Proxies)."
    } else {
        Remove-EnvVar 'MIGRATRIX_HTTPS_PROXY'; Remove-EnvVar 'MIGRATRIX_HTTP_PROXY'; Remove-EnvVar 'MIGRATRIX_NO_PROXY'
    }
    # The extra CA: kept as certs\extra-ca.pem; the list the containers read is built after the images are here.
    $ExtraCa  = Join-Path $CertsDir 'extra-ca.pem'
    $CaBundle = Join-Path $CertsDir 'ca-bundle.pem'
    if ($CaFile -eq 'none') {
        Remove-Item -Force -ErrorAction SilentlyContinue $ExtraCa, $CaBundle
        Remove-EnvVar 'MIGRATRIX_SSL_CERT_FILE'
        Write-Host "Extra CA removed: the containers trust their own CA list only."
    } elseif ($CaFile) {
        if ($CaFile -ne $ExtraCa) { Copy-Item $CaFile $ExtraCa -Force }
        Write-Host "Extra CA copied to $ExtraCa"
    }
    # Take over from another installation on the same key: only for the start that asked for it.
    if ($Replace) {
        Set-EnvVar 'MIGRATRIX_AGENT_REPLACE' ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        Write-Host "-Replace: this agent takes over from the installation that is connected with the same key (once)."
    } else {
        Remove-EnvVar 'MIGRATRIX_AGENT_REPLACE'
    }
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
    # An install made by the installer of before fixed versions has one line for all five images, TAG=latest.
    # Nothing reads it any more: it is removed, and the summary says what the images ran on ("was latest").
    $legacyTag = Get-FileValue $EnvFile 'TAG'
    if (Read-Lines $EnvFile | Where-Object { $_ -match '^TAG=' }) { Remove-EnvVar 'TAG' }
    foreach ($key in $imageKeys) {
        $new = $released[$key]
        $old = Get-FileValue $EnvFile $key
        if (-not $old) { $old = $legacyTag }
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
    $HttpsPort = (Read-Lines $EnvFile | Where-Object { $_ -match '^HTTPS_PORT=\d+' } | Select-Object -Last 1) -replace '^HTTPS_PORT=', ''
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
    $RegistryPrefix = (Read-Lines $EnvFile | Where-Object { $_ -match '^REGISTRY=' } | Select-Object -Last 1) -replace '^REGISTRY=', ''
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
    $dockerDown = $false
    if (-not $NoPull) {
        if (-not $dockerUp -and $Upgrade) {
            # Exit code 3, as for an install: prepared, not started (the table in the header).
            Write-Host ""
            Write-Host "Prepared, NOT upgraded: Docker is not installed or not running, so the new images were not pulled and the containers still run the versions they had." -ForegroundColor Yellow
            Write-Host "   .env already names the new versions: start Docker and run 'docker compose pull' and 'docker compose up -d' in $RepoRoot."
            $script:InstallExit = 3
            return
        }
        if (-not $dockerUp) {
            $dockerDown = $true
            Write-Host "Docker is not installed or not running: no image was pulled."
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

    # --- extra CA: the list the containers read -------------------------------------
    # SSL_CERT_FILE replaces the image's CA list, it does not add to it: the file given to the containers is the
    # image's own list followed by the extra CA. Rebuilt on every run (a new image may carry a newer list).
    $caNote = ""
    if (Test-Path $ExtraCa) {
        $agentImage = "${RegistryPrefix}migratrix-agent:" + (Get-FileValue $EnvFile 'AGENT_TAG')
        $tmpBundle = Join-Path $env:TEMP ("migratrix-ca-" + [guid]::NewGuid().ToString('N') + ".pem")
        $built = $false
        if ($dockerUp) {
            cmd /c "docker image inspect $agentImage >nul 2>&1"
            if ($LASTEXITCODE -eq 0) {
                # cmd writes the bytes as they are; PowerShell 5 would re-encode the redirected text.
                cmd /c "docker run --rm --network none --entrypoint cat $agentImage /etc/ssl/certs/ca-certificates.crt > `"$tmpBundle`" 2>nul"
                if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpBundle) -and (Select-String -Path $tmpBundle -SimpleMatch '-----BEGIN CERTIFICATE-----' -Quiet)) {
                    $out = [IO.File]::Create($CaBundle)
                    try {
                        foreach ($part in @($tmpBundle, $ExtraCa)) {
                            $bytes = [IO.File]::ReadAllBytes($part)
                            $out.Write($bytes, 0, $bytes.Length)
                            $out.WriteByte(10)
                        }
                    } finally { $out.Dispose() }
                    Set-EnvVar 'MIGRATRIX_SSL_CERT_FILE' '/certs/ca-bundle.pem'
                    $built = $true
                    Write-Host "Extra CA: the agent and the Risk Assessment API trust $ExtraCa in addition to their own CA list ($CaBundle)"
                }
            }
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $tmpBundle
        if (-not $built) {
            if ((Test-Path $CaBundle) -and (Get-FileValue $EnvFile 'MIGRATRIX_SSL_CERT_FILE') -and -not $CaFile) {
                Write-Host "Extra CA: the CA list built by an earlier run is kept ($CaBundle)"
            } else {
                $caNote = "The extra CA is saved ($ExtraCa) but NOT in use yet: the CA list is built from the agent image, which is not on this machine. Run the installer again, with Docker running and without -NoPull."
                Write-Warning $caNote
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
            Write-Host "Nothing was removed. The containers of this installation now:"
            Push-Location $RepoRoot
            try { cmd /c "docker compose ps --all 2>nul" | ForEach-Object { Write-Host "   $_" } } finally { Pop-Location }
            throw "The new images were pulled but the containers could not be restarted; see the message above. Run 'docker compose up -d' in $RepoRoot once it is solved ('docker compose down' there stops the containers that are running)."
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
    if ($dockerDown) {
        # Not the green "Done", and not exit 0: nothing was pulled and nothing runs (onboarding trials ERR-05).
        Write-Host "Prepared, NOT started (mode: $Mode): Docker is not installed or not running on this machine." -ForegroundColor Yellow
        Write-Host "   The settings are in $EnvFile, but no image was pulled and no container runs."
        Write-Host "   Start Docker Desktop (or install it: https://docs.docker.com/get-docker/), then:"
        Write-Host "   cd `"$RepoRoot`""
        Write-Host "   docker compose pull"
        Write-Host "   docker compose up -d"
        if ($caNote) { Write-Host "   $caNote" }
        if ($firewallNote) { Write-Host "   $firewallNote" }
        Write-Host "   (To prepare the files on purpose without Docker, run the installer with -NoPull: it then ends with exit code 0.)"
        $script:InstallExit = 3
        return
    }
    if ($NoPull) {
        Write-Host "Prepared (mode: $Mode; -NoPull: no image was pulled, nothing was started). Start the agent:" -ForegroundColor Green
    } else {
        Write-Host "Done (mode: $Mode). Start the agent:" -ForegroundColor Green
    }
    Write-Host "   cd `"$RepoRoot`""
    Write-Host "   docker compose up -d"
    Write-Host ""
    if ($caNote) { Write-Host "   WARNING: $caNote" }
    if ($proxyNote) { Write-Host "   The agent reaches Migratrix through the proxy $proxyNote." }
    if ($Replace) { Write-Host "   This start takes over from the agent that is connected with the same key; that one then stops serving." }
    switch ($Mode) {
        "localhost" { Write-Host "   Agent will be reachable at: https://$HostName - from a browser on this machine only." }
        { $_ -in "custom", "ip" } {
            $reach = if ($httpsPortValue -eq '443') { "https://$HostName" } else { "https://${HostName}:$httpsPortValue" }
            Write-Host "   Reachable at: $reach once the agent applies its certificate."
        }
        "managed" { Write-Host "   Migratrix will assign a subdomain + certificate after the agent connects." }
    }
    if ($firewallNote) { Write-Host "   $firewallNote" }
    Write-Host ""
    Write-Host "   Then check that the agent connected - a wrong key or an unreachable orchestrator is said there, in words:"
    Write-Host "   docker compose logs -f agent"
    Write-Host "   and on the Platform: Settings > Agents shows the agent as Connected."
    Write-Host "   If the log says another agent is connected with this key: stop that agent, or run the installer again"
    Write-Host "   with -Replace, or regenerate the key in Settings > Agents."
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
    @{ ApiKey = $ApiKey; GithubToken = $GithubToken; ProxyResolved = $true; HttpsProxy = $HttpsProxyValue
       HttpProxy = $HttpProxyValue; NoProxy = $NoProxyValue } | ConvertTo-Json | Set-Content -Path $secrets -Encoding UTF8

    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode `"$Mode`" -GithubUser `"$GithubUser`"" +
               " -SecretsFile `"$secrets`" -LogFile `"$log`" -InstallUser `"$User`""
    if ($HostName)        { $argLine += " -HostName `"$HostName`"" }
    if ($OrchestratorUrl) { $argLine += " -OrchestratorUrl `"$OrchestratorUrl`"" }
    if ($NoPull)          { $argLine += " -NoPull" }
    if ($NoFirewall)      { $argLine += " -NoFirewall" }
    if ($CaFile)          { $argLine += " -CaFile `"$CaFile`"" }
    if ($HttpsPort)       { $argLine += " -HttpsPort $HttpsPort" }
    if ($AgentPort)       { $argLine += " -AgentPort $AgentPort" }
    if ($Replace)         { $argLine += " -Replace" }

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
try { Read-Options } catch {
    Microsoft.PowerShell.Utility\Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
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
    $script:InstallExit = if ($script:FailExit) { $script:FailExit } else { 1 }
} finally {
    if ($SecretsFile) { Remove-Item -Force -ErrorAction SilentlyContinue $SecretsFile }
}
exit $script:InstallExit
