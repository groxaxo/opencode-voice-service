#!/bin/bash
# talk.sh — VAD-driven voice conversation orchestrator
#
# A complete voice conversation cycle in two commands:
#   talk.sh listen   → VAD record + STT → prints transcribed text
#   talk.sh speak    → TTS (NeuTTS default, xAI/VibeVoice/Supertonic fallback), then auto-listen
#
# Depends on:
#   vad_recorder.py  (Silero VAD + sounddevice)
#   tts.sh           (NeuTTS / xAI / VibeVoice / Supertonic)
#   Parakeet STT     (local CoreML default :5093)
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
# TTS (Supertonic local default, NeuTTS → xAI cloud fallback chain)
# Supertonic is auto-installed by setup.sh on :8766 (or :8765 if forced).
# Fallback to NeuTTS (local GGUF, :8020) then xAI (cloud, requires XAI_API_KEY).
: "${TTS_ENGINE:=supertonic}"
: "${XAI_TTS_VOICE:=rex}"
: "${VIBEVOICE_MODEL:=vibe-realtime-8bit}"
: "${VIBEVOICE_VOICE:=en-Emma_woman}"
: "${VIBEVOICE_VOICE_AUTO:=1}"
: "${VIBEVOICE_CFG_SCALE:=2.0}"
: "${VIBEVOICE_DDPM_STEPS:=15}"
export TTS_ENGINE
# STT: local Parakeet CoreML (FluidInference/parakeet-tdt-0.6b-v3-coreml via speech-server)
: "${STT_ENGINE:=coreml}"   # coreml | remote; both default to local :5093 unless env overrides
: "${STT_URL:=http://127.0.0.1:5093/v1/audio/transcriptions}"
: "${STT_MODEL:=FluidInference/parakeet-tdt-0.6b-v3-coreml}"
: "${STT_REMOTE_URL:=http://127.0.0.1:5093/v1/audio/transcriptions}"
: "${STT_REMOTE_MODEL:=FluidInference/parakeet-tdt-0.6b-v3-coreml}"
# VAD parameters (passed to vad_recorder.py)
: "${VAD_MIN_SILENCE_MS:=500}"
: "${VAD_THRESHOLD:=0.5}"
# Mic device selection
# Default targets the built-in mic and the find_mic() logic explicitly
# excludes "nomachine" (and other virtual adapters).
: "${MIC_QUERY:=MacBook Air Microphone}"
# Ready cue before listen (short tone so user knows when to speak)
: "${TALK_READY_CUE:=1}"
: "${TALK_READY_SOUND:=/System/Library/Sounds/Tink.aiff}"
: "${TALK_READY_DELAY_MS:=700}"
# After speak finishes playback, immediately start listen (stdout = next user text)
: "${TALK_AUTO_LISTEN:=1}"
# Barge-in: detect user speech during TTS playback and interrupt
# WARNING: requires echo cancellation or careful mic placement — TTS audio
# bleeding into the mic will trigger false interrupts. Test before enabling.
: "${TALK_BARGE_IN:=0}"
# Grace period (ms) before barge-in VAD activates after TTS playback starts
# Prevents the VAD from triggering on the initial TTS audio burst
: "${TALK_BARGE_IN_DELAY_MS:=2000}"
# Idle timeout: exit listen if no speech detected within N seconds (0=disabled)
: "${TALK_IDLE_TIMEOUT_S:=30}"
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

TTS_LANG_SH="${TTS_LANG_SH:-$HOME/.config/opencode/tts_lang.sh}"
# shellcheck source=/dev/null
[ -f "$TTS_LANG_SH" ] && . "$TTS_LANG_SH"

resolve_stt() {
    if [ "${STT_ENGINE}" = "remote" ]; then
        printf '%s\n%s\n' "${STT_REMOTE_URL:-$STT_URL}" "${STT_REMOTE_MODEL:-$STT_MODEL}"
    else
        printf '%s\n%s\n' "$STT_URL" "$STT_MODEL"
    fi
}

