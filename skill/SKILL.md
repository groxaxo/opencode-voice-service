---
name: talk
description: >-
  Orchestrates VAD-driven voice conversation (Silero listen, Parakeet ONNX STT,
  Supertonic ONNX TTS with xAI cloud fallback). Use when the user says talk,
  voice, speak, habla, voz, audio, talk mode, or wants spoken back-and-forth.
  Also when they ask to read a reply aloud (say it, speak that). Triggers on voice,
  talk, speak, habla, audio, tts, stt.
---

# Talk — Voice Conversation

Load in OpenCode via `skill("talk")`. Codex uses the same skill at `~/.codex/skills/talk` (symlink).

**Default STT:** local Parakeet ONNX via `parakeet-tdt-0.6b-v3-fastapi-openai` on `127.0.0.1:5093` (auto-installed by `setup.sh`). OpenAI-compatible API, 25 languages, ~20x real-time on Apple Silicon.

**Default TTS:** **Supertonic ONNX** via `supertonic-express` on `:8766` (auto-installed by `setup.sh`). Falls back to **NeuTTS** (local GGUF, `:8020`) then **xAI** (cloud, `api.x.ai`, voice `eve`). macOS `say` is intentionally disabled. All engines have automatic fallback chains.

> **Port note:** Supertonic defaults to `:8766` (not `:8765`) so it can coexist
> with the existing Chatterbox TTS server on `:8765`. If a precompiled
> `speech-server` already runs on `:5093` for STT, setup.sh detects it and
> leaves the existing Parakeet plist untouched.

**Barge-in:** During TTS playback, the mic is monitored via VAD. If the user starts speaking, playback is interrupted and the system switches to listening. Controlled by `TALK_BARGE_IN` (default: 0 — opt-in, requires `TALK_BARGE_IN=1`). WARNING: requires echo cancellation or careful mic placement — TTS audio bleeding into the mic will trigger false interrupts. Test before enabling.

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
~/.config/opencode/skills/talk/talk.sh speak "…" # TTS (Supertonic local default → NeuTTS → xAI)
~/.config/opencode/skills/talk/talk.sh status    # health check (all backends)
~/.config/opencode/skills/talk/talk.sh devices   # list mics
~/.config/opencode/skills/talk/talk.sh loop      # continuous loop (tty or pipe stdin)
```

## Talk loop (you orchestrate)

When the user enters talk/voice mode:

1. **First turn only** — `talk.sh listen`. Stdout = first user utterance (may be empty → listen again).
2. **Think** — Reply to that text. Keep answers **short** for voice.
3. **Speak + listen** — `talk.sh speak '<reply>'` (escape single quotes). This plays TTS, then **opens the mic immediately** when audio ends. **Stdout = the user's next utterance** (same as `listen`).
4. **Loop** — Go to step 2 with the text from step 3. **Do not call `listen` separately** after `speak` (it is built in).

### Idle timeout

`listen` exits cleanly with empty stdout after `TALK_IDLE_TIMEOUT_S` seconds (default: 30) if no speech is detected.

### Rules

- Always invoke `talk.sh` via Shell; never fake transcription or audio.
- Empty stdout from `speak` (no speech detected) → `talk.sh listen` once, then continue.
- One-off read-aloud only (no mic): `TALK_AUTO_LISTEN=0 talk.sh speak '…'`.
- TTS down (all engines failed) → fix backends; do not use macOS `say`.
- First session turn: `talk.sh status` if services were recently restarted.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `STT_ENGINE` | `coreml` | STT backend (local Parakeet ONNX `:5093`) |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Parakeet ONNX endpoint |
| `TTS_ENGINE` | `supertonic` | `supertonic` (local ONNX), `neutts` (local GGUF), `xai` (cloud) |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Supertonic TTS endpoint (auto-installed) |
| `XAI_API_KEY` | (required) | API key for xAI TTS fallback |
| `XAI_TTS_VOICE` | `eve` | xAI voice: `ara`, `eve`, `leo`, `rex`, `sal` |
| `TALK_READY_CUE` | 1 | Play a short tone before `listen` |
| `TALK_READY_SOUND` | Tink.aiff | macOS system sound for ready cue |
| `TALK_READY_DELAY_MS` | 700 | Ignore mic after cue |
| `VAD_THRESHOLD` | 0.5 | Lower = more sensitive |
| `VAD_MIN_SILENCE_MS` | 500 | End-of-turn silence |
| `MIC_QUERY` | MacBook Air Microphone | Substring to select the mic |
| `TALK_AUTO_LISTEN` | `1` | After `speak`, run `listen` |
| `TALK_BARGE_IN` | `0` | Interrupt TTS on speech (opt-in) |
| `TALK_IDLE_TIMEOUT_S` | `30` | Exit listen if no speech (0=disabled) |

## Troubleshooting

| Problem | Action |
|---------|--------|
| No transcription | `talk.sh status` — check Parakeet ONNX on `:5093`. `launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt` |
| No TTS (Supertonic) | `talk.sh status` — check Supertonic ONNX on `:8766`. `launchctl kickstart -k gui/$UID/com.opencode.supertonic` |
| VAD misses speech | `talk.sh devices`; lower `VAD_THRESHOLD` |
| Wrong microphone | `talk.sh devices`; set `MIC_QUERY="MacBook Air Microphone"` |
| xAI TTS fails | Check `XAI_API_KEY` is set; `talk.sh status` shows key status |
| Listen blocks forever | Set `TALK_IDLE_TIMEOUT_S` (default 30s) |
| All TTS failed | Fix backends; macOS `say` is intentionally not used |
| Backends not running | Rerun `./setup.sh` to re-clone and re-install |
