#Requires -Version 5.1
<#
.SYNOPSIS
    Windows installer for OpenCode Voice Service.

.DESCRIPTION
    One-command setup for the complete voice stack on Windows:
      1. Python venv with Silero VAD, sounddevice, ONNX Runtime
      2. Parakeet STT Backend  — ONNX-based ASR on :5093 (CPU-only)
      3. Supertonic TTS Backend — ONNX-based TTS on :8766 (CPU-only)
      4. Windows Task Scheduler auto-start for both services
      5. Skill install for Claude Code, OpenCode, OpenClaw, Hermes, Codex

.PARAMETER SkipParakeet
    Skip Parakeet STT installation.

.PARAMETER SkipSupertonic
    Skip Supertonic TTS installation.

.PARAMETER SkipVoices
    Skip reference voice generation.

.PARAMETER VenvOnly
    Only create the Python venv, skip backends.

.PARAMETER Force
    Overwrite existing Task Scheduler tasks (DESTRUCTIVE).

.PARAMETER Uninstall
    Remove Task Scheduler tasks and optionally all installed dirs.

.PARAMETER Integrations
    Comma-separated list of agent integrations to install:
    claudecode,opencode,openclaw,hermes,codex
    Default: prompt interactively if terminal is present.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -SkipSupertonic
    .\setup.ps1 -Force
    .\setup.ps1 -Uninstall -Force
#>

[CmdletBinding()]
param(
    [switch]$SkipParakeet,
    [switch]$SkipSupertonic,
    [switch]$SkipVoices,
    [switch]$VenvOnly,
    [switch]$Force,
    [switch]$Uninstall,
    [string]$Integrations = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoDir     = $PSScriptRoot
$ConfigDir   = "$env:USERPROFILE\.config\opencode"
$SkillDir    = "$ConfigDir\skills\talk"
$VenvDir     = "$ConfigDir\tts-venv"
$Python      = "$VenvDir\Scripts\python.exe"

$ParakeetDir  = "$ConfigDir\parakeet-stt"
$ParakeetVenv = "$ParakeetDir\.venv"
$ParakeetPort = if ($env:PARAKEET_PORT) { $env:PARAKEET_PORT } else { "5093" }

$SupertonicDir  = "$ConfigDir\supertonic-tts"
$SupertonicVenv = "$SupertonicDir\.venv"
$SupertonicPort = if ($env:SUPERTONIC_PORT) { $env:SUPERTONIC_PORT } else { "8766" }

# ── Colour helpers ─────────────────────────────────────────────────────────────
function info  { param($m) Write-Host "[setup] $m" -ForegroundColor Cyan }
function ok    { param($m) Write-Host "[setup] $([char]0x2713) $m" -ForegroundColor Green }
function warn  { param($m) Write-Host "[setup] $m" -ForegroundColor Yellow }
function err   { param($m) Write-Host "[setup] $m" -ForegroundColor Red }

# ── Dependency check ───────────────────────────────────────────────────────────
function Assert-Command {
    param([string]$Name, [string]$Install = "")
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        err "$Name not found."
        if ($Install) { warn "Install with: $Install" }
        exit 1
    }
}

Assert-Command "git"    "winget install --id Git.Git"
Assert-Command "python" "winget install --id Python.Python.3.12"

# Check Python version
$pyVersion = & python --version 2>&1 | Select-String "(\d+)\.(\d+)" | ForEach-Object { $_.Matches[0].Value }
info "Python: $pyVersion"

# ── Interactive component selection ───────────────────────────────────────────
$InstallParakeet   = -not $SkipParakeet
$InstallSupertonic = -not $SkipSupertonic

# Agent integration targets
$AgentTargets = @{
    "claudecode" = "$env:USERPROFILE\.claude\skills\talk"
    "opencode"   = "$ConfigDir\skills\talk"
    "openclaw"   = "$env:USERPROFILE\.openclaw\skills\talk"
    "hermes"     = "$env:USERPROFILE\.hermes\skills\talk"
    "codex"      = "$env:USERPROFILE\.codex\skills\talk"
}

$SelectedIntegrations = @{}

