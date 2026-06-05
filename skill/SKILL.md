---
name: talk
description: >-
  Orchestrates VAD-driven voice conversation (Silero listen, Parakeet STT,
  NeuTTS default with xAI cloud fallback). Use when the user says talk,
  voice, speak, habla, voz, audio, talk mode, or wants spoken back-and-forth.
  Also when they ask to read a reply aloud (say it, speak that). Triggers on voice,
  talk, speak, habla, audio, tts, stt.
---

# Talk — Voice Conversation

Load in OpenCode via `skill("talk")`. Codex uses the same skill at `~/.codex/skills/talk` (symlink).

**Default STT:** local Parakeet CoreML [`FluidInference/parakeet-tdt-0.6b-v3-coreml`](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) via `speech-server` on `127.0.0.1:5093` (ANE, offline).

**Default TTS:** **NeuTTS** (Neuphonic, local llama-cpp GGUF, `:8020`, launchd `com.op.neutts-server`). Lazy-loads Q8 models on first request, evicts after 5 min idle (~0.5 GB baseline). Falls back to **xAI** (`api.x.ai`, voice `eve`, model `grok-2-audio`) if NeuTTS fails. Also supports **Supertonic** (local CoreML, `:8765`, `TTS_ENGINE=supertonic`) as last-resort fallback. macOS `say` is intentionally disabled. Requires `XAI_API_KEY` env var for xAI fallback.

**Fallback chains:** NeuTTS→xAI→Supertonic | xAI→NeuTTS→VibeVoice→Supertonic | VibeVoice→NeuTTS→xAI→Supertonic | Supertonic→NeuTTS→xAI→Supertonic. All engines try to recover before failing.

**Barge-in:** During TTS playback, the mic is monitored via VAD. If the user starts speaking, playback is interrupted and the system switches to listening. Controlled by `TALK_BARGE_IN` (default: 1).

## Paths

| Role | Path |
|------|------|
| Orchestrator | `~/.config/opencode/skills/talk/talk.sh` |
| VAD engine | `~/.config/opencode/skills/talk/vad_recorder.py` |
| TTS CLI | `~/.config/opencode/tts.sh` |
| Lang / voice presets | `~/.config/opencode/tts_lang.sh` |

## Commands

```bash
~/.config/opencode/skills/talk/talk.sh listen    # block until user stops; print transcript
~/.config/opencode/skills/talk/talk.sh speak "…" # TTS (NeuTTS default → xAI fallback)
~/.config/opencode/skills/talk/talk.sh status    # health check
~/.config/opencode/skills/talk/talk.sh devices   # list mics
~/.config/opencode/skills/talk/talk.sh loop      # continuous loop (tty or pipe stdin)
```

## Talk loop (you orchestrate)

When the user enters talk/voice mode:

1. **First turn only** — `talk.sh listen`. Stdout = first user utterance (may be empty → listen again).
2. **Think** — Reply to that text. Keep answers **short** for voice.
3. **Speak + listen** — `talk.sh speak '<reply>'` (escape single quotes). This plays TTS, then **opens the mic immediately** when audio ends. **Stdout = the user's next utterance** (same as `listen`).
4. **Loop** — Go to step 2 with the text from step 3. **Do not call `listen` separately** after `speak` (it is built in).

This pipelines conversation: the user can start talking again while you prepare the next LLM request, because recording begins the moment your reply finishes playing.

### Idle timeout

`listen` exits cleanly with empty stdout after `TALK_IDLE_TIMEOUT_S` seconds (default: 30) if no speech is detected. This prevents indefinite blocking. Set `TALK_IDLE_TIMEOUT_S=0` to disable.

### Rules

- Always invoke `talk.sh` via Shell; never fake transcription or audio.
- Empty stdout from `speak` (no speech detected) → `talk.sh listen` once, then continue.
- One-off read-aloud only (no mic): `TALK_AUTO_LISTEN=0 talk.sh speak '…'`.
- TTS down (all engines failed) → fix NeuTTS/xAI; do not use macOS `say`.
- First session turn: `talk.sh status` if services were recently restarted.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `STT_ENGINE` | `coreml` | `coreml` or `remote`; both default to local `127.0.0.1:5093` |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Local CoreML STT |
| `STT_MODEL` | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | Model id for API |
| `STT_TIMEOUT_SECONDS` | `45` | Curl timeout for one STT request |
| `TTS_ENGINE` | `neutts` | `neutts` (default), `xai`, `vibevoice`, `supertonic` |
| `XAI_API_KEY` | (required) | API key for xAI TTS |
| `XAI_TTS_VOICE` | `eve` | xAI voice: `ara`, `eve`, `leo`, `rex`, `sal` |
| `XAI_TTS_MODEL` | `grok-2-audio` | xAI model for speech |
| `NEUTTS_URL` | `http://127.0.0.1:8020` | NeuTTS server |
| `NEUTTS_MODEL` | `neuphonic/neutts-nano-q4-gguf` | Default backbone (EN) |
| `NEUTTS_MODEL_ES` | `neuphonic/neutts-nano-spanish-q4-gguf` | Spanish backbone |
| `NEUTTS_PORT` | `8020` | NeuTTS server port |
| `NEUTTS_PRELOAD_MODELS` | `` (all lazy by default) | Space-separated models to preload at boot (empty = lazy) |
| `TALK_READY_CUE` | 1 | Play a short tone before `listen` (set `0` to disable) |
| `TALK_READY_SOUND` | Tink.aiff | macOS system sound for ready cue |
| `TALK_READY_DELAY_MS` | 400 | Ignore mic after cue so speech is not clipped |
| `VAD_THRESHOLD` | 0.5 | Lower = more sensitive |
| `VAD_MIN_SILENCE_MS` | 500 | End-of-turn silence |
| `MIC_QUERY` | MacBook Air Microphone | Substring to select the mic |
| `TALK_AUTO_LISTEN` | `1` | After `speak`, run `listen` and print next user text on stdout |
| `TALK_BARGE_IN` | `1` | Detect and interrupt TTS playback when user starts speaking |
| `TALK_IDLE_TIMEOUT_S` | `30` | Exit listen if no speech within N seconds (0=disabled) |

## Troubleshooting

| Problem | Action |
|---------|--------|
| No transcription | `talk.sh status` — includes a real WAV transcription self-test; if failed, `launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt` |
| Force alternate STT | Override `STT_URL` or `STT_REMOTE_URL`; default remains local `:5093` |
| VAD misses speech | `talk.sh devices`; lower `VAD_THRESHOLD` |
| Wrong microphone (e.g. NoMachine) | `talk.sh devices`; set `MIC_QUERY="MacBook Air Microphone"` |
| xAI TTS fails | Check `XAI_API_KEY` is set; `talk.sh status` shows key status, then NeuTTS is tried automatically |
| No NeuTTS speech | `talk.sh status` — API on :8020? `launchctl kickstart -k gui/$UID/com.op.neutts-server` |
| Listen blocks forever | Set `TALK_IDLE_TIMEOUT_S` (default 30s); check that mic is working with `talk.sh devices` |
| All TTS failed | Fix NeuTTS or xAI; macOS `say` is intentionally not used |
| Barge-in false triggers | Raise `VAD_THRESHOLD` (default 0.5); or set `TALK_BARGE_IN=0` to disable |
