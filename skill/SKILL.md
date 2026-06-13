---
name: talk
description: >-
  Orchestrates VAD-driven voice conversation (Silero VAD listen, Parakeet ONNX STT,
  Supertonic ONNX TTS with xAI cloud fallback). All inference is CPU-only — no GPU required.
  Use when the user says talk, voice, speak, habla, voz, audio, talk mode, or wants
  spoken back-and-forth. Also when they ask to read a reply aloud (say it, speak that).
  Triggers on: voice, talk, speak, habla, audio, tts, stt.
---

# Talk — Voice Conversation (CPU-only local voice stack)

Works with **Claude Code**, **OpenCode CLI**, **OpenClaw**, **Hermes Agent**, and **Codex**.

Load via `skill("talk")` in any supported agent. The same `SKILL.md` is installed to
each agent's skills directory by `setup.sh` / `setup.ps1`.

| Agent | Skill path |
|-------|-----------|
| Claude Code  | `~/.claude/skills/talk/` |
| OpenCode CLI | `~/.config/opencode/skills/talk/` |
| OpenClaw     | `~/.openclaw/skills/talk/` |
| Hermes Agent | `~/.hermes/skills/talk/` |
| Codex        | `~/.codex/skills/talk/` |

**Default STT:** local Parakeet ONNX via `parakeet-tdt-0.6b-v3-fastapi-openai` on `127.0.0.1:5093` (auto-installed by `setup.sh` / `setup.ps1`). OpenAI-compatible API, 25 languages, CPU-only ONNX INT8.

**Default TTS:** **Supertonic 3 ONNX** via `supertonic-express-3` on `:8766` (auto-installed, FP16, CPU-only, voices F1–F5 / M1–M5). Falls back to **NeuTTS** (local GGUF, `:8020`) then **xAI** (cloud, `api.x.ai`, voice `eve`). `say`/TTS-system fallback intentionally disabled.

**Audio playback:** `afplay` (macOS), `ffplay`/`aplay`/`paplay` (Linux), `ffplay`/SoundPlayer (Windows via `talk.ps1`).

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

The session **persists** across natural pauses and stays open until the user explicitly cancels via one of three signals:

| Signal | Trigger | Empty stdout → agent exits loop |
|--------|---------|--------------------------------|
| Keyboard | `Ctrl+C` / `Cmd+D` (sent to `talk.sh`) | n/a — process killed |
| Session silence | No speech for `TALK_IDLE_TIMEOUT_S` (default 300s = 5 min) | yes |
| Spoken stop phrase | User says any phrase in `TALK_STOP_PHRASES` (default `"stop talk"`) | yes |

When you receive empty stdout from `talk.sh speak`, **exit the conversation loop** cleanly — the user has ended the session. Do not call `talk.sh listen` again to "recover"; respect the cancel.

### Idle timeout

`listen` exits cleanly with empty stdout after `TALK_IDLE_TIMEOUT_S` seconds (default: **300** = 5 min) if no speech is detected. This is the **session-silence window**: if the user walks away, the loop ends after 5 min of silence. Set `TALK_IDLE_TIMEOUT_S=0` to disable, or override per-session with e.g. `TALK_IDLE_TIMEOUT_S=1800 talk.sh speak …` for 30 min.

### Stop phrases

`TALK_STOP_PHRASES` is a pipe-separated list of phrases that end the session (case-insensitive substring match). Default: `"stop talk"`. Spanish: `TALK_STOP_PHRASES="stop talk|para de hablar"`. When matched, `cmd_listen` prints `"[talk] Stop phrase detected"` to stderr and empty stdout to the agent.

> **Caveat:** substring match is intentionally permissive — *"I want to stop talking now"* matches `"stop talk"`. For tighter control, use a longer phrase: `TALK_STOP_PHRASES="end the conversation"`. Word-boundary matching is a planned future improvement.

### Rules

- Always invoke `talk.sh` via Shell; never fake transcription or audio.
- **Empty stdout from `speak`** = user ended the session (stop phrase, silence timeout, or keyboard). Exit the conversation loop; do not retry `listen`.
- One-off read-aloud only (no mic): `TALK_AUTO_LISTEN=0 talk.sh speak '…'`.
- TTS down (all engines failed) → fix backends; do not use macOS `say`.
- First session turn: `talk.sh status` if services were recently restarted.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `STT_ENGINE` | `coreml` | STT backend (local Parakeet ONNX `:5093`) |
| `STT_URL` | `http://127.0.0.1:5093/v1/audio/transcriptions` | Parakeet ONNX endpoint |
| `TTS_ENGINE` | `supertonic` | `supertonic` (local ONNX), `neutts` (local GGUF), `xai` (cloud) |
| `SUPERTONIC_URL` | `http://127.0.0.1:8766` | Supertonic 3 TTS endpoint (auto-installed) |
| `SUPERTONIC_VOICE` | `F4` | Voice style `F1`–`F5` / `M1`–`M5` |
| `TTS_QUALITY` | `normal` | `normal` = 8 steps, `high` = 20 steps; `SUPERTONIC_STEPS=<1-20>` overrides |
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
| `TALK_IDLE_TIMEOUT_S` | `300` | Session-silence window: exit listen if no speech within N seconds (0=disabled, 300=5 min) |
| `TALK_STOP_PHRASES` | `stop talk` | Pipe-separated phrases that end the session (case-insensitive substring match) |

## Troubleshooting

| Problem | Action |
|---------|--------|
| No transcription | `talk.sh status` — check Parakeet ONNX on `:5093`. macOS: `launchctl kickstart -k gui/$UID/com.opencode.parakeet-stt`. Linux: `systemctl --user start opencode-parakeet-stt`. Windows: `Start-ScheduledTask 'OpenCode-Parakeet-STT'` |
| No TTS (Supertonic) | `talk.sh status` — check Supertonic ONNX on `:8766`. macOS: `launchctl kickstart -k gui/$UID/com.opencode.supertonic`. Linux: `systemctl --user start opencode-supertonic`. Windows: `Start-ScheduledTask 'OpenCode-Supertonic'` |
| VAD misses speech | `talk.sh devices`; lower `VAD_THRESHOLD` |
| Wrong microphone | `talk.sh devices`; set `MIC_QUERY` to your mic name substring |
| No audio on Linux | Install ffmpeg: `sudo apt install ffmpeg` or `sudo dnf install ffmpeg` |
| No audio on Windows | Install ffmpeg: `winget install Gyan.FFmpeg` |
| xAI TTS fails | Check `XAI_API_KEY` is set; `talk.sh status` shows key status |
| Listen blocks forever | Set `TALK_IDLE_TIMEOUT_S` (default 300s = 5 min); check that mic is working with `talk.sh devices` |
| Want to end the conversation | Speak any phrase in `TALK_STOP_PHRASES` (default `"stop talk"`), wait 5 min in silence, or send `Ctrl+C` to `talk.sh` |
| Agent keeps re-calling `listen` after cancel | Empty stdout from `talk.sh speak` means session ended — break out of the loop, do not retry `listen` |
| All TTS failed | Fix backends; system TTS fallback intentionally not used |
| Backends not running | Rerun `./setup.sh` (macOS/Linux) or `.\setup.ps1` (Windows) |
