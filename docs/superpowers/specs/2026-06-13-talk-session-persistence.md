# Talk Session Persistence — Design

**Date:** 2026-06-13
**Status:** Approved (brainstorming, Sections 1–4)
**Scope:** `~/.config/opencode/skills/talk/talk.sh` + `SKILL.md`

## Goal

Make `talk.sh` keep the conversation loop open until the user **explicitly**
cancels. Today, the 30-second `TALK_IDLE_TIMEOUT_S` and the agent's own
discipline are the only things keeping the loop alive — both fragile.

After this change, the loop exits only on:

1. **Keyboard** — `Ctrl+C` / `Cmd+D` (caught by `trap`).
2. **5 minutes of session silence** — bumped `TALK_IDLE_TIMEOUT_S` default
   (no speech at all in the last 5 min → `cmd_listen` returns empty stdout;
   the agent re-enters `talk.sh listen` to wait again, but if the user truly
   walked away, the next 5-min timeout ends the session).
3. **Spoken "stop talk"** — case-insensitive substring match against
   `TALK_STOP_PHRASES` (default `"stop talk"`); agent is informed via empty
   stdout and exits the conversation loop.

## Section 1 — Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Agent (LLM)                                                      │
│   while true:                                                    │
│     out = run("talk.sh speak '<reply>'")   # ← built-in listen    │
│     if out == "": break        # empty stdout = session ended    │
│     think(out)                                                    │
└──────────────────────────────────────────────────────────────────┘
                │                          ▲
                │ speak →                  │ next user text on stdout
                ▼                          │
┌──────────────────────────────────────────────────────────────────┐
│ talk.sh  (orchestrator)                                          │
│   cmd_speak(text):                                               │
│     1. TTS via tts.sh (Supertonic → NeuTTS → xAI)                │
│     2. if TALK_AUTO_LISTEN=1: cmd_listen  (auto-loops)           │
│                                                                  │
│   cmd_listen():                                                  │
│     1. Play ready cue                                            │
│     2. Run vad_recorder.py (idle-timeout = 5 min default)        │
│     3. Transcribe via Parakeet :5093                             │
│     4. is_stop_phrase(text)?  → print nothing, return 0          │
│        else                    → print text, return 0            │
└──────────────────────────────────────────────────────────────────┘
```

**Key insight:** the existing `TALK_AUTO_LISTEN=1` default already chains
`speak` → `listen`. The fix is *only* in `cmd_listen` — bump the timeout
and add the stop-phrase gate. The outer `while true` in the agent is
implicit: the agent keeps calling `talk.sh speak` until stdout is empty
(session ended).

**Why no Python changes:** `vad_recorder.py --idle-timeout-s` already
exists; the default just changes at the call site.

## Section 2 — Implementation

### Change 1: `talk.sh` line 97 — bump idle timeout default

```bash
: "${TALK_IDLE_TIMEOUT_S:=30}"
```

becomes

```bash
: "${TALK_IDLE_TIMEOUT_S:=300}"
```

(5 min). Users who want the old behavior set `TALK_IDLE_TIMEOUT_S=30`.

### Change 2: `talk.sh` after line 97 — add stop-phrases env var

```bash
# Spoken phrases that end the session (case-insensitive substring match,
# pipe-separated). Default: "stop talk". Spanish example: "para de hablar".
: "${TALK_STOP_PHRASES:=stop talk}"
```

### Change 3: `talk.sh` — new `is_stop_phrase()` function + call site

Add helper (sits next to `cmd_ready_cue`, ~line 200):

```bash
# True if $1 matches any of the | separated phrases in TALK_STOP_PHRASES
# (case-insensitive substring match).
is_stop_phrase() {
    local text="${1,,}"          # bash 4+ lowercase
    local phrase
    IFS='|' read -ra phrases <<< "${TALK_STOP_PHRASES,,}"
    for phrase in "${phrases[@]}"; do
        [ -z "$phrase" ] && continue
        [[ "$text" == *"$phrase"* ]] && return 0
    done
    return 1
}
```

Wire it into `cmd_listen` between the STT call and the `echo "$text"` at
line 260:

```bash
    if is_stop_phrase "$text"; then
        echo "[talk] Stop phrase detected: ending session" >&2
        rm -f "$file"
        echo ""           # empty stdout = session ended
        exit 0
    fi
    echo "$text"
    rm -f "$file"