transcribe_file() {
    local file="$1"
    local stt_url="$2"
    local stt_model="$3"
    local response_file http_code

    response_file="$(mktemp /tmp/opencode-stt-response.XXXXXX.json)"
    http_code=$(curl -sS -m "${STT_TIMEOUT_SECONDS:-45}" \
        -o "$response_file" \
        -w '%{http_code}' \
        "$stt_url" \
        -F "file=@$file" \
        -F "model=$stt_model") || {
        local curl_status=$?
        echo "STT request failed (curl exit $curl_status): $stt_url" >&2
        rm -f "$response_file"
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "STT request failed (HTTP $http_code): $stt_url" >&2
        sed -n '1,12p' "$response_file" >&2
        rm -f "$response_file"
        return 1
    fi

    local parse_status=0
    "$PYTHON" - "$response_file" <<'PY' || parse_status=$?
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
except Exception as exc:
    print(f"STT response was not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if isinstance(payload, dict):
    text = payload.get("text")
    if isinstance(text, str):
        print(text)
        sys.exit(0)
    error = payload.get("error")
    if error:
        print(f"STT error: {error}", file=sys.stderr)
        sys.exit(1)

print(f"STT response did not contain a text field: {payload!r}", file=sys.stderr)
sys.exit(1)
PY
    rm -f "$response_file"
    return "$parse_status"
}

detect_lang() {
    local text="$1"
    if [ -f "$TTS_LANG_SH" ]; then
        resolve_lang "" "$text"
    elif echo "$text" | LC_ALL=C grep -q '[áéíóúñü¿¡ÁÉÍÓÚÑÜ]'; then
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

    # Start VAD recorder BEFORE the ready cue so audio is captured
    # from the moment the user hears the cue. --ready-delay-ms keeps
    # VAD from triggering on cue bleed; ring buffer captures everything.
    local vad_out
    vad_out=$(mktemp /tmp/opencode-vad-output.XXXXXX)

    "$PYTHON" "$VAD_PY" --oneshot \
        --mic-query "$MIC_QUERY" \
        --output-file "$outfile" \
        --vad-threshold "$VAD_THRESHOLD" \
        --min-silence-ms "$VAD_MIN_SILENCE_MS" \
        --ready-delay-ms "$ready_delay" \
        --idle-timeout-s "${TALK_IDLE_TIMEOUT_S:-30}" \
        2>/dev/null >"$vad_out" &
    local vad_pid=$!

    # Play the ready cue NOW — vad_recorder is already capturing
    cmd_ready_cue >&2

    # Wait for VAD to finish (speech_end, idle_timeout, or error)
    wait "$vad_pid"

    # Parse the JSON output for the WAV file path
    local file
    file=$("$PYTHON" -c "
import json
with open('$vad_out') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
            if d.get('event') == 'speech_end':
                print(d.get('file',''))
        except: pass
    ")
    rm -f "$vad_out"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo ""
        exit 0
    fi

    # Transcribe (local CoreML Parakeet by default)
    local stt_info stt_url stt_model text
    stt_info="$(resolve_stt)"
    stt_url="$(printf '%s\n' "$stt_info" | sed -n '1p')"
    stt_model="$(printf '%s\n' "$stt_info" | sed -n '2p')"
    if ! text=$(transcribe_file "$file" "$stt_url" "$stt_model"); then
        rm -f "$file"
        return 1
    fi

    echo "$text"
    rm -f "$file"
}

cmd_speak() {
    local text="$1"
    local lang="${2:-$(detect_lang "$text")}"

    if [ "${TALK_BARGE_IN}" = "1" ] && [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        # Barge-in mode: generate TTS, play with background monitoring
        if _speak_with_barge_in "$text" "$lang"; then
            return 0
        fi
        echo "[talk] Barge-in failed, falling back to simple mode" >&2
    fi

    # Simple mode: TTS generates + plays, then listen
    TTS_ENGINE="$TTS_ENGINE" \
    VIBEVOICE_MODEL="${VIBEVOICE_MODEL:-vibe-realtime-8bit}" \
    VIBEVOICE_VOICE="${VIBEVOICE_VOICE:-en-Emma_woman}" \
    VIBEVOICE_VOICE_AUTO="${VIBEVOICE_VOICE_AUTO:-1}" \
    VIBEVOICE_CFG_SCALE="${VIBEVOICE_CFG_SCALE:-2.0}" \
    VIBEVOICE_DDPM_STEPS="${VIBEVOICE_DDPM_STEPS:-15}" \
    VIBEVOICE_WS_URI="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}" \
        bash "$TTS_SH" "$text" "$lang"

    if [ "${TALK_AUTO_LISTEN}" = "1" ]; then
        echo "Listening for your reply…" >&2
        cmd_listen
    fi
}

_speak_with_barge_in() {
    local text="$1"
    local lang="$2"
    local wav_file=""

    # Step 1: Generate TTS without playing (get WAV path)
    wav_file=$(TTS_NO_PLAY=1 \
        TTS_ENGINE="$TTS_ENGINE" \
        VIBEVOICE_MODEL="${VIBEVOICE_MODEL:-vibe-realtime-8bit}" \
        VIBEVOICE_VOICE="${VIBEVOICE_VOICE:-en-Emma_woman}" \
        VIBEVOICE_VOICE_AUTO="${VIBEVOICE_VOICE_AUTO:-1}" \
        VIBEVOICE_CFG_SCALE="${VIBEVOICE_CFG_SCALE:-2.0}" \
        VIBEVOICE_DDPM_STEPS="${VIBEVOICE_DDPM_STEPS:-15}" \
        VIBEVOICE_WS_URI="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}" \
            bash "$TTS_SH" "$text" "$lang" 2>/dev/null) || {
        # TTS generation failed, fall back to simple mode
        echo "[talk] TTS generation failed" >&2
        return 1
    }

    if [ -z "$wav_file" ] || [ ! -f "$wav_file" ]; then
        echo "[talk] TTS produced no audio file" >&2
        return 1
    fi

    # Step 2: Start playback in background
    afplay "$wav_file" &
    local play_pid=$!

    # Step 3: Start barge-in VAD monitor in parallel
    local barge_result=""
    barge_result=$("$PYTHON" "$VAD_PY" --barge-in \
        --mic-query "$MIC_QUERY" \
        --vad-threshold "$VAD_THRESHOLD" \
        --ready-delay-ms "${TALK_BARGE_IN_DELAY_MS:-2000}" \
        --idle-timeout-s "0" \
        2>/dev/null) &
    local vad_pid=$!

    # Step 4: Wait for either to finish
    # Poll both PIDs until one exits
    local interrupted=0
    while true; do
        if ! kill -0 "$play_pid" 2>/dev/null; then
            # Playback finished naturally
            interrupted=0
            break
        fi
        if ! kill -0 "$vad_pid" 2>/dev/null; then
            # VAD detected speech (barge-in!)
            interrupted=1
            break
        fi
        sleep 0.05
    done

    # Step 5: Clean up
    if [ "$interrupted" = "1" ]; then
        # User spoke — kill playback
        kill "$play_pid" 2>/dev/null
        wait "$play_pid" 2>/dev/null
        echo "[talk] Barge-in detected, interrupting playback" >&2
    else
        # Playback finished — kill VAD monitor
        kill "$vad_pid" 2>/dev/null
        wait "$vad_pid" 2>/dev/null
    fi

    # Cleanup WAV file
    rm -f "$wav_file"

    # Step 6: Start listening for the user's utterance
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
            # Support both interactive (tty) and piped (agent) stdin
            local response=""
            if [ -t 0 ]; then
                # Interactive terminal: read from keyboard
                read -r response
            else
                # Piped stdin (from agent): read next line
                IFS= read -r response || break
            fi
            if [ -n "$response" ]; then
                TALK_AUTO_LISTEN=1 cmd_speak "$response"
            fi
        fi
    done
}

stt_memory_stats() {
    local parakeet_dir="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
    if [ -d "$parakeet_dir" ]; then
        echo "  Model on disk (compiled CoreML): $(du -sh "$parakeet_dir" 2>/dev/null | awk '{print $1}')"
    else
        echo "  Model on disk: not found (first STT run will download)"
    fi

    local hf_cache="$HOME/.cache/huggingface/hub/models--FluidInference--parakeet-tdt-0.6b-v3-coreml"
    if [ -d "$hf_cache" ]; then
        echo "  HF cache (duplicate, safe to delete): $(du -sh "$hf_cache" 2>/dev/null | awk '{print $1}')"
    else
        echo "  HF cache: not present"
    fi

    local pocket_cache="$HOME/.cache/fluidaudio"
    if [ -d "$pocket_cache" ]; then
        echo "  fluidaudio cache (PocketTTS, optional): $(du -sh "$pocket_cache" 2>/dev/null | awk '{print $1}')"
    fi

    local stt_pid
    stt_pid=$(pgrep -f '/Users/op/bin/speech-server' | head -1)
    if [ -z "$stt_pid" ]; then
        echo "  speech-server: not running"
        return 0
    fi

    echo "  speech-server PID: $stt_pid"
    ps -p "$stt_pid" -o rss=,%cpu= 2>/dev/null | awk '{printf "  ps RSS (app only): %.0f MB  CPU: %s%%\n", $1/1024, $2}'
    if command -v footprint >/dev/null 2>&1; then
        footprint "$stt_pid" 2>/dev/null | awk '
            /Footprint:/ { sub(/^.*Footprint: /,""); fp=$0 }
            /phys_footprint:/ && !/peak/ { phys=$2" "$3 }
            /phys_footprint_peak:/ { phys_peak=$2" "$3 }
            /neural_peak:/ { neural=$2" "$3 }
            END {
                if (fp) printf "  footprint total: %s\n", fp
                if (phys) printf "  phys footprint (dirty app RAM): %s\n", phys
                if (phys_peak) printf "  phys footprint peak: %s\n", phys_peak
                if (neural) printf "  neural_peak (CoreML/ANE model): %s\n", neural
            }'
    fi
}

cmd_status() {
    echo "=== Audio Input Devices ==="
    "$PYTHON" "$VAD_PY" --list-devices 2>&1 | grep -v '^$'
    echo ""
    echo "=== Selected Microphone (MIC_QUERY=${MIC_QUERY:-<default>}) ==="
    "$PYTHON" "$VAD_PY" --print-selected-mic --mic-query "${MIC_QUERY:-MacBook Air Microphone}" 2>&1 || echo "(selection failed)"
    echo ""

    echo "=== TTS (engine=$TTS_ENGINE) ==="
    if [ "$TTS_ENGINE" = "xai" ]; then
        echo "  xAI voice: ${XAI_TTS_VOICE:-eve}"
        echo "  xAI model: ${XAI_TTS_MODEL:-grok-2-audio}"
        echo "  API key: $([ -n "${XAI_API_KEY:-}" ] && echo 'set' || echo 'NOT SET')"
        echo "  Fallback: VibeVoice only; macOS say disabled"
    elif [ "$TTS_ENGINE" = "vibevoice" ] || [ "$TTS_ENGINE" = "vibe" ] || [ "$TTS_ENGINE" = "mlx-vibe" ]; then
        echo "  VibeVoice model: ${VIBEVOICE_MODEL:-vibe-realtime-8bit}"
        echo "  VibeVoice voice: ${VIBEVOICE_VOICE:-en-Emma_woman}"
        echo "  Auto voice (es/en): ${VIBEVOICE_VOICE_AUTO:-1}"
        echo "  CFG scale: ${VIBEVOICE_CFG_SCALE:-2.0}"
        echo "  DDPM steps: ${VIBEVOICE_DDPM_STEPS:-15}"
    elif [ "$TTS_ENGINE" = "supertonic" ] || [ "$TTS_ENGINE" = "coreml-tts" ]; then
        echo "  Supertonic URL: ${SUPERTONIC_URL:-http://127.0.0.1:8766}"
        echo "  Supertonic voice: ${SUPERTONIC_VOICE_STYLE:-voice_styles/F4.json}"
        echo "  Compute: ${SUPERTONIC_COMPUTE_UNITS:-CPU_AND_NE}"
    fi
    local vibevoice_http_url="${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}"
    vibevoice_http_url="$(printf '%s' "$vibevoice_http_url" | sed 's|^ws://|http://|')"
    vibevoice_http_url="${vibevoice_http_url%/ws/tts}/health"
    echo "=== VibeVoice API (${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}, local MLX) ==="
    if curl -sf -m 2 "$vibevoice_http_url" >/dev/null 2>&1; then
        curl -sf "$vibevoice_http_url" | "$PYTHON" -c "
import json,sys
h=json.load(sys.stdin)
print('  RUNNING — loaded:', ', '.join(h.get('loaded_models') or []) or 'lazy')
print('  models:', ', '.join(h.get('available_models') or []))
" 2>/dev/null || echo "  RUNNING"
    else
        echo "  NOT RUNNING (launchctl kickstart -k gui/\$UID/com.op.tts-multimodel-api)"
    fi
    echo ""

    local stt_model stt_url stt_info
    stt_info="$(resolve_stt)"
    stt_url="$(printf '%s\n' "$stt_info" | sed -n '1p')"
    stt_model="$(printf '%s\n' "$stt_info" | sed -n '2p')"
    echo "=== STT (engine=$STT_ENGINE, model=$stt_model) ==="
    echo "  Endpoint: $stt_url"
    local stt_host
    stt_host=$(echo "$stt_url" | sed 's|http://||;s|/.*||')
    if nc -z -w 2 "${stt_host%:*}" "${stt_host#*:}" 2>/dev/null; then
        echo "  REACHABLE"
    else
        echo "  NOT REACHABLE"
    fi
    if [ "${STT_ENGINE}" != "remote" ]; then
        if launchctl print "gui/$(id -u)/com.opencode.parakeet-stt" >/dev/null 2>&1; then
            echo "  launchd: com.opencode.parakeet-stt running"
        else
            echo "  launchd: com.opencode.parakeet-stt not loaded"
        fi
        stt_memory_stats
    fi
    local sample_wav="$HOME/.config/opencode/ref_voice_bench.wav"
    if [ -f "$sample_wav" ]; then
        local sample_text
        if sample_text=$(transcribe_file "$sample_wav" "$stt_url" "$stt_model" 2>/tmp/opencode-stt-status.err); then
            echo "  Self-test: OK — ${sample_text}"
        else
            echo "  Self-test: FAILED"
            sed 's/^/    /' /tmp/opencode-stt-status.err
        fi
        rm -f /tmp/opencode-stt-status.err
    fi
    echo ""

    echo "=== Python Environment ==="
    echo "  Interpreter: $PYTHON"
    echo "  VAD: $VAD_PY"
    echo "  TTS: $TTS_SH"
    echo "  Codex skill: $([ -L "$HOME/.codex/skills/talk" ] && readlink "$HOME/.codex/skills/talk" || echo "not symlinked")"
    echo "  VibeVoice helper: ${VIBEVOICE_SPEAK_PY:-$HOME/tts-multimodel-api/speak_vibevoice.py}"
    echo "  VibeVoice WS: ${VIBEVOICE_WS_URI:-ws://127.0.0.1:8010/ws/tts}"
    echo "  Auto-listen after speak: $([ "$TALK_AUTO_LISTEN" = 1 ] && echo yes || echo no)"
    echo "  Barge-in: $([ "$TALK_BARGE_IN" = 1 ] && echo "enabled (interrupt TTS on speech)" || echo disabled)"
    echo "  Idle timeout: ${TALK_IDLE_TIMEOUT_S:-30}s (0=disabled)"
    "$PYTHON" -c "
import sounddevice as sd, torch, silero_vad
print('  sounddevice : OK')
print('  torch      :', torch.__version__)
print('  silero-vad :', silero_vad.__version__)
" 2>&1
}

cmd_devices() {
    echo "=== Audio Input Devices ===" >&2
    "$PYTHON" "$VAD_PY" --list-devices
    echo ""
    echo "=== Selected Microphone (MIC_QUERY=${MIC_QUERY:-MacBook Air Microphone}) ==="
    "$PYTHON" "$VAD_PY" --print-selected-mic --mic-query "${MIC_QUERY:-MacBook Air Microphone}" 2>&1 || echo "(selection failed)"
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