if ($Integrations -ne "") {
    foreach ($k in $Integrations -split ',') {
        $k = $k.Trim().ToLower()
        if ($AgentTargets.ContainsKey($k)) { $SelectedIntegrations[$k] = $AgentTargets[$k] }
    }
} elseif ([Environment]::UserInteractive -and -not $VenvOnly) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║      OpenCode Voice Service — Windows Setup          ║" -ForegroundColor Cyan
    Write-Host "  ║   100% CPU-only · No GPU Required · Local ONNX       ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Components:" -ForegroundColor White
    Write-Host "    [1] Silero VAD + voice venv  (always installed)"  -ForegroundColor Gray

    $choice = Read-Host "  Install Parakeet STT on :$ParakeetPort? [Y/n]"
    $InstallParakeet = ($choice -eq "" -or $choice -match '^[Yy]')

    $choice = Read-Host "  Install Supertonic TTS on :$SupertonicPort? [Y/n]"
    $InstallSupertonic = ($choice -eq "" -or $choice -match '^[Yy]')

    Write-Host ""
    Write-Host "  Agent integrations (installs skill to each agent's skills/ dir):" -ForegroundColor White
    foreach ($key in $AgentTargets.Keys) {
        $path = $AgentTargets[$key]
        $choice = Read-Host "  Install for $key ($path)? [Y/n]"
        if ($choice -eq "" -or $choice -match '^[Yy]') {
            $SelectedIntegrations[$key] = $path
        }
    }
    Write-Host ""
} else {
    # Non-interactive: install all integrations
    $SelectedIntegrations = $AgentTargets.Clone()
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
if ($Uninstall) {
    info "── Uninstalling OpenCode Voice Service ──────────────────────"
    foreach ($label in @("OpenCode-Parakeet-STT", "OpenCode-Supertonic")) {
        $task = Get-ScheduledTask -TaskName $label -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskName $label -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $label -Confirm:$false
            ok "Task Scheduler: $label removed"
        }
    }
    if ($Force) {
        @($ParakeetDir, $SupertonicDir, $VenvDir, $SkillDir) | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Recurse -Force; ok "removed: $_" }
        }
    } else {
        warn "Directories kept (pass -Force to remove):"
        warn "  $ParakeetDir"
        warn "  $SupertonicDir"
        warn "  $VenvDir"
        warn "  $SkillDir"
    }
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Python venv (voice core — Silero VAD, sounddevice, ONNX)
# ══════════════════════════════════════════════════════════════════════════════
info "── Voice Core Venv ────────────────────────────────────────────"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

if (-not (Test-Path $VenvDir)) {
    info "Creating Python venv at $VenvDir..."
    & python -m venv $VenvDir
    ok "Venv created"
} else {
    info "Venv exists at $VenvDir"
}

info "Installing voice core Python dependencies..."
& "$VenvDir\Scripts\pip" install --quiet --upgrade pip setuptools wheel 2>$null
& "$VenvDir\Scripts\pip" install --quiet `
    silero-vad `
    sounddevice `
    onnxruntime `
    torch `
    torchaudio `
    numpy
ok "Voice core dependencies installed"

