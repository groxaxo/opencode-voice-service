<#
.SYNOPSIS
    Windows voice conversation orchestrator for OpenCode Voice Service.

.DESCRIPTION
    Equivalent of talk.sh for Windows. Drives VAD → Parakeet STT → Supertonic TTS
    in a pipelined voice conversation loop. All inference is local/CPU-only.

.PARAMETER Command
    listen  — record one utterance, transcribe, print text
    speak   — TTS synthesis + auto-listen
    status  — health check all backends
    devices — list audio input devices
    loop    — continuous conversation loop

.EXAMPLE
    .\talk.ps1 listen
    .\talk.ps1 speak "Hello, how can I help?"
    .\talk.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("listen","record","hear","speak","say","tts","status","health","devices","mic","loop")]
    [string]$Command = "listen",

    [Parameter(Position=1, ValueFromRemainingArguments)]
    [string[]]$Args = @()
)

$ServiceDir = $PSScriptRoot

# ── Config ───────────────────────────────────────────────────────────────────
$ConfigDir      = "$env:USERPROFILE\.config\opencode"
$VenvPython     = if ($env:PYTHON) { $env:PYTHON } else { "$ConfigDir\tts-venv\Scripts\python.exe" }
$VadPy          = "$ServiceDir\vad_recorder.py"
$TtsSh          = if ($env:TTS_SH) { $env:TTS_SH } else { "$ConfigDir\tts.sh" }

$TtsEngine      = if ($env:TTS_ENGINE)      { $env:TTS_ENGINE }      else { "supertonic" }
$XaiTtsVoice    = if ($env:XAI_TTS_VOICE)   { $env:XAI_TTS_VOICE }   else { "rex" }
$SttUrl         = if ($env:STT_URL)         { $env:STT_URL }         else { "http://127.0.0.1:5093/v1/audio/transcriptions" }
$SttModel       = if ($env:STT_MODEL)       { $env:STT_MODEL }       else { "parakeet-tdt-0.6b-v3" }
$SupertonicUrl  = if ($env:SUPERTONIC_URL)  { $env:SUPERTONIC_URL }  else { "http://127.0.0.1:8766" }
$MicQuery       = if ($env:MIC_QUERY)       { $env:MIC_QUERY }       else { "" }
$VadThreshold   = if ($env:VAD_THRESHOLD)   { $env:VAD_THRESHOLD }   else { "0.5" }
$MinSilenceMs   = if ($env:VAD_MIN_SILENCE_MS) { $env:VAD_MIN_SILENCE_MS } else { "500" }
$AutoListen     = if ($env:TALK_AUTO_LISTEN)    { $env:TALK_AUTO_LISTEN }    else { "1" }
$BargeIn        = if ($env:TALK_BARGE_IN)       { $env:TALK_BARGE_IN }       else { "0" }
$IdleTimeoutS   = if ($env:TALK_IDLE_TIMEOUT_S) { $env:TALK_IDLE_TIMEOUT_S } else { "30" }
$ReadyCue       = if ($env:TALK_READY_CUE)      { $env:TALK_READY_CUE }      else { "1" }
$ReadyDelayMs   = if ($env:TALK_READY_DELAY_MS) { $env:TALK_READY_DELAY_MS } else { "700" }

# ── Audio playback (cross-platform WAV player) ─────────────────────────────
function Play-Wav {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    # Try ffplay first (best cross-platform option)
    if (Get-Command ffplay -ErrorAction SilentlyContinue) {
        & ffplay -nodisp -autoexit -loglevel quiet $Path 2>$null
        return
    }
    # Windows built-in SoundPlayer (WAV only, synchronous)
    try {
        Add-Type -AssemblyName System.Media
        $player = New-Object System.Media.SoundPlayer $Path
        $player.PlaySync()
    } catch {
        Write-Host "[talk] Audio playback failed: $_" -ForegroundColor Yellow
    }
}

function Play-ReadyCue {
    if ($ReadyCue -eq "0") { return }
    # Windows system sound (beep)
    [Console]::Beep(880, 120)
}

