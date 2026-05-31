# OpenCode Voice Service

**Silero VAD-driven voice conversation service for OpenCode.** Continuous 16kHz microphone capture with automatic endpointing, remote STT via Parakeet, and local TTS via Chatterbox-Multilingual-MLX.

No beeps, no fixed recording windows. Just speak — the VAD detects when you're done.

## Features

- **Silero VAD** — neural voice activity detection, not crude RMS gating
- **Automatic endpointing** — configurable trailing silence threshold (default 500ms)
- **Pre-speech padding** — 400ms of audio before detected speech included for natural starts
- **Gain normalization** — audio boosted to -20dBFS before STT (OpenVoiceApp pattern)
- **Ring buffer** — bounded memory growth, handles arbitrary-length utterances
- **Language-aware TTS** — auto-detects Spanish vs English from character patterns
- **OpenCode skill** — ready-to-use skill definition for `skill("talk")`
- **Standalone CLI** — works independently of OpenCode for testing and scripting

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   VAD Recorder (vad_recorder.py)              │
│                                                               │
│  ┌──────────┐    ┌─────────────┐    ┌──────────────────┐     │
│  │ sounddevice│──▶│ Silero VAD  │──▶│  Endpointer       │     │
│  │ (16kHz)   │   │ (512 frames)│   │ (500ms silence)  │     │
│  └──────────┘    └─────────────┘    └────────┬─────────┘     │
│                                              │                │
│           speech_end ──▶ RingBuffer.slice ──▶ save_wav        │
│                                              │                │
└──────────────────────────────────────────────┼────────────────┘
                                               ▼
                                    ┌──────────────────┐
                                    │  Parakeet STT    │
                                    │ (:5092)          │
                                    └────────┬─────────┘
                                             ▼
                                    ┌──────────────────┐
                                    │  OpenCode / CLI  │
                                    └────────┬─────────┘
                                             ▼
                                    ┌──────────────────┐
                                    │  Chatterbox TTS   │
                                    │ (:8765, local)    │
                                    └──────────────────┘
```

The design is modeled after [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) iOS architecture — see the [architecture docs](docs/architecture.md) for detailed mappings.

## Prerequisites

- **macOS** (Apple Silicon recommended for TTS performance)
- **Python 3.12** (managed via `uv` or `pyenv`)
- **ffmpeg** (for reference voice generation)
- **TTS server**: `mlx-audio` running at `localhost:8765`
- **STT server**: Parakeet at `100.85.200.51:5092`

## Quick Start

```bash
# 1. Clone
git clone https://github.com/groxaxo/opencode-voice-service.git
cd opencode-voice-service

# 2. Run setup (creates venv, installs deps)
chmod +x setup.sh && ./setup.sh

# 3. Test the service
./service/talk.sh status
./service/talk.sh devices

# 4. Speak!
./service/talk.sh listen
# (speak into your mic, wait for silence, transcribed text appears)

# 5. Hear a response
./service/talk.sh speak "Hello from the voice service"
```

## Usage

### As a Standalone Service

```bash
# Record one utterance and transcribe
./service/talk.sh listen
# → "the transcribed text"

# Speak via TTS
./service/talk.sh speak "Text to say" [en|es]

# Continuous conversation loop (readline-based)
./service/talk.sh loop

# Check everything is working
./service/talk.sh status

# List audio inputs
./service/talk.sh devices
```

### As an OpenCode Skill

The skill at `skill/SKILL.md` is registered by default when you run `setup.sh`. It's triggered by the model when the user says "talk", "voice", "speak", "habla", etc.

The model orchestrates the talk loop:

1. `talk.sh listen` — VAD records + STT returns transcribed text
2. Process text as the user's message
3. `talk.sh speak "response"` — TTS playback
4. Loop

### SDK / Scripting

```python
# Programmatic use from Python
from service.vad_recorder import VADRecorder, list_devices, save_wav
import argparse

args = argparse.Namespace(
    oneshot=True, continuous=False,
    output_dir="/tmp", output_file="utterance.wav",
    min_silence_ms=500, vad_threshold=0.5,
    pre_speech_ms=400, max_duration_s=30,
    mic_device=None, mic_query="MacBook",
    debug=False
)
recorder = VADRecorder(args)
recorder.run()
```

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PYTHON` | auto-detected | Python interpreter path |
| `VAD_THRESHOLD` | 0.5 | Speech probability threshold |
| `VAD_MIN_SILENCE_MS` | 500 | Trailing silence before turn end |
| `MIC_QUERY` | MacBook | Mic device name substring |
| `STT_URL` | http://100.85.200.51:5092/... | Parakeet STT endpoint |
| `STT_MODEL` | istupakov/parakeet-tdt-0.6b-v3-onnx | STT model name |
| `TTS_SERVER` | http://localhost:8765 | TTS server URL |
| `TTS_HOST` | localhost | TTS host override |
| `TTS_PORT` | 8765 | TTS port override |
| `REF_DIR` | ~/.config/opencode | Reference voice directory |

## Reference Voices

Generate cloned voices for TTS:

```bash
# English (Samantha)
say -v "Samantha" -o /tmp/ref.aiff "Hello, I am your AI assistant." && \
  ffmpeg -i /tmp/ref.aiff -ar 22050 -ac 1 ~/.config/opencode/ref_voice_en.wav -y

# Spanish (Mónica)
say -v "Mónica" -o /tmp/ref.aiff "Hola, soy tu asistente de inteligencia artificial." && \
  ffmpeg -i /tmp/ref.aiff -ar 22050 -ac 1 ~/.config/opencode/ref_voice_es.wav -y
```

## Directory Structure

```
opencode-voice-service/
├── README.md                  # This file
├── LICENSE                    # MIT
├── setup.sh                   # One-command setup
├── .gitignore
├── service/
│   ├── vad_recorder.py        # Silero VAD recording engine
│   ├── talk.sh                # Voice conversation orchestrator
│   └── tts.sh                 # TTS CLI wrapper
├── skill/
│   └── SKILL.md               # OpenCode skill definition
├── launchd/
│   └── com.opencode.tts-server.plist  # TTS server autostart
└── docs/
    └── architecture.md         # Architecture reference
```

## OpenCode Skill Integration

After `setup.sh`, the skill is installed to `~/.config/opencode/skills/talk/`. The model loads it automatically when you say "talk", "voice", "speak", "habla", etc.

To re-register manually:
```bash
# Symlink the skill
ln -sf "$PWD/skill" ~/.config/opencode/skills/talk
```

## Related Projects

- [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) — iOS app this service's architecture is modeled after
- [Chatterbox TTS Setup](https://github.com/groxaxo/chatterbox-tts-setup) — TTS server setup scripts
- [OpenCode](https://opencode.ai) — The AI coding assistant this skill is for

## License

MIT
