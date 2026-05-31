#!/bin/bash
# talk.sh — VAD-driven voice conversation orchestrator
#
# A complete voice conversation cycle in two commands:
#   talk.sh listen   → VAD record + STT → prints transcribed text
#   talk.sh speak    → speaks text via local TTS
#
# Depends on:
#   vad_recorder.py  (Silero VAD + sounddevice)
#   tts.sh           (Chatterbox mlx-audio server)
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
# TTS server (local Chatterbox via mlx-audio)
: "${TTS_SERVER:=http://localhost:8765}"
# STT endpoint (remote Parakeet)
: "${STT_URL:=http://100.85.200.51:5092/v1/audio/transcriptions}"
: "${STT_MODEL:=istupakov/parakeet-tdt-0.6b-v3-onnx}"
# VAD parameters (passed to vad_recorder.py)
: "${VAD_MIN_SILENCE_MS:=500}"
: "${VAD_THRESHOLD:=0.5}"
# Mic device selection
: "${MIC_QUERY:=MacBook}"
# -----------------------------------------------------------------------------

# Auto-detect Python
if [ -z "$PYTHON" ]; then
    for p in ~/.config/opencode/tts-venv/bin/python3; do
        [ -x "$p" ] && { PYTHON="$p"; break; }
    done
    [ -z "$PYTHON" ] && PYTHON="python3"
fi

TTS_SH="$SERVICE_DIR/tts.sh"
VAD_PY="$SERVICE_DIR/vad_recorder.py"

detect_lang() {
    local text="$1"
    if echo "$text" | grep -qP '[áéíóúñü¿¡]'; then
        echo "es"
    else
        echo "en"
    fi
}

cmd_listen() {
    local outfile="${1:-opencode-utterance.wav}"

    # Run VAD recorder in oneshot mode, parse the last JSON line for the file path
    local file
    file=$("$PYTHON" "$VAD_PY" --oneshot \
        --mic-query "$MIC_QUERY" \
        --output-file "$outfile" \
        --vad-threshold "$VAD_THRESHOLD" \
        --min-silence-ms "$VAD_MIN_SILENCE_MS" \
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
    bash "$TTS_SH" "$text" "$lang"
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
                cmd_speak "$response"
            fi
        fi
    done
}

cmd_status() {
    echo "=== Audio Input Devices ==="
    "$PYTHON" "$VAD_PY" --list-devices 2>&1 | grep -v '^$'
    echo ""

    echo "=== TTS Server ($TTS_SERVER) ==="
    local tts_host
    tts_host=$(echo "$TTS_SERVER" | sed 's|http://||;s|/.*||')
    if nc -z -w 2 "${tts_host%:*}" "${tts_host#*:}" 2>/dev/null; then
        echo "  RUNNING"
    else
        echo "  NOT RUNNING — start with: launchctl load ~/Library/LaunchAgents/com.opencode.tts-server.plist"
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