# ── Transcribe WAV file via Parakeet STT ──────────────────────────────────
function Invoke-Transcribe {
    param([string]$File)

    $tmpResponse = [System.IO.Path]::GetTempFileName() + ".json"
    try {
        $httpCode = & curl.exe -sS -m 45 `
            -o $tmpResponse `
            -w '%{http_code}' `
            $SttUrl `
            -F "file=@$File" `
            -F "model=$SttModel" 2>$null

        if (-not $httpCode -or $httpCode -lt 200 -or $httpCode -ge 300) {
            Write-Host "[talk] STT HTTP $httpCode" -ForegroundColor Yellow
            return $null
        }

        $json = Get-Content $tmpResponse -Raw | ConvertFrom-Json
        return $json.text
    } catch {
        Write-Host "[talk] STT error: $_" -ForegroundColor Yellow
        return $null
    } finally {
        Remove-Item $tmpResponse -Force -ErrorAction SilentlyContinue
    }
}

# ── VAD listen ────────────────────────────────────────────────────────────
function Invoke-Listen {
    $tmpVadOut = [System.IO.Path]::GetTempFileName() + ".json"
    $outWav    = [System.IO.Path]::GetTempFileName() + ".wav"

    # Build VAD args
    $vadArgs = @(
        $VadPy, "--oneshot",
        "--output-file", $outWav,
        "--vad-threshold", $VadThreshold,
        "--min-silence-ms", $MinSilenceMs,
        "--ready-delay-ms", $ReadyDelayMs,
        "--idle-timeout-s", $IdleTimeoutS
    )
    if ($MicQuery) { $vadArgs += @("--mic-query", $MicQuery) }

    # Start VAD, play ready cue
    $vadJob = Start-Process -FilePath $VenvPython -ArgumentList $vadArgs `
        -RedirectStandardOutput $tmpVadOut `
        -RedirectStandardError ([System.IO.Path]::GetTempFileName()) `
        -PassThru -NoNewWindow

    Play-ReadyCue

    $vadJob.WaitForExit()

    # Parse speech_end event
    $wavFile = $null
    if (Test-Path $tmpVadOut) {
        Get-Content $tmpVadOut | ForEach-Object {
            try {
                $evt = $_ | ConvertFrom-Json
                if ($evt.event -eq "speech_end") { $wavFile = $evt.file }
            } catch {}
        }
    }
    Remove-Item $tmpVadOut -Force -ErrorAction SilentlyContinue

    if (-not $wavFile -or -not (Test-Path $wavFile)) { return "" }

    $text = Invoke-Transcribe $wavFile
    Remove-Item $wavFile -Force -ErrorAction SilentlyContinue
    return $text
}

# ── TTS speak via supertonic / xai ────────────────────────────────────────
function Invoke-TTS {
    param([string]$Text, [string]$Lang = "en")

    $outputWav = [System.IO.Path]::GetTempFileName() + ".wav"

    if ($TtsEngine -eq "supertonic" -or $TtsEngine -eq "coreml-tts") {
        $body = (@{ text = $Text; language = $Lang } | ConvertTo-Json -Compress)
        $httpCode = & curl.exe -sS -m 60 `
            -o $outputWav -w '%{http_code}' `
            "$SupertonicUrl/v1/audio/speech" `
            -H "Content-Type: application/json" `
            -d $body 2>$null
        if ($httpCode -ge 200 -and $httpCode -lt 300 -and (Test-Path $outputWav) -and (Get-Item $outputWav).Length -gt 0) {
            Play-Wav $outputWav
            Remove-Item $outputWav -Force -ErrorAction SilentlyContinue
            return $true
        }
        Write-Host "[tts] Supertonic failed (HTTP $httpCode), trying xAI..." -ForegroundColor Yellow
    }

    if ($env:XAI_API_KEY) {
        $body = (@{ text = $Text; voice_id = $XaiTtsVoice; language = $Lang } | ConvertTo-Json -Compress)
        $httpCode = & curl.exe -sS -m 60 `
            -o $outputWav -w '%{http_code}' `
            "https://api.x.ai/v1/tts" `
            -H "Authorization: Bearer $($env:XAI_API_KEY)" `
            -H "Content-Type: application/json" `
            -d $body 2>$null
        if ($httpCode -ge 200 -and $httpCode -lt 300 -and (Test-Path $outputWav) -and (Get-Item $outputWav).Length -gt 0) {
            Play-Wav $outputWav
            Remove-Item $outputWav -Force -ErrorAction SilentlyContinue
            return $true
        }
        Write-Host "[tts] xAI failed (HTTP $httpCode)" -ForegroundColor Yellow
    }

    Remove-Item $outputWav -Force -ErrorAction SilentlyContinue
    Write-Host "[tts] All TTS engines failed" -ForegroundColor Red
    return $false
}

# ── Commands ─────────────────────────────────────────────────────────────
function Cmd-Listen {
    $text = Invoke-Listen
    if ($text) { Write-Output $text }
}

function Cmd-Speak {
    $text = if ($Args.Count -gt 0) { $Args[0] } else { "" }
    if (-not $text) { Write-Host "[talk] No text provided" -ForegroundColor Yellow; return }

    $lang = if ($Args.Count -gt 1) { $Args[1] } else { "en" }

    Invoke-TTS $text $lang | Out-Null

    if ($AutoListen -eq "1") {
        Write-Host "Listening for your reply..." -ForegroundColor Cyan
        $next = Invoke-Listen
        if ($next) { Write-Output $next }
    }
}

function Cmd-Status {
    Write-Host "=== Audio Devices ===" -ForegroundColor Cyan
    & $VenvPython $VadPy --list-devices 2>&1

    Write-Host ""
    Write-Host "=== Parakeet STT (:5093) ===" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:5093/health" -TimeoutSec 2 -ErrorAction Stop
        Write-Host "  RUNNING — $($resp.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "  NOT RUNNING" -ForegroundColor Red
        Write-Host "  Start: Start-ScheduledTask 'OpenCode-Parakeet-STT'"
    }

    Write-Host ""
    Write-Host "=== Supertonic TTS (:$($SupertonicUrl.Split(':')[-1])) ===" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri "$SupertonicUrl/health" -TimeoutSec 2 -ErrorAction Stop
        Write-Host "  RUNNING — $($resp.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "  NOT RUNNING" -ForegroundColor Red
        Write-Host "  Start: Start-ScheduledTask 'OpenCode-Supertonic'"
    }

    Write-Host ""
    Write-Host "=== Python Environment ===" -ForegroundColor Cyan
    Write-Host "  Interpreter: $VenvPython"
    Write-Host "  VAD: $VadPy"
    Write-Host "  TTS engine: $TtsEngine"
    Write-Host "  Auto-listen: $AutoListen"
}

function Cmd-Devices {
    Write-Host "=== Audio Input Devices ===" -ForegroundColor Cyan
    & $VenvPython $VadPy --list-devices 2>&1
}

function Cmd-Loop {
    Write-Host "Talk loop — Ctrl+C to stop" -ForegroundColor Cyan
    while ($true) {
        $text = Invoke-Listen
        if ($text) {
            Write-Host "User: $text" -ForegroundColor White
            Write-Host -NoNewline "Response: " -ForegroundColor Gray
            $response = Read-Host
            if ($response) {
                $env:TALK_AUTO_LISTEN = "1"
                Invoke-TTS $response "en" | Out-Null
            }
        }
    }
}

# ── Dispatch ─────────────────────────────────────────────────────────────
switch ($Command) {
    { $_ -in "listen","record","hear" } { Cmd-Listen }
    { $_ -in "speak","say","tts" }      { Cmd-Speak }
    { $_ -in "status","health" }        { Cmd-Status }
    { $_ -in "devices","mic" }          { Cmd-Devices }
    "loop"                              { Cmd-Loop }
}