if ($VenvOnly) { ok "Venv-only setup complete"; exit 0 }

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Install Parakeet STT Backend (ONNX-based, :5093) — CPU-only
# ══════════════════════════════════════════════════════════════════════════════
function Install-Parakeet {
    if (-not $InstallParakeet) { info "Skipping Parakeet STT"; return }
    info "── Parakeet STT Backend (ONNX, CPU-only) ─────────────────────"

    if (Test-Path "$ParakeetDir\.git") {
        info "Parakeet repo exists, pulling..."
        & git -C $ParakeetDir pull --ff-only 2>&1 | ForEach-Object { "  $_" } | Write-Host
    } else {
        info "Cloning Parakeet STT repo..."
        Remove-Item $ParakeetDir -Recurse -Force -ErrorAction SilentlyContinue
        & git clone https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai $ParakeetDir 2>&1 | ForEach-Object { "  $_" } | Write-Host
    }

    if (-not (Test-Path $ParakeetVenv)) {
        info "Creating Parakeet venv..."
        & python -m venv $ParakeetVenv
        ok "Parakeet venv created"
    }

    info "Installing Parakeet dependencies (CPU ONNX)..."
    & "$ParakeetVenv\Scripts\pip" install --quiet --upgrade pip 2>$null

    # Windows: use onnxruntime (CPU), not onnxruntime-gpu
    $reqFile = "$ParakeetDir\requirements.txt"
    $reqWindows = "$ParakeetDir\requirements-windows.txt"
    if (Test-Path $reqFile) {
        (Get-Content $reqFile) -replace 'onnxruntime-gpu[^\r\n]*', 'onnxruntime' | Set-Content $reqWindows
    } else {
        Set-Content $reqWindows "onnxruntime`nnumpy`nfastapi`nuvicorn[standard]`npython-multipart"
    }
    & "$ParakeetVenv\Scripts\pip" install --quiet -r $reqWindows 2>$null
    & "$ParakeetVenv\Scripts\pip" install --quiet `
        "uvicorn[standard]" fastapi python-multipart silero-vad 2>$null

    ok "Parakeet dependencies installed (CPU ONNX)"

    # Register Task Scheduler task
    $taskName = "OpenCode-Parakeet-STT"
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        warn "Task '$taskName' already exists (pass -Force to overwrite)"
    } else {
        if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
        $action  = New-ScheduledTaskAction `
            -Execute "$ParakeetVenv\Scripts\python.exe" `
            -Argument "$ParakeetDir\server.py" `
            -WorkingDirectory $ParakeetDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit 0 `
            -RestartCount 99 `
            -RestartInterval (New-TimeSpan -Minutes 1)
        $env_vars = @{ PARAKEET_PORT = $ParakeetPort; PARAKEET_USE_GPU = "false"; HOME = $env:USERPROFILE }
        # Note: Task Scheduler doesn't natively support env vars per task; we wrap in a helper
        $wrapperScript = "$ParakeetDir\start-windows.ps1"
        Set-Content $wrapperScript @"
`$env:PARAKEET_PORT = '$ParakeetPort'
`$env:PARAKEET_USE_GPU = 'false'
`$env:HOME = `$env:USERPROFILE
`$logFile = '$ConfigDir\parakeet-stt.log'
& '$ParakeetVenv\Scripts\python.exe' '$ParakeetDir\server.py' *>> `$logFile
"@
        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-WindowStyle Hidden -NonInteractive -File `"$wrapperScript`"" `
            -WorkingDirectory $ParakeetDir
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Description "Parakeet ONNX STT Server (CPU-only) on port $ParakeetPort" `
            -Force | Out-Null
        ok "Task Scheduler: $taskName registered"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Install Supertonic TTS Backend (ONNX-based, :8766) — CPU-only
# ══════════════════════════════════════════════════════════════════════════════
function Install-Supertonic {
    if (-not $InstallSupertonic) { info "Skipping Supertonic TTS"; return }
    info "── Supertonic TTS Backend (ONNX, CPU-only) ──────────────────"

    if (Test-Path "$SupertonicDir\.git") {
        info "Supertonic repo exists, pulling..."
        & git -C $SupertonicDir pull --ff-only 2>&1 | ForEach-Object { "  $_" } | Write-Host
    } else {
        info "Cloning Supertonic Express repo..."
        Remove-Item $SupertonicDir -Recurse -Force -ErrorAction SilentlyContinue
        & git clone https://github.com/groxaxo/supertonic-express $SupertonicDir 2>&1 | ForEach-Object { "  $_" } | Write-Host
    }

    if (-not (Test-Path $SupertonicVenv)) {
        info "Creating Supertonic venv..."
        & python -m venv $SupertonicVenv
        ok "Supertonic venv created"
    }

    info "Installing Supertonic dependencies..."
    & "$SupertonicVenv\Scripts\pip" install --quiet --upgrade pip 2>$null
    $reqFile = "$SupertonicDir\py\requirements.txt"
    if (Test-Path $reqFile) {
        & "$SupertonicVenv\Scripts\pip" install --quiet -r $reqFile 2>$null
    }
    & "$SupertonicVenv\Scripts\pip" install --quiet huggingface-hub transformers 2>$null
    ok "Supertonic dependencies installed"

    # Download ONNX model
    $onnxDir = "$SupertonicDir\assets"
    if (-not (Test-Path "$onnxDir\model_q4.onnx") -and -not (Test-Path "$onnxDir\model.onnx")) {
        info "Downloading Supertonic ONNX model (~500MB, one-time)..."
        New-Item -ItemType Directory -Force -Path $onnxDir | Out-Null
        & "$SupertonicVenv\Scripts\python" -c @"
from huggingface_hub import snapshot_download
print('Downloading Supertonic-TTS-2-ONNX...')
snapshot_download('onnx-community/Supertonic-TTS-2-ONNX', local_dir=r'$onnxDir', ignore_patterns=['*.md','.gitattributes'])
print('Model download complete.')
"@
        ok "Supertonic ONNX model downloaded"
    } else {
        ok "Supertonic ONNX model already present"
    }

    # Register Task Scheduler task
    $taskName = "OpenCode-Supertonic"
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        warn "Task '$taskName' already exists (pass -Force to overwrite)"
    } else {
        if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
        $wrapperScript = "$SupertonicDir\start-windows.ps1"
        Set-Content $wrapperScript @"
`$env:ONNX_DIR = '$SupertonicDir\assets'
`$env:VOICE_STYLES_DIR = '$SupertonicDir\assets'
`$env:USE_GPU = 'false'
`$env:HOME = `$env:USERPROFILE
`$logFile = '$ConfigDir\supertonic.log'
Set-Location '$SupertonicDir\py'
& '$SupertonicVenv\Scripts\python.exe' -m uvicorn api.src.main:app ``
    --host 0.0.0.0 --port $SupertonicPort --app-dir '$SupertonicDir\py' ``
    *>> `$logFile
"@
        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-WindowStyle Hidden -NonInteractive -File `"$wrapperScript`"" `
            -WorkingDirectory "$SupertonicDir\py"
        $trigger  = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit 0 `
            -RestartCount 99 `
            -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Description "Supertonic ONNX TTS Server (CPU-only) on port $SupertonicPort" `
            -Force | Out-Null
        ok "Task Scheduler: $taskName registered"
    }
}

# Run backend installs (sequential on Windows to avoid pip contention)
Install-Parakeet
Install-Supertonic

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Install service files to skill directory
# ══════════════════════════════════════════════════════════════════════════════
info "── Installing service files ────────────────────────────────────"
New-Item -ItemType Directory -Force -Path $SkillDir | Out-Null

$serviceFiles = @(
    "service\vad_recorder.py",
    "service\talk.sh",
    "service\tts.sh",
    "service\tts_lang.sh",
    "windows\talk.ps1",
    "skill\SKILL.md"
)
foreach ($f in $serviceFiles) {
    $src = Join-Path $RepoDir $f
    $dst = Join-Path $SkillDir (Split-Path $f -Leaf)
    if (Test-Path $src) { Copy-Item $src $dst -Force }
}
ok "Service files installed to $SkillDir"

# Backward compat: tts files at config root
Copy-Item (Join-Path $RepoDir "service\tts.sh")      "$ConfigDir\tts.sh"       -Force
Copy-Item (Join-Path $RepoDir "service\tts_lang.sh") "$ConfigDir\tts_lang.sh"  -Force
Copy-Item (Join-Path $RepoDir "windows\talk.ps1")    "$ConfigDir\talk.ps1"     -Force -ErrorAction SilentlyContinue
ok "TTS CLI + lang helper installed to $ConfigDir"

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Install agent integrations
# ══════════════════════════════════════════════════════════════════════════════
if ($SelectedIntegrations.Count -gt 0) {
    info "── Agent Integrations ─────────────────────────────────────────"
    foreach ($key in $SelectedIntegrations.Keys) {
        $targetDir = $SelectedIntegrations[$key]
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Copy-Item "$SkillDir\*" $targetDir -Force -Recurse
        ok "$key  →  $targetDir"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Start services
# ══════════════════════════════════════════════════════════════════════════════
info "Starting services..."
foreach ($taskName in @("OpenCode-Parakeet-STT", "OpenCode-Supertonic")) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName $taskName
        ok "$taskName started"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ""
info "── Setup Complete ────────────────────────────────────────────"
Write-Host ""
Write-Host "  Voice skill:   $SkillDir\talk.ps1"
Write-Host "  VAD engine:    $SkillDir\vad_recorder.py"
Write-Host "  TTS CLI:       $ConfigDir\tts.sh"
Write-Host "  Voice venv:    $VenvDir"
Write-Host ""
Write-Host "  Backends (Task Scheduler auto-start on login):"
$pStat = if ((Get-ScheduledTask "OpenCode-Parakeet-STT"  -EA SilentlyContinue)) { "(c) registered" } else { "not registered" }
$sStat = if ((Get-ScheduledTask "OpenCode-Supertonic" -EA SilentlyContinue))    { "(c) registered" } else { "not registered" }
Write-Host "    STT — Parakeet ONNX    :$ParakeetPort   $pStat   log: $ConfigDir\parakeet-stt.log"
Write-Host "    TTS — Supertonic ONNX  :$SupertonicPort   $sStat   log: $ConfigDir\supertonic.log"
Write-Host ""
Write-Host "  Quick test:"
Write-Host "    python $SkillDir\vad_recorder.py --list-devices"
Write-Host "    & '$Python' '$SkillDir\vad_recorder.py' --list-devices"
Write-Host ""
Write-Host "  Agent integrations installed:" -ForegroundColor Cyan
foreach ($k in $SelectedIntegrations.Keys) {
    Write-Host "    $k → $($SelectedIntegrations[$k])" -ForegroundColor Gray
}
Write-Host ""
Write-Host "────────────────────────────────────────────────────────────"
