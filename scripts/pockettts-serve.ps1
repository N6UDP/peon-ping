<#
.SYNOPSIS
    Manage the optional pocket-tts "serve" daemon used by tts-pockettts.ps1 for
    warm (~3s) synthesis. Without the daemon the backend uses the ~7s uvx CLI.

.DESCRIPTION
    One shared daemon per port serves every agent session on the machine. Start
    is multi-session safe: a health check short-circuits when it's already up,
    and a lockfile serialises the start window so concurrent sessions never spawn
    duplicate daemons.

    Port resolution: PEON_PTTS_PORT env, else config.json tts.pockettts.port,
    else 8123.

.EXAMPLE
    .\pockettts-serve.ps1 start
    .\pockettts-serve.ps1 status
    .\pockettts-serve.ps1 stop
#>
param([ValidateSet("start", "stop", "status", "restart")][string]$Action = "status")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = Split-Path -Parent $scriptDir

function Get-Port {
    if ($env:PEON_PTTS_PORT) { return [string]$env:PEON_PTTS_PORT }
    $cfgPath = Join-Path $installDir "config.json"
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            if ($cfg.tts.pockettts.port) { return [string]$cfg.tts.pockettts.port }
        } catch { }
    }
    return "8123"
}

$port = Get-Port
$base = "http://localhost:$port"
$tmp = [System.IO.Path]::GetTempPath()
$pidFile = Join-Path $tmp "pockettts-serve-$port.pid"
$lockFile = Join-Path $tmp "pockettts-serve-$port.lock"

function Test-Up {
    try { return ((Invoke-WebRequest "$base/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) }
    catch { return $false }
}

function Wait-Up([int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-Up) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Start-Daemon {
    if (Test-Up) { Write-Host "pocket-tts serve already up on :$port"; return }

    # Serialise the start window across sessions with an atomic lockfile.
    # Steal a stale lock (>90s) left by a crashed starter.
    if (Test-Path $lockFile) {
        try {
            $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
            if ($age.TotalSeconds -gt 90) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    $lock = $null
    try {
        $lock = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch {
        # Another session owns the start; just wait for it to come up.
        Write-Host "Another session is starting pocket-tts serve; waiting..."
        if (Wait-Up 60) { Write-Host "pocket-tts serve up on :$port" }
        else { Write-Warning "pocket-tts serve not ready after 60s" }
        return
    }

    try {
        if (Test-Up) { Write-Host "pocket-tts serve already up on :$port"; return }
        $uvx = Get-Command uvx -ErrorAction SilentlyContinue
        if (-not $uvx) { Write-Error "uvx not found on PATH"; return }
        $p = Start-Process -FilePath $uvx.Source `
            -ArgumentList @("pocket-tts", "serve", "--port", $port) `
            -WindowStyle Hidden -PassThru
        $p.Id | Set-Content $pidFile
        Write-Host "Starting pocket-tts serve on :$port (pid $($p.Id)); loading model..."
        if (Wait-Up 90) { Write-Host "Ready on :$port" }
        else { Write-Warning "Daemon started (pid $($p.Id)) but /health not ready after 90s" }
    } finally {
        if ($lock) { $lock.Close() }
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Daemon {
    $stopped = $false
    if (Test-Path $pidFile) {
        $dpid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($dpid) {
            try { Stop-Process -Id $dpid -Force -ErrorAction SilentlyContinue; $stopped = $true } catch { }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    if ($stopped) { Write-Host "Stopped pocket-tts serve on :$port" }
    else { Write-Host "No tracked pocket-tts serve pid for :$port" }
}

switch ($Action) {
    "start"   { Start-Daemon }
    "stop"    { Stop-Daemon }
    "restart" { Stop-Daemon; Start-Sleep 1; Start-Daemon }
    "status"  {
        if (Test-Up) { Write-Host "pocket-tts serve: UP on :$port" }
        else { Write-Host "pocket-tts serve: DOWN on :$port (backend uses ~7s CLI)" }
    }
}
