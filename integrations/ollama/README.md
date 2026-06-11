# Ollama voice integration

This patch adds a **local, CPU-only voice interface to [Ollama](https://github.com/ollama/ollama)**
so you can talk to your models and hear them reply. It packages the
`opencode-voice-service` speech stack (Silero VAD → Parakeet STT → Supertonic TTS)
as a native Ollama command.

After applying it, Ollama gains:

- **`ollama voice <model>`** — a hands-free spoken conversation loop
- **`/voice`** — a toggle inside the `ollama run` REPL to switch a session to speech
- **`ollama voice --setup`** — one command to install and start the local speech backends

Ollama only orchestrates the `listen → chat → speak` loop; it reuses its existing chat
API, so any model you can `ollama run` you can also talk to. All speech inference is CPU
only — no GPU required.

## What's in here

| File | Purpose |
| --- | --- |
| `0001-ollama-voice.patch` | The full change, applyable to an Ollama checkout |

The patch adds a `voice/` Go package (with the Bash/PowerShell/Python speech scripts
embedded via `go:embed`), a `cmd/voice.go` subcommand, a `/voice` toggle in
`cmd/interactive.go`, and `docs/voice.md`.

## Install

### Prerequisites

- **Go 1.26+** and a working Ollama build toolchain (see Ollama's `docs/development.md`)
- **git**
- **python 3.10+** on your `PATH`
- An audio player: `afplay` (macOS), `ffplay`/`aplay`/`paplay` (Linux), built-in (Windows)

### 1. Apply the patch to an Ollama checkout

```bash
git clone https://github.com/ollama/ollama.git
cd ollama

# with git am (keeps the commit), from this repo:
git am /path/to/integrations/ollama/0001-ollama-voice.patch

# …or, if you prefer a plain apply:
git apply /path/to/integrations/ollama/0001-ollama-voice.patch
```

### 2. Build Ollama

```bash
go build .          # produces the ./ollama binary
# (or the full native build per Ollama's docs: cmake -B build . && cmake --build build)
```

### 3. Install the speech backends (one time)

```bash
./ollama voice --setup
```

`--setup` is an **interactive installer**: it detects your OS/GPU, proposes an
acceleration backend, and lets you pick. It installs everything under `~/.ollama/voice/`
(override with `OLLAMA_VOICE_HOME`): the Parakeet STT server on `:5093` and the Supertonic
TTS server on `:8766`, and registers auto-start units — **systemd `--user`** on Linux,
**launchd** on macOS, **Task Scheduler** on Windows.

Acceleration (`--accel`, default `auto`):

| Value | Where | Backend |
| --- | --- | --- |
| `cpu` | any | plain `onnxruntime` (portable) |
| `cuda` | Linux | `onnxruntime-gpu` on NVIDIA |
| `coreml` | macOS | Apple Neural Engine — Supertonic-3 CoreML (`CPU_AND_NE`) |
| `directml` | Windows | `onnxruntime-directml` (GPU) |

```bash
./ollama voice --setup --accel cpu --yes   # non-interactive
./ollama voice --setup --accel coreml      # macOS Neural Engine
```

On Windows, `--setup` invokes the bundled `setup.ps1` (CPU or DirectML) and registers the
Task Scheduler tasks.

### 4. Talk to a model

```bash
./ollama serve            # in one terminal (or let the CLI start it)
./ollama voice llama3.2   # in another — speak after the tone, Ctrl-C to exit
```

Or inside a normal chat session:

```
./ollama run llama3.2
>>> /voice        # start talking
>>> /voice off    # back to the keyboard
```

## Configuration

The backends are plain HTTP services and can be repointed with environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `OLLAMA_VOICE_HOME` | `~/.ollama/voice` | Install/runtime directory |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Speech-to-text endpoint |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Text-to-speech endpoint |
| `TTS_ENGINE` | `supertonic` | TTS engine (`supertonic`, `neutts`, `xai`) |
| `VAD_THRESHOLD` | `0.5` | Mic speech-detection sensitivity |
| `TALK_IDLE_TIMEOUT_S` | `30` | Stop listening after N seconds of silence |
| `MIC_QUERY` | _(auto)_ | Substring to pick a specific microphone |

## Notes

- The `0001-ollama-voice.patch` targets `ollama/ollama` `main`. If upstream has moved and
  a hunk fails, apply with `git apply --3way` or re-base the change.
- This is a downstream patch, not part of upstream Ollama. It adds a Python/Bash (or
  PowerShell) runtime requirement for the speech backends.
