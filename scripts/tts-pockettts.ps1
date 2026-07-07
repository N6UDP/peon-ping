<#
.SYNOPSIS
    pocket-tts (Kyutai) TTS backend for peon-ping. Speaks stdin text in a chosen
    voice via the `uvx pocket-tts` CLI. Fire-and-forget: always exits 0, errors
    go to stderr gated on PEON_DEBUG=1, matching the tts-native.ps1 contract.

.DESCRIPTION
    Invoked by peon.ps1's Invoke-TtsSpeak with decoded text on stdin and
    voice/rate/volume as named params.

    Modes (config.json -> tts.pockettts):
      - daemon = false (DEFAULT): synthesize with the `uvx pocket-tts generate`
        CLI. Simple and dependency-light; ~7s cold per line.
      - daemon = true: use a shared `serve` daemon for warm (~3s) synthesis. If
        the daemon is healthy its /tts endpoint is used. If it is down and
        auto_start is true, a detached, multi-session-safe start is kicked off
        (non-blocking) and the CURRENT line is spoken via the CLI so nothing is
        lost while the daemon warms up. Subsequent lines use the warm daemon.

    Config keys (all optional):
      tts.pockettts.daemon      bool   default false
      tts.pockettts.port        int    default 8123 (env PEON_PTTS_PORT wins)
      tts.pockettts.auto_start  bool   default true (only when daemon = true)

    Voice resolution (first match wins):
      1. -Voice param if it points at an existing .wav/.safetensors file
         (set tts.voice in config to your cloned voice).
      2. Bundled ../voices/peon-voice.safetensors or peon-ref.wav if present.
      3. pocket-tts built-in default voice.

    Rate is not supported by pocket-tts and is ignored. Volume is applied at
    playback via win-play.ps1.
#>
param(
    [Parameter(ValueFromPipeline = $true)]
    [string]$InputText,
    [string]$Voice = "default",
    [double]$Rate = 1.0,
    [double]$Vol = 0.5
)

begin {
    $script:Debug = ($env:PEON_DEBUG -eq "1")
    function Dbg([string]$m) { if ($script:Debug) { [Console]::Error.WriteLine("[tts-pockettts] $m") } }
    $script:Buffer = New-Object System.Text.StringBuilder

    # The serve daemon streams WAV with placeholder RIFF/data chunk sizes
    # (e.g. 2,000,000,000). System.Media.SoundPlayer reads those bogus sizes and
    # plays nothing, so rewrite them to the real byte counts before playback.
    function Repair-WavHeader([string]$Path) {
        try {
            $b = [System.IO.File]::ReadAllBytes($Path)
            if ($b.Length -lt 44) { return }
            if ([System.Text.Encoding]::ASCII.GetString($b, 0, 4) -ne "RIFF") { return }
            $pos = 12
            while ($pos -lt $b.Length - 8) {
                $id = [System.Text.Encoding]::ASCII.GetString($b, $pos, 4)
                $sz = [BitConverter]::ToUInt32($b, $pos + 4)
                if ($id -eq "data") {
                    $realData = $b.Length - $pos - 8
                    if ($sz -ne $realData) {
                        [BitConverter]::GetBytes([uint32]$realData).CopyTo($b, $pos + 4)
                        [BitConverter]::GetBytes([uint32]($b.Length - 8)).CopyTo($b, 4)
                        [System.IO.File]::WriteAllBytes($Path, $b)
                        Dbg "repaired wav header: data $sz -> $realData"
                    }
                    return
                }
                if ($sz -eq 0 -or $sz -gt $b.Length) { return }
                $pos += 8 + $sz + ($sz % 2)
            }
        } catch { Dbg "wav header repair failed: $_" }
    }
}

process {
    if ($null -ne $InputText -and $InputText.Length -gt 0) { [void]$script:Buffer.AppendLine($InputText) }
}

