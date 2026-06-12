# Ollama voice integration

Talk to your local [Ollama](https://github.com/ollama/ollama) models and hear them reply —
a **local, CPU-only** voice interface built on the `opencode-voice-service` speech stack
(Silero VAD → Parakeet STT → Supertonic TTS). All speech inference runs on the CPU; the
GPU stays free for the model that's actually thinking.

There are two ways to install it. **Most people want Option A.**

| | Option A — `ollama-voice` command | Option B — native `ollama voice` subcommand |
|---|---|---|
| Ollama | uses your **already-installed** binary | **rebuilds** Ollama from source (Go 1.26+) |
| Install | `bash install.sh` (autoinstaller) | clone → `git am` patch → `go build` |
| Talks via | Ollama HTTP API (`:11434`), like `ollama run` | in-process Ollama API client |
| Command | `ollama-voice <model>` | `ollama voice <model>` + `/voice` in the REPL |
| Best for | anyone with a normal Ollama install | distributing a custom Ollama build |

---

## Option A — autoinstaller (recommended, no rebuild)

Wires the voice stack into the Ollama you already have. It installs a small `ollama-voice`
command that drives the **listen → chat → speak** loop against Ollama's HTTP API — so any
model you can `ollama run`, you can `ollama-voice`.

### Install

```bash
# from this repo's root
bash integrations/ollama/install.sh
```

The installer:

1. Verifies the stock `ollama` binary is present (it does **not** rebuild it).
2. Installs the CPU speech backends — Parakeet STT (`:5093`) and Supertonic TTS (`:8766`) —
   by delegating to the repo's `setup.sh`. **Skipped automatically** if they're already
   installed and healthy.
3. Installs the `ollama-voice` command onto your `PATH` (`~/.local/bin` by default).
4. Smoke-checks Ollama + both backends and prints how to start talking.

Flags: `--yes` (no prompts) · `--bindir DIR` · `--model NAME` (ensure a model is pulled) ·
`--skip-backends` · `--reinstall-backends` · `--uninstall [--backends]`.

**Prerequisites:** an installed Ollama (`ollama --version`), `python3`, `bash`, `curl`, and
an audio player (`afplay` on macOS; `ffplay`/`aplay`/`paplay` on Linux). The speech backends
themselves are installed for you in step 2.

### Talk to a model

```bash
ollama-voice                 # talk to your default model (speak after the tone)
ollama-voice llama3.2        # talk to a specific model (pulled if missing)
ollama-voice --text          # type instead of speaking (mic-free test; replies still spoken)
ollama-voice --once          # one exchange, then exit
ollama-voice --list          # list local Ollama models
ollama-voice --status        # check Ollama + STT/TTS backends
# Ctrl-C to leave the conversation. Say "goodbye"/"exit"/"adiós" to end by voice.
```

Want the `ollama voice <model>` ergonomics without rebuilding? Add a shell function that
intercepts the `voice` verb and passes everything else through to the real CLI:

```bash
ollama() { [ "$1" = voice ] && { shift; command ollama-voice "$@"; } || command ollama "$@"; }
```

### How it works

```
  mic ─▶ Silero VAD ─▶ Parakeet STT     (talk.sh listen, :5093, local ONNX/CPU)
                            │
                            ▼
                  Ollama  POST /api/chat (:11434)   ← your installed ollama, streamed
                            │   (full conversation history; chain-of-thought is never spoken)
                            ▼
            Supertonic TTS  (talk.sh speak, :8766) ─▶ playback ─▶ listen again
```

`ollama-voice` is a thin orchestrator: it shells out to the same `talk.sh` the rest of the
project uses for STT/TTS, and calls Ollama's streaming chat API in between — the exact shape
of the upstream `ollama voice` Go command (Option B), minus the rebuild.

### Configuration

`ollama-voice` reads these (and forwards all the usual `talk.sh` variables — `VAD_THRESHOLD`,
`MIC_QUERY`, `TTS_ENGINE`, `SUPERTONIC_VOICE`, `TALK_IDLE_TIMEOUT_S`, …):

| Variable | Default | Description |
| --- | --- | --- |
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | Ollama endpoint |
| `OLLAMA_VOICE_MODEL` | _(first installed)_ | default model when none is given |
| `OLLAMA_VOICE_THINK` | `false` | `false`/`true`/`high`/`medium`/`low`/`default`. Reasoning is **never spoken**; `false` also skips it for snappier replies |
| `OLLAMA_VOICE_SYSTEM` | _(concise spoken-style prompt)_ | system prompt; set empty to use the model's own |
| `OLLAMA_VOICE_LANG` | _(auto)_ | TTS language hint: `en` / `es` / `""` |
| `OLLAMA_VOICE_KEEPALIVE` | _(server default)_ | keep the model warm between turns, e.g. `10m` |
| `OLLAMA_VOICE_NUM_PREDICT` | _(model default)_ | cap reply length in tokens |
| `TALK_SH` | _(installed copy)_ | path to `talk.sh` if not in the standard location |

**Keeping TTS fully local:** the voice reply is synthesized by `talk.sh`/`tts.sh`, whose
default engine is local **Supertonic** with a fallback chain to **xAI** (cloud) if a local
engine can't synthesize. If you have `XAI_API_KEY` set and the local Supertonic server isn't
answering, you'll hear the cloud voice. For local-only output, make sure the Supertonic
server on `:8766` is healthy (`bash ~/.config/opencode/skills/talk/talk.sh status`) and
optionally `unset XAI_API_KEY` for that session.

### Uninstall

```bash
bash integrations/ollama/install.sh --uninstall            # remove the ollama-voice command
bash integrations/ollama/install.sh --uninstall --backends # also remove Parakeet/Supertonic
```

### Files

| File | Purpose |
| --- | --- |
| `install.sh` | autoinstaller (Option A) — verifies Ollama, installs backends + command |
| `ollama-voice` | the runtime `listen → chat → speak` loop (Python; talks to Ollama's HTTP API) |
| `0001-ollama-voice.patch` | the source patch for Option B (native subcommand) |

---

## Option B — native `ollama voice` subcommand (build from source)

This patch adds a first-class `voice` subcommand **inside** Ollama. Use it only if you want
to build and distribute a custom Ollama binary; it requires a full Go toolchain and replaces
your installed binary with your build.

After applying it, Ollama gains:

- **`ollama voice <model>`** — a hands-free spoken conversation loop
- **`/voice`** — a toggle inside the `ollama run` REPL to switch a session to speech
- **`ollama voice --setup`** — installs and starts the local speech backends

The patch adds a `voice/` Go package (with the Bash/PowerShell/Python speech scripts embedded
via `go:embed`), a `cmd/voice.go` subcommand, a `/voice` toggle in `cmd/interactive.go`, and
`docs/voice.md`. Ollama only orchestrates the loop; it reuses its existing chat API.

### Prerequisites

- **Go 1.26+** and a working Ollama build toolchain (see Ollama's `docs/development.md`)
- **git**, **python 3.10+** on your `PATH`
- An audio player: `afplay` (macOS), `ffplay`/`aplay`/`paplay` (Linux), built-in (Windows)

### 1. Apply the patch to an Ollama checkout

```bash
git clone https://github.com/ollama/ollama.git
cd ollama

# with git am (keeps the commit), from this repo:
git am /path/to/integrations/ollama/0001-ollama-voice.patch
# …or a plain apply:
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

`--setup` is an **interactive installer**: it detects your OS/GPU, proposes an acceleration
backend, and lets you pick. It installs everything under `~/.ollama/voice/` (override with
`OLLAMA_VOICE_HOME`): the Parakeet STT server on `:5093` and the Supertonic TTS server on
`:8766`, and registers auto-start units — **systemd `--user`** on Linux, **launchd** on
macOS, **Task Scheduler** on Windows.

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

### Configuration (Option B)

| Variable | Default | Description |
| --- | --- | --- |
| `OLLAMA_VOICE_HOME` | `~/.ollama/voice` | Install/runtime directory |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Speech-to-text endpoint |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Text-to-speech endpoint |
| `TTS_ENGINE` | `supertonic` | TTS engine (`supertonic`, `neutts`, `xai`) |
| `VAD_THRESHOLD` | `0.5` | Mic speech-detection sensitivity |
| `TALK_IDLE_TIMEOUT_S` | `30` | Stop listening after N seconds of silence |
| `MIC_QUERY` | _(auto)_ | Substring to pick a specific microphone |

### Notes

- The `0001-ollama-voice.patch` targets `ollama/ollama` `main`. If upstream has moved and a
  hunk fails, apply with `git apply --3way` or re-base the change.
- This is a downstream patch, not part of upstream Ollama. It adds a Python/Bash (or
  PowerShell) runtime requirement for the speech backends.
