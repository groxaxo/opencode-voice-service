---
name: talk
description: >-
  Orchestrates VAD-driven voice conversation (Silero listen, Parakeet STT,
  xAI TTS on macOS; Chatterbox optional). Use when the user says talk, voice,
  speak, habla, voz, audio, talk mode, or wants spoken back-and-forth. Also
  when they ask to read a reply aloud (say it, speak that). Triggers on voice,
  talk, speak, habla, audio, tts, stt.
---

# Talk — Voice Conversation

**Default TTS:** xAI (`voice_id` **eve**, `language` **auto**) — same API as OpenVoiceApp `VoiceBridge`. **Chatterbox** (local mlx-audio on `:8765`) is optional via `TTS_ENGINE=chatterbox` or automatic fallback when xAI fails.

## Paths

| Role | Path |
|------|------|
| Orchestrator | `~/.config/opencode/skills/talk/talk.sh` |
| VAD engine | `~/.config/opencode/skills/talk/vad_recorder.py` |
| TTS CLI | `~/.config/opencode/tts.sh` |

## Commands

```bash
~/.config/opencode/skills/talk/talk.sh listen    # block until user stops; print transcript
~/.config/opencode/skills/talk/talk.sh speak "…" # TTS (xAI default)
~/.config/opencode/skills/talk/talk.sh status    # health check
~/.config/opencode/skills/talk/talk.sh devices   # list mics
```

## Talk loop (you orchestrate)

When the user enters talk/voice mode:

1. **Listen** — Shell: `~/.config/opencode/skills/talk/talk.sh listen`. Stdout = user utterance (may be empty).
2. **Think** — Reply to that text as a normal message. Keep answers short for voice.
3. **Speak** — Shell: `~/.config/opencode/skills/talk/talk.sh speak '<reply>'` (escape single quotes in the reply).
4. **Loop** — Run `listen` again immediately; do not wait for typed input between turns.

### Rules

- Always invoke `talk.sh` via Shell; never fake transcription or audio.
- Empty `listen` → run `listen` again.
- TTS down (xAI + optional Chatterbox) → `say -v "Monica" '<reply>'`.
- First turn in a session: run `talk.sh status` if services were recently restarted.
- One-off read-aloud: `talk.sh speak` or `~/.config/opencode/tts.sh "…"`.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `TTS_ENGINE` | `xai` | `xai` (default) or `chatterbox` for local mlx-audio |
| `XAI_TTS_VOICE` | `eve` | xAI voice: `ara`, `eve`, `leo`, `rex`, `sal` |
| `XAI_API_KEY` | (from `.env`) | Bearer token; else read from `voice-bridge/.env` or `~/.hermes/.env` |
| `TTS_ENABLE_CHATTERBOX_FALLBACK` | `1` | If xAI fails, try local Chatterbox before `say` |
| `TALK_READY_CUE` | 1 | Play a short tone before `listen` (set `0` to disable) |
| `TALK_READY_SOUND` | Tink.aiff | macOS system sound for ready cue |
| `TALK_READY_DELAY_MS` | 400 | Ignore mic after cue so speech is not clipped |
| `VAD_THRESHOLD` | 0.5 | Lower = more sensitive |
| `VAD_MIN_SILENCE_MS` | 500 | End-of-turn silence |
| `MIC_QUERY` | MacBook | Mic name substring |

## Troubleshooting

| Problem | Action |
|---------|--------|
| No transcription | `talk.sh status` — STT reachable? |
| VAD misses speech | `talk.sh devices`; lower `VAD_THRESHOLD` |
| No xAI speech | `talk.sh status` — API key set? Try `tts.sh "test"` |
| Force Chatterbox | `TTS_ENGINE=chatterbox talk.sh speak "hola"` |
| Disable fallback | `TTS_ENABLE_CHATTERBOX_FALLBACK=0` |
