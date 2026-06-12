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
                     │ Supertonic 2  (:8880)   — optional│
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
  Supertonic 3 (FP16 ONNX)
  (groxaxo/supertonic-3-v2 · Supertone/supertonic-3)
                                        │
                                        ▼
  WAV ──▶ afplay
```

- Local ONNX-based inference via [supertonic-express-3](https://github.com/groxaxo/supertonic-express-3)
  (graph: `text_encoder → duration_predictor → vector_estimator → vocoder`,
  auto-detected as v3 by the presence of `onnx/tts.json`)
- FP16 model (~196 MB) pulled from [groxaxo/supertonic-3-v2](https://github.com/groxaxo/supertonic-3-v2)
  (CPU-optimized), with `Supertone/supertonic-3` on Hugging Face as fallback
- Auto-installed by `setup.sh` into `~/.config/opencode/supertonic-tts/`; forced to the
  CPU ONNX Runtime backend (`SUPERTONIC_ORT_BACKEND=cpu`)
- launchd / systemd auto-start on `:8766`
- Measured 1.6–2.8× realtime on an Intel i7-12700KF (CPU only); FP16, 8 denoising steps
- Multilingual: EN, ES, KO, PT, FR; voices F1–F5 / M1–M5

### Optional: Supertonic 2 (`:8880`)

[Supertonic Express 2](https://github.com/groxaxo/supertonic-express)
(model [`onnx-community/Supertonic-TTS-2-ONNX`](https://huggingface.co/onnx-community/Supertonic-TTS-2-ONNX),
66M params) is a separate, opt-in backend exposing the **same** OpenAI-compatible
`/v1/audio/speech` API. It is *not* auto-installed — add it with
`bash integrations/supertonic2/install.sh`. It runs on `:8880` (so it coexists
with Supertonic 3), is forced to the CPU ONNX Runtime backend, and is driven by
`tts.sh` via `TTS_ENGINE=supertonic2` (graph:
`text_encoder → latent_denoiser → voice_decoder`). Same language and voice
coverage as Supertonic 3. See [`integrations/supertonic2/`](../integrations/supertonic2/README.md).

### TTS Fallback Chain

**Policy:** local engines are always exhausted before the xAI cloud — xAI is the
last resort, used only if every local engine fails. (Selecting `xai` explicitly
honors that choice first, then still falls back to local engines.)

| Primary | Fallback 1 | Fallback 2 | Fallback 3 (last resort) |
|---------|-----------|-----------|--------------------------|
| `supertonic` (default) → | `neutts` (local) → | `xai` (cloud) | — |
| `supertonic2` (opt-in) → | `supertonic` (local) → | `neutts` (local) → | `xai` (cloud) |
| `neutts` → | `supertonic` (local) → | `xai` (cloud) | — |
| `xai` (explicit) → | `supertonic` (local) → | `neutts` (local) | — |

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
| TTS (Supertonic 3 ONNX, local) | ~1.7s short → ~5.5s long (1.6–2.8× realtime) |
| TTS (xAI, cloud) | ~500–2000ms |
| **E2E voice overhead (speak → hear, excl. LLM)** | **~2s** local |

## Web Dashboard (frontend/)

A browser-based control panel for live testing and configuration, served by a
FastAPI proxy at `:7862`.

```
Browser :7862 ──▶ frontend/server.py ──▶ Supertonic :8766  (TTS proxy)
                                     ──▶ Parakeet   :5093  (STT proxy)
                                     ──▶ systemctl          (GPU restart)
```

### Panels

| Panel | What it does |
|-------|-------------|
| **TTS Test** | Type text → pick voice (F1–F5 / M1–M5), language, steps (1–20), speed (0.5–2×) → Synthesize → plays in-browser `<audio>` |
| **STT Test** | Record from mic (MediaRecorder) or upload a WAV → Transcribe → shows Parakeet output |
| **VAD Settings** | Live sliders for threshold / min-silence / pre-speech / max-duration → Save persists to `frontend-config.json` |
| **Backend Settings** | GPU/CPU toggle per service → Apply & Restart writes systemd drop-in override and restarts immediately |

### Launch

```bash
cd frontend && bash start.sh       # http://localhost:7862
PORT=8080 bash start.sh            # custom port
```

`start.sh` auto-installs `fastapi`, `uvicorn`, `httpx`, `python-multipart`
into the existing `tts-venv` on first run.

### Frontend API

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | Serve `index.html` |
| `/api/voices` | GET | List available Supertonic voices |
| `/api/status` | GET | Health of Supertonic + Parakeet |
| `/api/tts` | POST | Proxy to Supertonic `:8766/v1/audio/speech` |
| `/api/stt` | POST | Proxy multipart to Parakeet `:5093/v1/audio/transcriptions` |
| `/api/config` | GET/POST | Read/write VAD + GPU settings (`frontend-config.json`) |

### GPU toggle flow

1. POST `/api/config` with `use_gpu_supertonic: true`
2. Writes `~/.config/systemd/user/opencode-supertonic.service.d/gpu-override.conf`
3. Runs `systemctl --user daemon-reload && restart opencode-supertonic`
4. Returns `{"restarted": ["opencode-supertonic"]}`

Same pattern for `use_gpu_parakeet` → `opencode-parakeet-stt`.

## Install paths

| Component | Path | Port |
|-----------|------|------|
| Voice skill | `~/.config/opencode/skills/talk/` | — |
| Voice venv | `~/.config/opencode/tts-venv/` | — |
| Parakeet STT | `~/.config/opencode/parakeet-stt/` | 5093 |
| Supertonic TTS | `~/.config/opencode/supertonic-tts/` | 8766 |
| **Web dashboard** | `frontend/` (repo) | **7862** |
| VAD/GPU config | `~/.config/opencode/frontend-config.json` | — |

### Launchd services (macOS)

| Label | Description | Log |
|-------|-------------|-----|
| `com.opencode.parakeet-stt` | Parakeet ONNX STT | `~/.config/opencode/parakeet-stt.log` |
| `com.opencode.supertonic` | Supertonic ONNX TTS | `~/.config/opencode/supertonic.log` |

### Systemd services (Linux)

| Unit | Description | Log |
|------|-------------|-----|
| `opencode-parakeet-stt.service` | Parakeet ONNX STT | `~/.config/opencode/parakeet-stt.log` |
| `opencode-supertonic.service` | Supertonic ONNX TTS | `~/.config/opencode/supertonic.log` |

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
