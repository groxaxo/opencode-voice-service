# OpenCode Voice Service

**Silero VAD-driven voice conversation for OpenCode.** One-command setup installs the entire voice pipeline: VAD, local ONNX STT (Parakeet), and local ONNX TTS (Supertonic) — all with launchd auto-start.

## Architecture

```
  Mic ──▶ Silero VAD ──▶ WAV ──▶ Parakeet STT (:5093, local ONNX)
                                      │
                                      ▼
                                Agent / OpenCode
                                      │
                                      ▼
                   ┌──────────────────────────────────────┐
                   │ Supertonic TTS (:8766)  — default    │
                   │ NeuTTS (:8020)         — fallback 1  │
                   │ xAI (cloud, api.x.ai)  — fallback 2  │
                   └──────────────────────────────────────┘
                                      │
                                      ▼
                                afplay ──▶ listen again
```

> **Port notes:** Supertonic defaults to `:8766` (not `:8765`) so it can coexist
> with the existing Chatterbox TTS server on `:8765`. Override with
> `SUPERTONIC_PORT=8765` if you want to replace Chatterbox (and stop the
> `com.opencode.tts-server` plist). The Parakeet STT port is `:5093`; if a
> precompiled `speech-server` already runs there, setup.sh detects it and
> leaves it alone.

## Features

- **Silero VAD** — neural voice activity detection with automatic endpointing
- **Parakeet STT** — local ONNX-based ASR, automatically installed on `:5093`
- **Supertonic TTS** — local ONNX-based TTS, automatically installed on `:8766`
- **Multi-engine TTS** — Supertonic (default local), NeuTTS (local GGUF), xAI (cloud)
- **Pipelined talk loop** — `speak` ends → mic opens instantly (`TALK_AUTO_LISTEN=1`)
- **Barge-in** — interrupt TTS playback by speaking (opt-in via `TALK_BARGE_IN=1`)
- **OpenCode skill** — `skill("talk")` for OpenCode / Cursor / Claude Code
- **Standalone CLI** — works without the IDE
- **Non-destructive setup** — existing services are preserved; re-running
  `setup.sh` is safe. Use `--force` to overwrite customized plists.

## Quick Start

```bash
git clone https://github.com/groxaxo/opencode-voice-service.git
cd opencode-voice-service
chmod +x setup.sh && ./setup.sh

# That's it! All backends auto-installed and running via launchd.
# Configure xAI (optional, for cloud TTS fallback):
export XAI_API_KEY=xai-...
```

### What setup.sh installs

| Component | Location | Port | Auto-start |
|-----------|----------|------|-----------|
| Voice core | `~/.config/opencode/skills/talk/` | — | — |
| Silero VAD | `~/.config/opencode/tts-venv/` | — | — |
| **Parakeet STT** | `~/.config/opencode/parakeet-stt/` | **5093** | launchd |
| **Supertonic TTS** | `~/.config/opencode/supertonic-tts/` | **8766** | launchd |

### Options

```bash
./setup.sh                          # full setup (all backends, non-destructive)
./setup.sh --skip-parakeet          # skip Parakeet STT installation
./setup.sh --skip-supertonic        # skip Supertonic TTS installation
./setup.sh --venv-only              # only create the voice venv
./setup.sh --skip-voices            # skip reference voice generation
./setup.sh --force                  # overwrite existing plists (DESTRUCTIVE)
./setup.sh --uninstall              # stop services and remove plists
./setup.sh --uninstall --force      # also remove all installed dirs
```

## Usage

### Standalone CLI

```bash
~/.config/opencode/skills/talk/talk.sh listen              # record + transcribe → stdout
~/.config/opencode/skills/talk/talk.sh speak "Hello"       # TTS, then auto-listen
TTS_ENGINE=xai talk.sh speak "…"                           # force xAI cloud TTS
TTS_ENGINE=supertonic talk.sh speak "…"                    # force Supertonic local TTS
~/.config/opencode/skills/talk/talk.sh status              # health check
~/.config/opencode/skills/talk/talk.sh devices             # list mics
```

### OpenCode talk loop

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
| `TTS_ENGINE` | `supertonic` | `supertonic` (local), `neutts` (local), `xai` (cloud) |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Supertonic endpoint |
| `XAI_API_KEY` | (from env) | Bearer token for xAI TTS |
| `XAI_TTS_VOICE` | `eve` | `ara`, `eve`, `leo`, `rex`, `sal` |
| `TALK_AUTO_LISTEN` | `1` | After `speak`, run `listen` |
| `TALK_BARGE_IN` | `0` | Interrupt TTS on speech (opt-in) |
| `TALK_IDLE_TIMEOUT_S` | `30` | Exit listen if no speech |
| `VAD_THRESHOLD` | `0.5` | Speech sensitivity |
| `VAD_MIN_SILENCE_MS` | `500` | End-of-turn silence |

## Service management

```bash
# Start/stop Parakeet STT
launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt
launchctl bootout gui/$UID/com.opencode.parakeet-stt

# Start/stop Supertonic TTS
launchctl kickstart -k gui/$UID/com.opencode.supertonic
launchctl bootout gui/$UID/com.opencode.supertonic

# View logs
tail -f ~/.config/opencode/parakeet-stt.log
tail -f ~/.config/opencode/supertonic.log
```

## Re-install / migration

`setup.sh` is non-destructive by default. Re-running it:

- **Cloned backends** (`parakeet-stt/`, `supertonic-tts/`): `git pull --ff-only`
  if upstream has new commits; otherwise no-op.
- **Venvs**: reused if Python version matches; recreated if upgraded.
- **launchd plists**: **skipped** if they already exist. Use `--force` to
  overwrite (will replace any customizations like port changes or model
  arguments). This is intentionally destructive to protect working installs.
- **Service files** in `~/.config/opencode/skills/talk/`: always overwritten
  (these are pure code, not user config).
- **Reference voices** (`ref_voice_en.wav`, `ref_voice_es.wav`): preserved.

To fully remove: `./setup.sh --uninstall --force`.

## Directory structure

```
opencode-voice-service/
├── README.md
├── setup.sh                    # One-command full installer
├── .env.example
├── service/
│   ├── vad_recorder.py         # Silero VAD + sounddevice
│   ├── talk.sh                 # Voice conversation orchestrator
│   ├── tts.sh                  # Multi-engine TTS CLI
│   └── tts_lang.sh             # Shared language detection
├── skill/
│   └── SKILL.md                # OpenCode talk skill
├── launchd/
│   ├── com.opencode.parakeet-stt.plist   # Parakeet ONNX auto-start
│   └── com.opencode.supertonic.plist     # Supertonic ONNX auto-start
└── docs/
    └── architecture.md
```

## Related projects

- [parakeet-tdt-0.6b-v3-fastapi-openai](https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai) — STT backend (auto-installed by setup.sh)
- [supertonic-express](https://github.com/groxaxo/supertonic-express) — TTS backend (auto-installed by setup.sh)
- [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) — iOS voice app
- [OpenCode](https://opencode.ai)

## License

MIT