end {
    $text = $script:Buffer.ToString().TrimEnd()
    if (-not $text) {
        try { if ([Console]::IsInputRedirected) { $text = ([Console]::In.ReadToEnd()).TrimEnd() } } catch { Dbg "stdin read failed: $_" }
    }
    if (-not $text) { Dbg "empty input"; exit 0 }

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $installDir = Split-Path -Parent $scriptDir
    $voicesDir = Join-Path $installDir "voices"

    # --- Config (tts.pockettts) ---
    $daemon = $false
    $autoStart = $true
    $port = if ($env:PEON_PTTS_PORT) { $env:PEON_PTTS_PORT } else { "8123" }
    $cfgPath = Join-Path $installDir "config.json"
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $pt = $cfg.tts.pockettts
            if ($pt) {
                if ($null -ne $pt.daemon) { $daemon = [bool]$pt.daemon }
                if ($null -ne $pt.auto_start) { $autoStart = [bool]$pt.auto_start }
                if ((-not $env:PEON_PTTS_PORT) -and $pt.port) { $port = [string]$pt.port }
            }
        } catch { Dbg "config read failed: $_" }
    }

    # --- Voice resolution ---
    $voiceWav = $null       # reference wav for serve upload / CLI
    $voiceCli = $null       # safetensors or wav for CLI --voice
    if ($Voice -and $Voice -ne "default" -and (Test-Path $Voice)) {
        if ($Voice -match '\.safetensors$') { $voiceCli = $Voice; $voiceWav = $null }
        else { $voiceWav = $Voice; $voiceCli = $Voice }
    } else {
        $bundledSt = Join-Path $voicesDir "peon-voice.safetensors"
        $bundledRef = Join-Path $voicesDir "peon-ref.wav"
        if (Test-Path $bundledSt) { $voiceCli = $bundledSt }
        if (Test-Path $bundledRef) { $voiceWav = $bundledRef; if (-not $voiceCli) { $voiceCli = $bundledRef } }
    }

    $outWav = Join-Path ([System.IO.Path]::GetTempPath()) ("peon-tts-" + [guid]::NewGuid().ToString("N") + ".wav")
    $produced = $false

    # --- Warm path: serve daemon (only when enabled) ---
    if ($daemon) {
        $healthy = $false
        try {
            $h = Invoke-WebRequest -Uri "http://localhost:$port/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            $healthy = ($h.StatusCode -eq 200)
        } catch { $healthy = $false }

        if ($healthy) {
            Dbg "serve up on :$port, POST /tts"
            try {
                if ($voiceWav) {
                    & curl.exe -s -X POST "http://localhost:$port/tts" -F "text=$text" -F "voice_wav=@$voiceWav" -o $outWav
                } else {
                    & curl.exe -s -X POST "http://localhost:$port/tts" -F "text=$text" -o $outWav
                }
                if ((Test-Path $outWav) -and (Get-Item $outWav).Length -gt 44) { Repair-WavHeader $outWav; $produced = $true }
                else { Dbg "serve produced no audio" }
            } catch { Dbg "serve request failed: $_" }
        } elseif ($autoStart) {
            # Non-blocking, multi-session-safe start; the serve helper handles the
            # health check + lockfile so only one session actually launches it.
            $serveHelper = Join-Path $scriptDir "pockettts-serve.ps1"
            if (Test-Path $serveHelper) {
                Dbg "serve down on :$port; kicking detached start, using CLI for this line"
                try {
                    Start-Process -FilePath "powershell.exe" `
                        -ArgumentList "-NoProfile", "-NonInteractive", "-File", "`"$serveHelper`"", "start" `
                        -WindowStyle Hidden | Out-Null
                } catch { Dbg "detached serve start failed: $_" }
            }
        }
    }

    # --- Default / fallback path: uvx CLI ---
    if (-not $produced) {
        try {
            $uvx = (Get-Command uvx -ErrorAction SilentlyContinue)
            if (-not $uvx) { Dbg "uvx not found; cannot synthesize"; exit 0 }
            $cliArgs = @("pocket-tts", "generate", "--text", $text, "--output-path", $outWav, "-q")
            if ($voiceCli) { $cliArgs += @("--voice", $voiceCli) }
            Dbg "CLI: uvx $($cliArgs -join ' ')"
            & $uvx.Source @cliArgs 2>$null
            if ((Test-Path $outWav) -and (Get-Item $outWav).Length -gt 44) { $produced = $true }
        } catch { Dbg "CLI synthesis failed: $_" }
    }

    if (-not $produced) { Dbg "no audio produced"; exit 0 }

    # --- Playback via win-play.ps1 (SoundPlayer/ffplay) ---
    try {
        $winPlay = Join-Path $scriptDir "win-play.ps1"
        if (Test-Path $winPlay) {
            & powershell -NoProfile -NonInteractive -File $winPlay -path $outWav -vol $Vol 2>$null
        } else {
            (New-Object System.Media.SoundPlayer $outWav).PlaySync()
        }
    } catch { Dbg "playback failed: $_" }
    finally { Remove-Item $outWav -Force -ErrorAction SilentlyContinue }

    exit 0
}
