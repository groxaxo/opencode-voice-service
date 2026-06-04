#!/bin/bash
# talk.sh — VAD-driven voice conversation orchestrator
#
# A complete voice conversation cycle in two commands:
#   talk.sh listen   → VAD record + STT → prints transcribed text
#   talk.sh speak    → xAI TTS, then auto-listen for next utterance (default)
#
# Depends on:
#   vad_recorder.py  (Silero VAD + sounddevice)
#   tts.sh           (xAI TTS default; Chatterbox optional)
#   Parakeet STT     (remote, http://100.85.200.51:5092)
#
# Usage:
#   talk.sh listen                  — record one utterance, transcribe, print text
#   talk.sh speak "text" [lang]     — speak via TTS (lang: en|es, auto-detected)
#   talk.sh loop                    — continuous conversation loop (standalone)
#   talk.sh status                  — check all services
#   talk.sh devices                 — list audio input devices

set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Configurable settings ---------------------------------------------------
# Python env (tts-venv with silero-vad, sounddevice, onnxruntime, torch)
: "${PYTHON:=}"  # auto-detect below
# TTS (xAI default — same API as OpenVoiceApp VoiceBridge)
: "${TTS_ENGINE:=xai}"
: "${XAI_TTS_VOICE:=eve}"
: "${TTS_ENABLE_CHATTERBOX_FALLBACK:=1}"
# Optional local Chatterbox (mlx-audio on :8765)
: "${TTS_SERVER:=http://localhost:8765}"
# STT endpoint (remote Parakeet)
: "${STT_URL:=http://100.85.200.51:5092/v1/audio/transcriptions}"
: "${STT_MODEL:=istupakov/parakeet-tdt-0.6b-v3-onnx}"
# VAD parameters (passed to vad_recorder.py)
: "${VAD_MIN_SILENCE_MS:=500}"
: "${VAD_THRESHOLD:=0.5}"
# Mic device selection
: "${MIC_QUERY:=MacBook}"
# Ready cue before listen (short tone so user knows when to speak)
: "${TALK_READY_CUE:=1}"
: "${TALK_READY_SOUND:=/System/Library/Sounds/Tink.aiff}"
: "${TALK_READY_DELAY_MS:=400}"
# After speak finishes playback, immediately start listen (stdout = next user text)
: "${TALK_AUTO_LISTEN:=1}"
# -----------------------------------------------------------------------------

# Auto-detect Python
if [ -z "$PYTHON" ]; then
    for p in ~/.config/opencode/tts-venv/bin/python3; do
        [ -x "$p" ] && { PYTHON="$p"; break; }
    done
    [ -z "$PYTHON" ] && PYTHON="python3"
fi

TTS_SH="${TTS_SH:-$HOME/.config/opencode/tts.sh}"
if [ ! -x "$TTS_SH" ]; then
    TTS_SH="$SERVICE_DIR/tts.sh"
fi
VAD_PY="$SERVICE_DIR/vad_recorder.py"

detect_lang() {
    local text="$1"
    if echo "$text" | LC_ALL=C grep -q '[áéíóúñü¿¡ÁÉÍÓÚÑÜ]'; then
        echo "es"
    else
        echo "en"
    fi
}

cmd_ready_cue() {
    [ "${TALK_READY_CUE}" = "0" ] && return 0
    if [ -f "$TALK_READY_SOUND" ]; then
        afplay "$TALK_READY_SOUND" 2>/dev/null || printf '\a'
    else
        printf '\a'
    fi
}

