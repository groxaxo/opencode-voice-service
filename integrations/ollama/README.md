# Ollama voice integration

A **local, CPU-only voice interface for [Ollama](https://github.com/ollama/ollama)**
so you can talk to your models and hear them reply — no GPU, no API keys, no cloud.
Uses the `opencode-voice-service` speech stack (Silero VAD → Parakeet STT → Supertonic TTS).

## Quick Start (no rebuild needed)

For a **pre-installed Ollama** (the common case):

```bash
# 1. One-time install
bash integrations/ollama/install-ollama-voice.sh

# 2. Start talking
ollama-voice llama3.2
```

That's it. `ollama-voice` is a standalone Bash orchestrator that calls the voice
stack (`talk.sh listen` / `talk.sh speak`) and Ollama's HTTP API (`/api/chat`) —
no Go rebuild, no source patch, no Ollama restart.

```bash
ollama-voice llama3.2           # talk to llama3.2
ollama-voice qwen3.5            # talk to any model in `ollama ls`
ollama-voice --setup            # re-run voice backend install
ollama-voice --status           # health check for all components
```

See `ollama-voice --help` for the full list.

## Advanced: native Ollama patch (deep integration)

For embedding voice as a native `ollama voice` subcommand and `/voice` REPL toggle:

| File | Purpose |
| --- | --- |
| `0001-ollama-voice.patch` | Full Go source patch for Ollama checkout |
| `ollama-voice.sh` | Standalone orchestrator (no rebuild) |
| `install-ollama-voice.sh` | Autoinstaller for the standalone approach |

The patch adds a `voice/` Go package, `cmd/voice.go` subcommand, and `/voice` toggle
in `cmd/interactive.go`. Apply to an Ollama checkout:

```bash
git clone https://github.com/ollama/ollama.git && cd ollama
git am /path/to/integrations/ollama/0001-ollama-voice.patch
go build . && ./ollama voice --setup && ./ollama voice llama3.2
```

Requires Go 1.26+ and the full Ollama build toolchain.

## Architecture

```
ollama-voice (or `ollama voice`)
  ├─ talk.sh listen   → Silero VAD → Parakeet ONNX STT (:5093) → text
  ├─ Ollama /api/chat → LLM inference (any ollama model)
  └─ talk.sh speak    → Supertonic ONNX TTS (:8766) → speaker → auto-listen
```

All speech inference is CPU-only. The LLM runs wherever Ollama runs (CPU, GPU, or remote).

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | Ollama server URL |
| `OLLAMA_VOICE_MAX_TOKENS` | `250` | Max response tokens |
| `OLLAMA_VOICE_NO_THINK` | `1` | Disable CoT thinking for reasoning models |
| `OLLAMA_OPTIONS` | `{}` | Extra JSON options to pass to `/api/chat` |
| `TTS_ENGINE` | `supertonic` | TTS engine: `supertonic`, `neutts`, `xai` |
| `VAD_THRESHOLD` | `0.5` | Mic speech-detection sensitivity |
| `TALK_IDLE_TIMEOUT_S` | `30` | Stop listening after N seconds of silence |
| `MIC_QUERY` | _(auto)_ | Substring to pick a specific microphone |

## Notes

- The standalone `ollama-voice` works with any pre-installed Ollama binary — no rebuild.
- The `0001-ollama-voice.patch` targets `ollama/ollama` `main`. If upstream has moved,
  apply with `git apply --3way` or re-base.
- Reasoning models (Qwen3.5, DeepSeek-R1, etc.) get `think: false` by default to
  prevent chain-of-thought from being spoken aloud. Set `OLLAMA_VOICE_NO_THINK=0` to
  hear the full reasoning.
- As a safeguard, any inline `<think>…</think>` reasoning a model emits in its reply
  is stripped before TTS — so even models that ignore the `think` flag never get
  their chain-of-thought read aloud. A reply that is *only* reasoning (e.g. cut off
  at `OLLAMA_VOICE_MAX_TOKENS`) is dropped and the loop simply listens again.
