#Requires -Version 5
<#
.SYNOPSIS
  Migratrix bootstrap (Windows) — PUBLIC one-liner entrypoint.

.DESCRIPTION
  Downloads the compose file, the .env template, the released image versions and
  the real installer into a working directory, then hands off to the installer. The installer pulls the
  container images (ghcr.io): anonymously, or with -GithubToken when Migratrix gave
  you a registry token.

.EXAMPLE
  # Because args must pass through iex, create a scriptblock from the download:
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) -ApiKey <key from Settings - Agents>
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) -Mode custom -HostName agent.acme.com
  # Without -ApiKey the installer asks for the key and does not echo it.
  # An installed agent: move it to the released versions, keeping its key and settings.
  & ([scriptblock]::Create((irm https://get.migratrix.com/install.ps1))) -Upgrade

.NOTES
  Overridable via env: MIGRATRIX_BASE_URL, MIGRATRIX_DIR
  The downloaded files are checked against SHA256SUMS from the same place: a truncated or mixed-up download
  stops the install. (Same origin, so this is an integrity check of the transfer, not a signature.)
  Exit codes (run as a file): 1 when the bootstrap itself stops (download, checksum, a wrong option), with one
  line "ERROR: ..."; otherwise the installer's: 0 done, 1 an error, 3 prepared but Docker is not running,
  4 a published port is in use.
#>
# The options (read below, see Read-InstallerOptions):
#   -Mode <localhost|managed|custom|ip>   left out: localhost on a desktop Windows; Windows Server has no default
#   -HostName <name>                      the name or address the agent is reached on (modes custom, ip)
#   -ApiKey <key>                         left out: MIGRATRIX_API_KEY, or the installer asks without echoing
#   -OrchestratorUrl <url>  -GithubToken <token>  -GithubUser <user>
#   -NoPull  -NoFirewall
#   -Upgrade                              an installed agent: the released versions; key, mode and host are kept
#   -Proxy <url|none>  -NoProxy <list>    the outgoing proxy (also of the downloads below); left out: HTTPS_PROXY
#   -CaFile <pem|none>                    the CA of a proxy that inspects TLS
#   -HttpsPort <port>  -AgentPort <port>
#   -Replace                              take over, once, from another installation connected with the same key
$bootstrapTokens = $args

$ErrorActionPreference = 'Stop'

# Everything the bootstrap itself refuses ends the same way as the installer's refusals: one line "ERROR: ..." and
# exit code 1, not PowerShell's error record with a script position ("At ...install.ps1:79 char:9 + throw ...").
try {
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

function Assert-ProxyUrl([string]$What, [string]$Value) {
    if (-not $Value) { return }
    if ($Value -notmatch '^https?://') { throw "$What must be a URL that starts with http:// or https:// (for example http://proxy.example.com:3128). Nothing was installed." }
    if ($Value -match '[\s$''"`]') { throw "$What holds a space, a quote or a `$ sign; write such characters of the user name or password percent-encoded (%24 for `$). Nothing was installed." }
}

$valueNames  = @('Mode', 'HostName', 'ApiKey', 'OrchestratorUrl', 'GithubToken', 'GithubUser', 'Proxy', 'NoProxy', 'CaFile', 'HttpsPort', 'AgentPort')
$switchNames = @('NoPull', 'NoFirewall', 'Upgrade', 'Replace')
$read = Read-InstallerOptions $bootstrapTokens $valueNames $switchNames ($valueNames + $switchNames)
$Mode = $read.Mode; $HostName = $read.HostName; $ApiKey = $read.ApiKey; $OrchestratorUrl = $read.OrchestratorUrl
$GithubToken = $read.GithubToken; $GithubUser = if ($read.GithubUser) { $read.GithubUser } else { 'migratrix-bot' }
$Proxy = $read.Proxy; $NoProxy = $read.NoProxy; $CaFile = $read.CaFile
$NoPull = $read.NoPull; $NoFirewall = $read.NoFirewall; $Upgrade = $read.Upgrade; $Replace = $read.Replace
$noProxyGiven = $read.Given.ContainsKey('NoProxy')
$HttpsPort = ConvertTo-Port '-HttpsPort' $read.HttpsPort
$AgentPort = ConvertTo-Port '-AgentPort' $read.AgentPort
if ($Mode -and @('localhost', 'managed', 'custom', 'ip') -notcontains $Mode) {
    throw "-Mode '$Mode' is not a mode. Use localhost, managed, custom or ip. Nothing was installed."
}
# The proxy is checked before anything is downloaded through it, with the installer's own rule (INST-4): a value
# without http:// used to be ignored here without a word, and refused by the installer only after the downloads.
if ($Proxy -and $Proxy -ne 'none') { Assert-ProxyUrl "-Proxy" $Proxy }
elseif (-not $Proxy) {
    Assert-ProxyUrl "The HTTPS proxy of the environment (HTTPS_PROXY)" ([string]$env:HTTPS_PROXY)
    Assert-ProxyUrl "The HTTP proxy of the environment (HTTP_PROXY)" ([string]$env:HTTP_PROXY)
}

$Base    = if ($env:MIGRATRIX_BASE_URL) { $env:MIGRATRIX_BASE_URL } else { "https://get.migratrix.com" }
$WorkDir = if ($env:MIGRATRIX_DIR)      { $env:MIGRATRIX_DIR }      else { Join-Path $HOME 'migratrix' }

Write-Host "Migratrix bootstrap"
Write-Host "  source:      $Base"
Write-Host "  working dir: $WorkDir"

# A relative -CaFile is relative to where the command was run, not to the working directory entered below.
if ($CaFile -and $CaFile -ne 'none') {
    if (-not (Test-Path -PathType Leaf $CaFile)) { throw "-CaFile: $CaFile does not exist. Nothing was installed." }
    $CaFile = (Resolve-Path $CaFile).Path
}

# Behind an outgoing proxy: Windows PowerShell 5 does not read HTTPS_PROXY by itself, so the downloads are given
# the proxy (-Proxy, or HTTPS_PROXY of the environment). Without one, the system's proxy setting applies as usual.
$webArgs = @{}
$fetchProxy = if ($Proxy -and $Proxy -ne 'none') { $Proxy } elseif (-not $Proxy -and $env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { "" }
if ($fetchProxy -match '^https?://') {
    $proxyUri = [Uri]$fetchProxy
    $webArgs['Proxy'] = $proxyUri.GetLeftPart([UriPartial]::Authority) -replace '(://)[^/@]*@', '$1'
    if ($proxyUri.UserInfo) {
        $userInfo = $proxyUri.UserInfo -split ':', 2
        $proxyPassword = if ($userInfo.Count -gt 1) { [Uri]::UnescapeDataString($userInfo[1]) } else { "" }
        if ($proxyPassword) {
            $webArgs['ProxyCredential'] = New-Object System.Management.Automation.PSCredential(
                [Uri]::UnescapeDataString($userInfo[0]), (ConvertTo-SecureString $proxyPassword -AsPlainText -Force))
        }
    }
    Write-Host "  proxy:       $($webArgs['Proxy'])"
}

# Everything is downloaded into a fresh temporary folder and checked THERE. Only files that passed the check
# are moved into the working directory: a failed download or a wrong checksum leaves the working directory (and
# an existing installation's compose file) exactly as it was, so "Nothing was installed" is true (N-R2A-6).
$Stage = Join-Path $env:TEMP ("migratrix-bootstrap-" + [guid]::NewGuid().ToString('N'))
$staged = @('docker-compose.yml', '.env.example', 'versions.env', 'scripts\migratrix-install.ps1')
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $Stage 'scripts') | Out-Null

    function Fetch($name, $dest) {
        try {
            Invoke-WebRequest -UseBasicParsing "$Base/$name" -OutFile (Join-Path $Stage $dest) @webArgs
        } catch {
            throw "Could not download $Base/$name ($($_.Exception.Message)). Nothing was installed."
        }
        Write-Host "  fetched $name"
    }
    Fetch 'docker-compose.yml'    'docker-compose.yml'
    Fetch '.env.example'          '.env.example'
    Fetch 'versions.env'          'versions.env'
    Fetch 'migratrix-install.ps1' 'scripts\migratrix-install.ps1'

    # --- integrity: every fetched file must match the published checksum ----------
    $sumsFile = Join-Path $Stage 'SHA256SUMS'
    try {
        Invoke-WebRequest -UseBasicParsing "$Base/SHA256SUMS" -OutFile $sumsFile @webArgs
    } catch {
        throw "Could not download $Base/SHA256SUMS; the downloaded files cannot be checked. Nothing was installed."
    }
    $sums = @{}
    Get-Content $sumsFile | ForEach-Object {
        $parts = $_ -split '\s+', 2
        if ($parts.Count -eq 2) { $sums[$parts[1].TrimStart('*').Trim()] = $parts[0].ToLowerInvariant() }
    }
    function Verify($name, $path) {
        $got = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $Stage $path)).Hash.ToLowerInvariant()
        if (-not $sums.ContainsKey($name) -or $sums[$name] -ne $got) {
            throw "$name does not match its published checksum (download damaged or changed). Nothing was installed."
        }
    }
    Verify 'docker-compose.yml'    'docker-compose.yml'
    Verify '.env.example'          '.env.example'
    Verify 'versions.env'          'versions.env'
    Verify 'migratrix-install.ps1' 'scripts\migratrix-install.ps1'
    Write-Host "  checksums ok"

    # --- checked: now, and only now, into the working directory -------------------
    New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'scripts') | Out-Null
    foreach ($file in $staged) {
        Move-Item -Force -Path (Join-Path $Stage $file) -Destination (Join-Path $WorkDir $file)
    }
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Stage
}
Set-Location $WorkDir
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    # Run as a file: exit code 1. Run as the documented one-liner, "exit" would close the person's window.
    if ($PSCommandPath) { exit 1 }
    $global:LASTEXITCODE = 1
    return
}

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
if ($Upgrade)         { $installArgs += '-Upgrade' }
if ($Proxy -eq 'none') { $installArgs += @('-Proxy', 'none') }
if ($noProxyGiven -and $NoProxy) { $installArgs += @('-NoProxy', $NoProxy) }
if ($CaFile -and $CaFile -ne 'none') { $installArgs += @('-CaFile', $CaFile) }
elseif ($CaFile)      { $installArgs += @('-CaFile', 'none') }
if ($HttpsPort)       { $installArgs += @('-HttpsPort', "$HttpsPort") }
if ($AgentPort)       { $installArgs += @('-AgentPort', "$AgentPort") }
if ($Replace)         { $installArgs += '-Replace' }
$hadKey = $env:MIGRATRIX_API_KEY
$hadToken = $env:MIGRATRIX_GITHUB_TOKEN
$hadHttpsProxy = $env:HTTPS_PROXY
$hadHttpProxy = $env:HTTP_PROXY
try {
    if ($ApiKey)      { $env:MIGRATRIX_API_KEY = $ApiKey }
    if ($GithubToken) { $env:MIGRATRIX_GITHUB_TOKEN = $GithubToken }
    # A proxy URL may hold a password: like the key, it goes in the environment, not on the command line.
    if ($Proxy -and $Proxy -ne 'none') { $env:HTTPS_PROXY = $Proxy; $env:HTTP_PROXY = $Proxy }
    & powershell @installArgs
    $code = $LASTEXITCODE
} finally {
    $env:MIGRATRIX_API_KEY = $hadKey
    $env:MIGRATRIX_GITHUB_TOKEN = $hadToken
    $env:HTTPS_PROXY = $hadHttpsProxy
    $env:HTTP_PROXY = $hadHttpProxy
}
# Run as a file: the exit code is the installer's. Run as the documented one-liner (a script block in the user's
# own PowerShell window), "exit" would close that window with the installer's messages in it.
if ($PSCommandPath) { exit $code }
$global:LASTEXITCODE = $code
# One closing line per exit code (the table in the header). 3 is not a failure: the files are prepared and Docker
# is not running (INST-1: it used to read "The Migratrix installer failed (exit code 3)").
switch ($code) {
    0 { }
    3 { Write-Host "The files are prepared, but nothing was started: Docker is not installed or not running (exit code 3). The steps are in the messages above." -ForegroundColor Yellow }
    4 { Write-Host "Nothing was installed: a port the agent publishes is in use on this machine (exit code 4). See the messages above." -ForegroundColor Red }
    default { Write-Host "The Migratrix installer failed (exit code $code). See the messages above." -ForegroundColor Red }
}