cmd_listen() {
    local outfile="${1:-opencode-utterance.wav}"
    local ready_delay=0
    [ "${TALK_READY_CUE}" != "0" ] && ready_delay="${TALK_READY_DELAY_MS}"

    cmd_ready_cue >&2

    # Run VAD recorder in oneshot mode, parse the last JSON line for the file path
    local file
    file=$("$PYTHON" "$VAD_PY" --oneshot \
        --mic-query "$MIC_QUERY" \
        --output-file "$outfile" \
        --vad-threshold "$VAD_THRESHOLD" \
        --min-silence-ms "$VAD_MIN_SILENCE_MS" \
        --ready-delay-ms "$ready_delay" \
        2>/dev/null | "$PYTHON" -c "
import json,sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if d.get('event') == 'speech_end':
            print(d.get('file',''))
    except: pass
")

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo ""
        exit 0
    fi

    # Transcribe via remote Parakeet STT
    local text
    text=$(curl -s "$STT_URL" \
        -F "file=@$file" \
        -F "model=$STT_MODEL" | "$PYTHON" -c "import json,sys; print(json.load(sys.stdin).get('text',''))" 2>/dev/null)

    echo "$text"
    rm -f "$file"
}

cmd_speak() {
    local text="$1"
    local lang="${2:-$(detect_lang "$text")}"
    TTS_ENGINE="$TTS_ENGINE" \
    XAI_TTS_VOICE="$XAI_TTS_VOICE" \
    TTS_ENABLE_CHATTERBOX_FALLBACK="$TTS_ENABLE_CHATTERBOX_FALLBACK" \
        bash "$TTS_SH" "$text" "$lang" \
        || say -v "Monica" "$text"

    # Pipeline: mic opens as soon as TTS ends so the user can talk while the
    # agent is still preparing the next LLM call.
    if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        echo "Listening for your reply…" >&2
        cmd_listen
    fi
}

cmd_loop() {
    echo "Talk loop — Ctrl+C to stop" >&2
    while true; do
        local text
        text=$(cmd_listen)
        if [ -n "$text" ]; then
            echo "" >&2
            echo "User: $text" >&2
            echo -n "Response: " >&2
            read -r response
            if [ -n "$response" ]; then
                TALK_AUTO_LISTEN=1 cmd_speak "$response"
            fi
        fi
    done
}

cmd_status() {
    echo "=== Audio Input Devices ==="
    "$PYTHON" "$VAD_PY" --list-devices 2>&1 | grep -v '^$'
    echo ""

    echo "=== TTS (engine=$TTS_ENGINE, xAI voice=$XAI_TTS_VOICE) ==="
    if [ "$TTS_ENGINE" = "xai" ] || [ "$TTS_ENGINE" = "grok" ]; then
        if [ -n "${XAI_API_KEY:-}" ] || grep -q '^XAI_API_KEY=' \
            "$HOME/Documents/IOSAPP/voice-bridge/.env" \
            "$HOME/.hermes/.env" \
            "$HOME/.config/opencode/.env" 2>/dev/null; then
            echo "  xAI API key: configured"
        else
            echo "  xAI API key: MISSING — set XAI_API_KEY or add to voice-bridge/.env"
        fi
        echo "  Chatterbox fallback: $([ "$TTS_ENABLE_CHATTERBOX_FALLBACK" = 1 ] && echo enabled || echo disabled)"
    fi
    echo "=== Chatterbox server ($TTS_SERVER, optional) ==="
    local tts_host
    tts_host=$(echo "$TTS_SERVER" | sed 's|http://||;s|/.*||')
    if nc -z -w 2 "${tts_host%:*}" "${tts_host#*:}" 2>/dev/null; then
        echo "  RUNNING"
    else
        echo "  NOT RUNNING (only needed for TTS_ENGINE=chatterbox or fallback)"
    fi
    echo ""

    echo "=== STT Server ($STT_URL) ==="
    local stt_host
    stt_host=$(echo "$STT_URL" | sed 's|http://||;s|/.*||')
    if nc -z -w 2 "${stt_host%:*}" "${stt_host#*:}" 2>/dev/null; then
        echo "  REACHABLE"
    else
        echo "  NOT REACHABLE"
    fi
    echo ""

    echo "=== Python Environment ==="
    echo "  Interpreter: $PYTHON"
    echo "  VAD: $VAD_PY"
    echo "  TTS: $TTS_SH"
    echo "  Auto-listen after speak: $([ "$TALK_AUTO_LISTEN" = 1 ] && echo yes || echo no)"
    "$PYTHON" -c "
import sounddevice as sd, torch, silero_vad
print('  sounddevice : OK')
print('  torch      :', torch.__version__)
print('  silero-vad :', silero_vad.__version__)
" 2>&1
}

cmd_devices() {
    "$PYTHON" "$VAD_PY" --list-devices
}

case "${1:-listen}" in
    listen|record|hear)
        cmd_listen "${2:-opencode-utterance.wav}"
        ;;
    speak|say|tts)
        shift
        cmd_speak "$@"
        ;;
    loop)
        cmd_loop
        ;;
    status|health)
        cmd_status
        ;;
    devices|mic|list-devices)
        cmd_devices
        ;;
    *)
        echo "Usage: talk.sh {listen|speak|loop|status|devices}" >&2
        exit 1
        ;;
esac
