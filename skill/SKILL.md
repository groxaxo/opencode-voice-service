---
name: talk
description: >
  Real-time voice conversation via Talk mode. Use ONLY when the user says
  talk, voice, speak, habla, voz, audio, talk mode, or wants voice/audio
  interaction. Triggers on voice, talk, speak, habla, audio, tts, stt.
---

# Talk Mode — VAD-Driven Voice Conversation

Uses **Silero VAD** for automatic endpointing, **Parakeet TDT 0.6B v3** for STT, and **Chatterbox-Multilingual-MLX-v2-Q8** for local TTS.

No beeps, no fixed recording duration. Just speak and the recorder automatically detects when you're done (trailing silence ≥ 500ms).

## Architecture

| Layer | Component | Details |
|-------|-----------|---------|
| **VAD** | Silero VAD (ONNX via PyTorch) | 512-sample frames @ 16kHz, ~32ms/frame, 500ms trailing silence endpointing |
| **STT** | Parakeet TDT 0.6B v3 | Remote HTTP at `100.85.200.51:5092` |
| **TTS** | Chatterbox-Multilingual MLX v2 Q8 | Local mlx-audio server at `localhost:8765`, launchd autostart |
| **Audio in** | sounddevice → MacBook Air Microphone | Continuous 16kHz mono float32 capture |
| **Audio out** | afplay → system audio | WAV playback |
| **Python venv** | `~/.config/opencode/tts-venv` | silero-vad, sounddevice, onnxruntime, torch, mlx-audio |

The VAD recorder (`service/vad_recorder.py`) models the OpenVoiceApp iOS architecture:
- `RingBuffer` → matches `AudioRingBuffer` capacity-trimmed rolling buffer
- `VADIterator` → matches `LocalSileroVAD` + `SherpaOnnxVoiceActivityDetectorWrapper`
- 500ms `min_silence_duration` → matches `VoiceTurnTiming.sileroSpeechEndFrames` (~512ms)
- 400ms pre-speech padding → matches `speech_pad_ms` logic
- Gain normalization to -20dBFS → matches `AudioLevelAnalyzer.normalize()`

## Quick Commands

The `talk.sh` orchestrator handles everything:

```bash
# Listen: Silero VAD record + Parakeet STT → prints transcribed text
~/.config/opencode/skills/talk/talk.sh listen

# Speak: Chatterbox TTS playback (auto-detects en/es from text)
~/.config/opencode/skills/talk/talk.sh speak "Text to speak" [lang]

# Status: check all services
~/.config/opencode/skills/talk/talk.sh status
```

## Talk Loop (orchestrate this in your response)

### 1. Listen — VAD-Driven Recording

```bash
~/.config/opencode/skills/talk/talk.sh listen
```

Blocks until the user finishes speaking (trailing silence ≥ 500ms). Prints transcribed text on stdout.

- No beeps, no fixed duration
- Audio gain normalized to -20dBFS before saving
- Short utterances (< 100ms) are silently discarded
- Falls back to empty string if no speech detected

### 2. Think — Process as User Message

The transcribed text is the user's message. Process it naturally as you would any text input.

### 3. Speak — TTS Response

```bash
~/.config/opencode/skills/talk/talk.sh speak "Your response here"
~/.config/opencode/tts.sh "Text to speak" [en|es]
```

- `talk.sh speak` auto-detects Spanish if the text contains accented chars
- `tts.sh` requires explicit language code
- If the TTS server is down, fall back to `say -v "Samantha" "text"`

### Full Conversation Cycle

After entering talk mode:

1. Run `~/.config/opencode/skills/talk/talk.sh listen` — blocks, returns text
2. Process the text as the user's message
3. Run `~/.config/opencode/skills/talk/talk.sh speak "..."` — speaks response
4. Loop back to step 1 (immediately resume listening)

## VAD Configuration

Set environment variables before calling `talk.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `VAD_THRESHOLD` | 0.5 | Speech probability threshold (lower = more sensitive) |
| `VAD_MIN_SILENCE_MS` | 500 | Trailing silence before turn ends |
| `MIC_QUERY` | MacBook | Substring match for mic device name |
| `STT_URL` | http://100.85.200.51:5092/... | Parakeet STT endpoint |
| `TTS_SERVER` | http://localhost:8765 | Chatterbox TTS server |

```bash
# More sensitive VAD
VAD_THRESHOLD=0.3 VAD_MIN_SILENCE_MS=800 talk.sh listen

# Use a different microphone
MIC_QUERY="Yeti" talk.sh listen
```

## Service Management

```bash
# Start TTS server
launchctl load ~/Library/LaunchAgents/com.opencode.tts-server.plist

# Stop TTS server
launchctl unload ~/Library/LaunchAgents/com.opencode.tts-server.plist

# Check status
launchctl list | grep opencode.tts

# View logs
tail -f ~/.config/opencode/tts-server.log
```

## Troubleshooting

| Problem | Check |
|---------|-------|
| No transcription | `talk.sh status` — STT endpoint reachable? |
| VAD not detecting | `talk.sh devices` — correct mic? Lower `VAD_THRESHOLD`. |
| TTS silent | `launchctl list | grep opencode.tts` — server running? |
| No audio output | System volume? `afplay /System/Library/Sounds/Ping.aiff` |

## Reference Voices

| Language | Voice | Path |
|----------|-------|------|
| English | Samantha clone | `~/.config/opencode/ref_voice_en.wav` |
| Spanish | Mónica clone | `~/.config/opencode/ref_voice_es.wav` |

Generate reference voices:
```bash
say -v "Samantha" -o /tmp/ref.aiff "Hello, I am your AI assistant." && \
  ffmpeg -i /tmp/ref.aiff -ar 22050 -ac 1 ~/.config/opencode/ref_voice_en.wav -y
say -v "Mónica" -o /tmp/ref.aiff "Hola, soy tu asistente." && \
  ffmpeg -i /tmp/ref.aiff -ar 22050 -ac 1 ~/.config/opencode/ref_voice_es.wav -y
```
