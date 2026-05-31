# Architecture Reference

## Overview

The OpenCode Voice Service provides real-time voice conversation capabilities through a three-stage pipeline: **VAD → STT → TTS**. It is designed as both a standalone CLI service and an [OpenCode](https://opencode.ai) skill.

The architecture is modeled after [OpenVoiceApp](https://github.com/groxaxo/OpenVoiceApp) iOS, a production voice app whose on-device voice stack patterns we adopt for the macOS/CLI environment.

## VAD Pipeline (vad_recorder.py)

```
sounddevice.InputStream ──▶ Silero VAD (ONNX) ──▶ Endpointer ──▶ RingBuffer.slice ──▶ save_wav
    16kHz mono               512-sample frames      500ms silence     gain norm to        16-bit WAV
    float32 chunks           ~32ms per frame        trailing          -20dBFS
```

### Component Breakdown

| Component | Responsibility | OpenVoiceApp Equivalent |
|-----------|---------------|------------------------|
| `sounddevice.InputStream` | Continuous 16kHz mono float32 capture | `AVAudioEngine` + tap |
| `RingBuffer` | Rolling buffer of audio frames, capacity-trimmed | `AudioRingBuffer` |
| `VADIterator` | Silero VAD: speech probability per 512-sample frame | `LocalSileroVAD` + `SherpaOnnxVoiceActivityDetectorWrapper` |
| `Endpointer` | Track start/end of speech segment; fire on trailing silence | `VoiceTurnTiming.sileroSpeechEndFrames` |
| `normalize_audio()` | Boost quiet signals to -20dBFS RMS, hard ceiling at 0.98 | `AudioLevelAnalyzer.normalize()` |
| `save_wav()` | Write float32 → 16-bit PCM WAV | `AVAudioFile` write |

### VAD Parameters

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| `--vad-threshold` | 0.5 | Standard Silero threshold; balances false accepts vs false rejects |
| `--min-silence-ms` | 500 | Matches `VoiceTurnTiming.sileroSpeechEndFrames` (~512ms at 16×32ms) |
| `--pre-speech-ms` | 400 | Includes ~13 frames of audio before VAD triggers (padding) |
| `--max-duration-s` | 30 | Safety limit; rare in practice since VAD is responsive |

### Endpointing State Machine

```
        speech_prob >= threshold
    IDLE ─────────────────────────▶ SPEAKING
     ▲                                  │
     │                                  │ speech_prob < threshold - 0.15
     │                                  ▼
     │                          TEMP_SILENCE
     │                                  │
     │                    ┌─────────────┴─────────────┐
     │                    │                             │
     │          speech_prob >= threshold       silence > min_silence_ms
     │               (barge-in)                     (end turn)
     │                    │                             │
     │                    ▼                             ▼
     │               SPEAKING                     FILE_OUTPUT
     └────────────────────────────────────────────────┘
                        (reset)
```

The hysteresis gap (`threshold - 0.15`) prevents rapid toggling around the decision boundary, matching the iOS app's behavior.

## STT Pipeline

```
  multipart/form-data POST
  ───────────────────────────▶ http://100.85.200.51:5092/v1/audio/transcriptions
  WAV file + model name            │
                                   ▼
                              Parakeet TDT 0.6B v3
                                   │
                                   ▼
                              {"text": "..."}
```

- Remote service at 100.85.200.51 (OpenClaw bridge, LAN)
- Accepts 16-bit mono WAV at any sample rate (internally resampled)
- Returns JSON with transcribed `text`

## TTS Pipeline

```
  JSON POST
  ──────────▶ http://localhost:8765/v1/audio/speech
  text + lang + ref_audio        │
                                 ▼
  Chatterbox-Multilingual-MLX-v2-Q8
  (theoracleguy/Chatterbox-Multilingual-MLX-v2-Q8)
                                 │
                                 ▼
  WAV ──▶ afplay
```

- Local mlx-audio server, Apple Silicon optimized
- Reference voice clones for consistency:
  - EN: Samantha clone (`ref_voice_en.wav`)
  - ES: Mónica clone (`ref_voice_es.wav`)
- Streaming capable (the model supports it; current implementation synthesizes full utterance)

## Data Flow (Full Turn)

```
User speaks ◀──────────────────────────────────┐
  │                                            │
  ▼                                            │
[sounddevice] 16kHz float32 frames             │
  │                                            │
  ▼                                            │
[Silero VAD] per-frame speech detection        │
  │                                            │
  ▼                                            │
[RingBuffer] accumulates audio                 │
  │                                            │
  ▼                                            │
[Endpointer] 500ms silence → turn complete     │
  │                                            │
  ▼                                            │
[normalize_audio] boost to -20dBFS             │
  │                                            │
  ▼                                            │
[save_wav] 16-bit PCM WAV                      │
  │                                            │
  ▼                                            │
[Parakeet STT] HTTP multipart POST             │
  │                                            │
  ▼                                            │
[Transcribed text] output to stdout            │
  │                                            │
  ▼                                            │
[OpenCode / CLI] process as user message       │
  │                                            │
  ▼                                            │
[Chatterbox TTS] local HTTP POST               │
  │                                            │
  ▼                                            │
[afplay] audio output ─────────────────────────┘
```

## Timings

Measured on Apple Silicon MacBook Air, LAN-connected STT server:

| Stage | Latency (approx) |
|-------|-----------------|
| VAD endpointing | ~500ms trailing silence |
| STT (Parakeet, remote) | ~200–800ms depending on utterance length |
| TTS (Chatterbox, local) | ~500–2000ms depending on utterance length |
| **E2E (speak → hear response)** | **~2–4s** for typical 3–5 word turns |

## OpenCode Integration

The skill (`skill/SKILL.md`) injects voice conversation instructions when the model detects trigger keywords. The model then orchestrates the talk loop by calling `talk.sh listen` and `talk.sh speak`:

```
[User] "talk to me"
  → model loads talk skill
  → model runs: talk.sh listen
  → VAD records → STT → text returned
  → model processes text as user message
  → model runs: talk.sh speak "response"
  → TTS plays response
  → loop: talk.sh listen again
```

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `silero-vad` | ≥6.0 | VAD model (ONNX via PyTorch) |
| `sounddevice` | ≥0.5 | Microphone capture |
| `onnxruntime` | ≥1.18 | ONNX inference engine |
| `torch` | ≥2.0 | Tensor ops for VAD |
| `mlx-audio` | ≥0.4 | TTS server (local) |
| `numpy` | ≥1.26 | Audio buffer math |
