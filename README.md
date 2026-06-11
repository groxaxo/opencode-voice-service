# OpenCode Voice Service

**Local voice conversation for AI agents — 100% CPU-only, no GPU required.**  
One-command setup installs the full voice pipeline: [Silero VAD](https://github.com/snakers4/silero-vad) for speech detection, [Parakeet TDT 0.6B](https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai) for ONNX transcription, and [Supertonic TTS 2](https://github.com/groxaxo/supertonic-express) for ONNX synthesis — **all running locally on CPU, no cloud required**.

Works out of the box with **Claude Code**, **OpenCode CLI**, **OpenClaw**, **Hermes Agent**, and **Codex**.

## Why CPU-only?

> **You don't need a GPU to get great voice performance.**

All three engines in this stack are designed for CPU inference. The latency
numbers below are **measured**, not estimated — see [Benchmarks](#benchmarks).

| Engine | Runtime | CPU latency (measured) | Download |
|--------|---------|------------------------|----------|
| **Silero VAD** | ONNX | ~0.1 ms/frame (32 ms audio per frame) | ~1.3 MB |
| **Parakeet TDT 0.6B v3** | ONNX INT8 | ~280 ms for a short reply (8–21× realtime) | ~600 MB |
| **Supertonic TTS 2** | ONNX | ~0.8 s for a short reply (3–13× realtime) | ~250 MB |

The VAD and ONNX stack are optimized for Intel, AMD, and Apple Silicon CPUs. No CUDA, no ROCm, no GPU dependencies of any kind. The stack runs well on laptops, WSL, Docker containers, and CI machines.

## Benchmarks

Measured end-to-end on an **Intel Core i7-12700KF** (12-core/20-thread desktop
CPU), all engines on **CPU only**, no GPU, with the default ONNX models:

| Stage | Input | Latency (median of 5) | Speed vs realtime |
|-------|-------|-----------------------|-------------------|
| **Silero VAD** | one 512-sample frame (32 ms) | **0.09 ms** | ~350× |
| **Parakeet STT** | 2.5 s utterance | **282 ms** | 8.9× |
| **Parakeet STT** | 7.7 s utterance | **511 ms** | 15× |
| **Parakeet STT** | 17 s utterance | **812 ms** | 21× |
| **Supertonic TTS** | short reply (→2.5 s audio) | **777 ms** | 3.2× |
| **Supertonic TTS** | medium reply (→7.7 s audio) | **944 ms** | 8.2× |
| **Supertonic TTS** | long reply (→17 s audio) | **1.36 s** | 12.6× |

So on a normal desktop CPU, the **voice overhead around your LLM is ~1–1.5 s**
(STT + TTS); the slowest part of the loop is usually the LLM itself.

**GPU?** You don't need one — that's the point. On the test machine both GPUs
were fully committed to the local LLM (a vLLM tensor-parallel deployment), so the
voice stack ran entirely on CPU and never touched VRAM. Parakeet *can* use
`onnxruntime-gpu` (CUDA) if you have spare VRAM, but the design goal is to leave
the GPU free for the model that's actually answering you.

## Architecture

```
  Mic ──▶ Silero VAD ──▶ WAV ──▶ Parakeet STT (:5093, ONNX, CPU)
    (local ONNX)                          │
                                          ▼
                                  Agent / OpenCode / Claude Code
                                          │
                                          ▼
                     ┌──────────────────────────────────────┐
                     │ Supertonic TTS (:8766) — default      │  ONNX, CPU
                     │ NeuTTS (:8020)         — fallback 1   │  local GGUF
                     │ xAI (cloud, api.x.ai)  — fallback 2   │  cloud API
                     └──────────────────────────────────────┘
                                          │
                                          ▼
                                  audio playback ──▶ listen again
```

> **Port notes:** Supertonic defaults to `:8766` (not `:8765`) so it can coexist
> with an existing Chatterbox TTS server on `:8765`. Override with
> `SUPERTONIC_PORT=8765` if you want to replace Chatterbox. The Parakeet STT
> port is `:5093`; if a precompiled `speech-server` already runs there, `setup.sh`
> detects it and leaves it alone.

## Features

- **Silero VAD** — neural voice activity detection, ONNX, CPU-only
- **Parakeet STT** — ONNX INT8 ASR, auto-installed, 25 languages, ~200–500ms CPU
- **Supertonic TTS** — ONNX TTS, auto-installed, multilingual EN/ES/KO/PT/FR, CPU-only
- **Multi-engine TTS** — Supertonic (local ONNX), NeuTTS (local GGUF), xAI (cloud)
- **Pipelined talk loop** — `speak` ends → mic opens instantly (`TALK_AUTO_LISTEN=1`)
- **Barge-in** — interrupt TTS playback by speaking (opt-in via `TALK_BARGE_IN=1`)
- **Cross-platform** — macOS, Linux, Windows (PowerShell + Task Scheduler)
- **Multi-agent** — Claude Code, OpenCode CLI, OpenClaw, Hermes Agent, Codex
- **Interactive installer** — select components and agent integrations at setup time
- **Non-destructive setup** — existing services preserved; re-running `setup.sh` is safe

## Platform support

| Platform | Installer | Auto-start | Audio |
|----------|-----------|-----------|-------|
| **macOS** | `setup.sh` | launchd | `afplay` |
| **Linux** | `setup.sh` | systemd (user) | `ffplay` / `aplay` / `paplay` |
| **Windows** | `setup.ps1` | Task Scheduler | `ffplay` / SoundPlayer |

## Quick Start

### macOS / Linux

```bash
git clone https://github.com/groxaxo/opencode-voice-service.git
cd opencode-voice-service
chmod +x setup.sh && ./setup.sh
```

Running `./setup.sh` with no arguments starts an **interactive menu** — pick which
components (Parakeet STT, Supertonic TTS) and which agent integrations
(Claude Code, OpenCode, OpenClaw, Hermes, Codex) to install.

```bash
# Silent full install (all components + all integrations)
./setup.sh

# Selective install (skip flags)
./setup.sh --skip-parakeet          # skip Parakeet STT
./setup.sh --skip-supertonic        # skip Supertonic TTS
./setup.sh --integrations=claudecode,opencode  # only these agents

# That's it! All backends auto-installed and running.
# Optional: configure xAI cloud TTS fallback
export XAI_API_KEY=xai-...
```

### Windows (PowerShell)

```powershell
git clone https://github.com/groxaxo/opencode-voice-service.git
cd opencode-voice-service
.\setup.ps1
```

The Windows installer prompts for the same component and integration choices,
then registers Task Scheduler tasks that start Parakeet and Supertonic on login.

**Prerequisites (Windows):**
- Python 3.11+ (`winget install Python.Python.3.12`)
- Git (`winget install Git.Git`)
- Optional: ffmpeg for audio playback (`winget install Gyan.FFmpeg`)

### What setup installs

| Component | Location | Port | Auto-start |
|-----------|----------|------|-----------|
| Voice venv (VAD + ONNX) | `~/.config/opencode/tts-venv/` | — | — |
| **Parakeet STT** | `~/.config/opencode/parakeet-stt/` | **5093** | launchd / systemd / Task Scheduler |
| **Supertonic TTS** | `~/.config/opencode/supertonic-tts/` | **8766** | launchd / systemd / Task Scheduler |
| Skill (all agents) | See [Agent integrations](#agent-integrations) | — | — |

## Agent integrations

The installer copies the `talk` skill to each selected agent's skill directory:

| Agent | Skill path | How to activate |
|-------|-----------|-----------------|
| **Claude Code** | `~/.claude/skills/talk/` | `skill("talk")` or auto-detected |
| **OpenCode CLI** | `~/.config/opencode/skills/talk/` | `skill("talk")` |
| **OpenClaw** | `~/.openclaw/skills/talk/` | `skill("talk")` |
| **Hermes Agent** | `~/.hermes/skills/talk/` | `skill("talk")` |
| **Codex** | `~/.codex/skills/talk/` | auto-detected via symlink |

All agents use the same `SKILL.md` descriptor, which tells them:
1. When to invoke the skill (trigger words: *talk, voice, speak, habla, audio, tts*)
2. How to orchestrate the VAD → STT → TTS loop
3. Port and path configuration

### Setup options

```bash
./setup.sh                                     # interactive menu (all defaults)
./setup.sh --skip-parakeet                     # skip Parakeet STT
./setup.sh --skip-supertonic                   # skip Supertonic TTS
./setup.sh --venv-only                         # only create the voice venv
./setup.sh --skip-voices                       # skip reference voice generation
./setup.sh --force                             # overwrite existing plists/tasks (DESTRUCTIVE)
./setup.sh --uninstall                         # stop services and remove plists
./setup.sh --uninstall --force                 # also remove all installed dirs
./setup.sh --integrations=claudecode,opencode  # only install specific integrations
./setup.sh --no-integrations                   # skip all agent integrations
```

## Usage

### Standalone CLI

```bash
~/.config/opencode/skills/talk/talk.sh listen              # record + transcribe → stdout
~/.config/opencode/skills/talk/talk.sh speak "Hello"       # TTS + auto-listen
TTS_ENGINE=xai talk.sh speak "…"                           # force xAI cloud TTS
TTS_ENGINE=supertonic talk.sh speak "…"                    # force Supertonic local TTS
~/.config/opencode/skills/talk/talk.sh status              # health check
~/.config/opencode/skills/talk/talk.sh devices             # list mics
```

### Windows PowerShell

```powershell
# After setup.ps1
~\.config\opencode\skills\talk\talk.ps1 listen
~\.config\opencode\skills\talk\talk.ps1 speak "Hello"
~\.config\opencode\skills\talk\talk.ps1 status
```

### Agent talk loop (all agents)

The agent runs:

1. **Once:** `talk.sh listen` → first user message
2. **Each turn:** `talk.sh speak '<short reply>'` → plays audio, then records; **stdout = next user message**
3. Do **not** call `listen` after `speak` (built in).

See `skill/SKILL.md` for full agent rules.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `STT_ENGINE` | `coreml` | STT backend (Parakeet ONNX on `:5093`) |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Local Parakeet STT |
| `TTS_ENGINE` | `supertonic` | `supertonic` (local ONNX), `neutts` (local GGUF), `xai` (cloud) |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Supertonic endpoint |
| `XAI_API_KEY` | (from env) | Bearer token for xAI TTS cloud fallback |
| `XAI_TTS_VOICE` | `eve` | `ara`, `eve`, `leo`, `rex`, `sal` |
| `TALK_AUTO_LISTEN` | `1` | After `speak`, run `listen` |
| `TALK_BARGE_IN` | `0` | Interrupt TTS on speech (opt-in) |
| `TALK_IDLE_TIMEOUT_S` | `30` | Exit listen if no speech |
| `VAD_THRESHOLD` | `0.5` | Speech sensitivity |
| `VAD_MIN_SILENCE_MS` | `500` | End-of-turn silence |

## Service management

### macOS (launchd)

```bash
# Start/stop Parakeet STT
launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt
launchctl bootout gui/$UID/com.opencode.parakeet-stt

# Start/stop Supertonic TTS
launchctl kickstart -k gui/$UID/com.opencode.supertonic
launchctl bootout gui/$UID/com.opencode.supertonic

# Logs
tail -f ~/.config/opencode/parakeet-stt.log
tail -f ~/.config/opencode/supertonic.log
```

### Linux (systemd)

```bash
# Start/stop
systemctl --user start opencode-parakeet-stt
systemctl --user start opencode-supertonic

# Status
systemctl --user status opencode-parakeet-stt
systemctl --user status opencode-supertonic

# Logs
journalctl --user -u opencode-parakeet-stt -f
journalctl --user -u opencode-supertonic -f
```

### Windows (Task Scheduler)

```powershell
Start-ScheduledTask  "OpenCode-Parakeet-STT"
Stop-ScheduledTask   "OpenCode-Parakeet-STT"
Start-ScheduledTask  "OpenCode-Supertonic"
Stop-ScheduledTask   "OpenCode-Supertonic"

# Logs
Get-Content "$env:USERPROFILE\.config\opencode\parakeet-stt.log" -Tail 50
Get-Content "$env:USERPROFILE\.config\opencode\supertonic.log" -Tail 50
```

## Re-install / migration

`setup.sh` is non-destructive by default. Re-running it is safe. Use `--force` to
overwrite existing plists/systemd units. See `./setup.sh --help` for all options.

## Directory structure

```
opencode-voice-service/
├── README.md
├── setup.sh                    # macOS + Linux one-command installer
├── setup.ps1                   # Windows PowerShell installer
├── .env.example
├── service/
│   ├── vad_recorder.py         # Silero VAD + sounddevice (cross-platform)
│   ├── talk.sh                 # Voice conversation orchestrator (macOS + Linux)
│   ├── tts.sh                  # Multi-engine TTS CLI (macOS + Linux)
│   └── tts_lang.sh             # Shared language detection
├── windows/
│   └── talk.ps1                # Windows voice conversation orchestrator
├── skill/
│   └── SKILL.md                # Agent skill descriptor (all agents)
├── launchd/
│   ├── com.opencode.parakeet-stt.plist   # macOS Parakeet auto-start
│   └── com.opencode.supertonic.plist     # macOS Supertonic auto-start
└── docs/
    └── architecture.md
```

## Related projects

- [parakeet-tdt-0.6b-v3-fastapi-openai](https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai) — STT backend
- [supertonic-express](https://github.com/groxaxo/supertonic-express) — TTS backend
- [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) — iOS voice app
- [OpenCode](https://opencode.ai)

## License

MIT