```

### Verification

- `bash -n talk.sh` — syntax check, must pass.
- Unit-style test for `is_stop_phrase` (inline bash):
  ```bash
  TALK_STOP_PHRASES="stop talk|para de hablar" bash -c '
      source /Users/op/.config/opencode/skills/talk/talk.sh 2>/dev/null
      is_stop_phrase "ok Stop Talk everyone"   && echo PASS || echo FAIL
      is_stop_phrase "para de hablar ya"       && echo PASS || echo FAIL
      is_stop_phrase "i would like to talk"    && echo FAIL || echo PASS
  '
  ```
  *(note: `source` will execute the orchestrator's `case` dispatch since
  talk.sh has no `main`-style guard; a proper test calls the function
  via a sub-shell with the case blocked, or via a test harness that
  sources just the function. See test plan below.)*
- Live smoke: `TALK_STOP_PHRASES="stop talk" talk.sh listen` then say
  "stop talk" — expect empty stdout + "Stop phrase detected" on stderr.
- Live smoke: 5-min silence in `cmd_listen` — expect empty stdout.
- Live smoke: `Ctrl+C` during `cmd_listen` — expect script exit, no
  zombie processes.

## Section 3 — Error Handling

| Failure                    | Behavior                                                | Change?         |
|----------------------------|---------------------------------------------------------|-----------------|
| STT returns empty          | `text=""` → no stop-phrase match → empty stdout → loop   | None (resilient) |
| VAD recorder crash         | empty stdout, falls through to next `cmd_listen`        | None            |
| Agent / LLM crash          | empty response, skip TTS, fall through to listen        | None            |
| TTS engine failure         | `tts.sh` returns nonzero; agent sees empty stdout       | Verify in test  |
| Stop-phrase false positive | *"I want to stop talking now"* → matches `"stop talk"`  | Document caveat |
| Subprocess cleanup on exit | `trap cleanup EXIT INT TERM` (already present)          | Verify          |
| macOS SIGINT to subprocess | Bash `wait` propagates; children reaped                 | Verify          |

**TTS failure wrapper** (~2 lines, optional safety): if `tts.sh` returns
nonzero, `cmd_speak` should not crash. Existing `set -e` at line 20
already exits on any failure. Wrap the TTS call:

```bash
if ! bash "$TTS_SH" "$text" "$lang"; then
    echo "[talk] TTS failed, ending session" >&2
    exit 1
fi
```

This converts TTS failure into a clean exit-with-error rather than a
silent crash.

## Section 4 — SKILL.md Updates

| Section | Change |
|---------|--------|
| Header  | Note that "session persists until cancel" |
| Talk loop (step 4) | Document 3 cancel signals: 5-min silence, spoken stop phrase, keyboard |
| Idle timeout | Update default from 30 → 300; mention it's now the session-silence window |
| New env var | Add `TALK_STOP_PHRASES` to the table |
| New troubleshooting row | "Loop never ends" → set `TALK_IDLE_TIMEOUT_S` or speak stop phrase |
| Caveat | "Stop phrase uses substring match — phrases like *'I want to stop talking'* may match. Use `TALK_STOP_PHRASES='end session'` for tighter control." |

## Non-Goals

- Word-boundary stop-phrase matching (future improvement).
- A `talk.sh loop` agent-friendly mode that handles the LLM call in-shell
  (existing `cmd_loop` does this for tty but skips the agent's tool
  layer; out of scope).
- Per-phrase TTS engine selection (out of scope).
- Multi-language stop-phrase list as separate env var (single
  pipe-separated `TALK_STOP_PHRASES` is sufficient for v1).

## Rollout

1. Write design doc (this file).
2. Edit `talk.sh` (3 changes, ~12 lines added).
3. Edit `SKILL.md` (~10 line changes).
4. Run `bash -n talk.sh` to verify syntax.
5. Run an inline `is_stop_phrase` smoke test.
6. Live smoke: speak "stop talk" and confirm session ends.
7. Commit on a feature branch; report.
