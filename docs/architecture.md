# Architecture Reference

## Overview

The OpenCode Voice Service provides real-time voice conversation capabilities through a three-stage pipeline: **VAD → STT → TTS**. It is designed as both a standalone CLI service and an OpenCode skill.

The architecture is modeled after OpenVoiceApp iOS, a production voice app whose on-device voice stack patterns we adopt for the macOS/CLI environment.

## Pipeline

```
  Mic ──▶ Silero VAD ──▶ WAV ──▶ Parakeet STT (:5093, local ONNX)
                                      │
                                      ▼
                               Agent / OpenCode
                                      │
                                      ▼
                     ┌──────────────────────────────────┐
                     │ Supertonic TTS (:8766)  — default │
                     │ NeuTTS (:8020)         — fallback │
                     │ xAI (cloud)            — fallback │
                     └──────────────────────────────────┘
                                      │
                                      ▼
                               afplay ──▶ listen again
```

## VAD Pipeline (vad_recorder.py)

```
sounddevice.InputStream ──▶ Silero VAD (ONNX) ──▶ Endpointer ──▶ RingBuffer.slice ──▶ save_wav
    16kHz mono               512-sample frames      500ms silence     gain norm to        16-bit WAV
    float32 chunks           ~32ms per frame        trailing          -20dBFS
```

### Component Breakdown

| Component | Responsibility |
|-----------|---------------|
| `sounddevice.InputStream` | Continuous 16kHz mono float32 capture |
| `RingBuffer` | Rolling buffer of audio frames, capacity-trimmed |
| `VADIterator` | Silero VAD: speech probability per 512-sample frame |
| `Endpointer` | Track start/end of speech segment; fire on trailing silence |
| `normalize_audio()` | Boost quiet signals to -20dBFS RMS, hard ceiling at 0.98 |
| `save_wav()` | Write float32 → 16-bit PCM WAV |

### VAD Parameters

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| `--vad-threshold` | 0.5 | Standard Silero threshold |
| `--min-silence-ms` | 500 | Trailing silence for turn end |
| `--pre-speech-ms` | 800 | Audio padding before detected speech |
| `--max-duration-s` | 30 | Safety limit |

## STT Pipeline (Parakeet ONNX)

```
  multipart/form-data POST
  ───────────────────────────▶ http://127.0.0.1:5093/v1/audio/transcriptions
  WAV file + model name            │
                                   ▼
                              Parakeet TDT 0.6B v3
                              ONNX Runtime (INT8)
                                   │
                                   ▼
                              {"text": "..."}
```

- Local ONNX-based inference via [parakeet-tdt-0.6b-v3-fastapi-openai](https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai)
- Auto-installed by `setup.sh` into `~/.config/opencode/parakeet-stt/`
- launchd auto-start on `:5093`
- INT8 quantized; measured 8–21× realtime on an Intel i7-12700KF (CPU only)
- 25 languages, automatic language detection

## TTS Pipeline (Supertonic ONNX)

```
  JSON POST
  ──────────▶ http://127.0.0.1:8766/v1/audio/speech  (OpenAI-compatible)
  text + voice style + lang            │
                                        ▼
  Supertonic-TTS-2-ONNX
  (onnx-community/Supertonic-TTS-2-ONNX)
                                        │
                                        ▼
  WAV ──▶ afplay
```

- Local ONNX-based inference via [supertonic-express](https://github.com/groxaxo/supertonic-express)
- Auto-installed by `setup.sh` into `~/.config/opencode/supertonic-tts/`
- launchd auto-start on `:8766` (`:8765` is reserved for the existing Chatterbox
  TTS server; both can coexist because they have different labels)
- Fast: measured 3–13× realtime on an Intel i7-12700KF (CPU only)
- Multilingual: EN, ES, KO, PT, FR

### TTS Fallback Chain

| Primary | Fallback 1 | Fallback 2 |
|---------|-----------|-----------|
| `supertonic` → | `neutts` → | `xai` |
| `neutts` → | `xai` → | `supertonic` |
| `xai` → | `neutts` → | `supertonic` |

## Full Turn Data Flow

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
[Parakeet STT :5093] HTTP multipart POST       │
  │                                            │
  ▼                                            │
[Transcribed text] output to stdout            │
  │                                            │
  ▼                                            │
[OpenCode / CLI] process as user message       │
  │                                            │
  ▼                                            │
[Supertonic TTS :8766] HTTP POST               │
  (fallback: NeuTTS :8020, xAI cloud)          │
  │                                            │
  ▼                                            │
[afplay] audio output ─────────────────────────┘
```

## Timings

Measured on an Intel Core i7-12700KF (CPU only, no GPU); see the
[Benchmarks](../README.md#benchmarks) table for the full set.

| Stage | Latency (measured) |
|-------|-----------------|
| VAD per-frame | ~0.09ms per 32ms frame (~350× realtime) |
| VAD endpointing | ~500ms trailing silence (configurable) |
| STT (Parakeet ONNX, local) | ~280ms short → ~810ms long (8–21× realtime) |
| TTS (Supertonic ONNX, local) | ~0.8s short → ~1.4s long (3–13× realtime) |
| TTS (xAI, cloud) | ~500–2000ms |
| **E2E voice overhead (speak → hear, excl. LLM)** | **~1–1.5s** local |

## Install paths

| Component | Path | Port |
|-----------|------|------|
| Voice skill | `~/.config/opencode/skills/talk/` | — |
| Voice venv | `~/.config/opencode/tts-venv/` | — |
| Parakeet STT | `~/.config/opencode/parakeet-stt/` | 5093 |
| Supertonic TTS | `~/.config/opencode/supertonic-tts/` | 8766 |

### Launchd services

| Label | Description | Log |
|-------|-------------|-----|
| `com.opencode.parakeet-stt` | Parakeet ONNX STT | `~/.config/opencode/parakeet-stt.log` |
| `com.opencode.supertonic` | Supertonic ONNX TTS | `~/.config/opencode/supertonic.log` |

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `silero-vad` | >=6.0 | VAD model (ONNX via PyTorch) |
| `sounddevice` | >=0.5 | Microphone capture |
| `onnxruntime` | >=1.18 | ONNX inference engine |
| `torch` | >=2.0 | Tensor ops for VAD |
| `numpy` | >=1.26 | Audio buffer math |
| `onnx-asr[hub]` | >=0.10 | Parakeet STT runtime |
| `uvicorn` | >=0.30 | ASGI server (STT + TTS) |
| `fastapi` | >=0.115 | API framework |
| `transformers` | >=4.30 | Hugging Face tokenizers (TTS) |
| `huggingface-hub` | >=0.20 | Model download |
| `soundfile` | >=0.12 | Audio I/O |
| `librosa` | >=0.10 | Audio processing |
