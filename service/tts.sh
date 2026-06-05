#!/bin/bash
# tts.sh — Multi-engine TTS CLI for OpenCode / talk skill.
#
# Engines: neutts (default), xai, supertonic.
# Set TTS_ENGINE to override. macOS say is intentionally not available.

set -e

# --- Engine config -----------------------------------------------------------
: "${TTS_ENGINE:=neutts}"
: "${XAI_API_KEY:=${XAI_API_KEY:-}}"
: "${XAI_TTS_VOICE:=eve}"
: "${XAI_TTS_MODEL:=grok-2-audio}"
: "${SUPERTONIC_URL:=http://127.0.0.1:8765}"
: "${SUPERTONIC_SH:=$HOME/.config/opencode/skills/supertonic-tts/supertonic.sh}"
: "${NEUTTS_URL:=http://127.0.0.1:8020}"
: "${NEUTTS_MODEL:=neuphonic/neutts-nano-q8-gguf}"
# -----------------------------------------------------------------------------

# shellcheck source=tts_lang.sh
. "${TTS_LANG_SH:=$HOME/.config/opencode/tts_lang.sh}"

TEXT="${1:-Hello.}"
OUTPUT="/tmp/opencode-speech.wav"
LANG="$(resolve_lang "${2:-}" "$TEXT")"

: "${TTS_NO_PLAY:=0}"

speak_neutts() {
    local text="$1"
    local lang="$2"
    local model="$NEUTTS_MODEL"

    case "$lang" in
        es*)  model="neuphonic/neutts-nano-spanish-q8-gguf" ;;
        de*)  model="neuphonic/neutts-nano-german-q8-gguf" ;;
        fr*)  model="neuphonic/neutts-nano-french-q8-gguf" ;;
        en*|*) model="${NEUTTS_MODEL}" ;;
    esac

    echo "[tts] NeuTTS lang=${lang} model=${model}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
d = {'text': sys.argv[1], 'model': sys.argv[3]}
if sys.argv[2]:
    d['language'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" "$model" 2>/dev/null || printf '{"text":"%s","model":"%s"}' "$text" "$model")

    local http_code
    http_code=$(curl -sS -m 120 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${NEUTTS_URL}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: NeuTTS request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: NeuTTS HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: NeuTTS produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_xai() {
    local text="$1"
    local lang="$2"
    local voice="${XAI_TTS_VOICE:-eve}"

    if [ -z "$XAI_API_KEY" ]; then
        echo "tts.sh: XAI_API_KEY not set" >&2
        return 1
    fi

    echo "[tts] xAI lang=${lang} voice=${voice}" >&2

    local input_json
    input_json=$(printf '{"text":%s,"voice_id":"%s","language":"%s"}' \
        "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")" \
        "$voice" "$lang")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "https://api.x.ai/v1/tts" \
        -H "Authorization: Bearer $XAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$input_json") || {
        echo "tts.sh: xAI request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: xAI HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: xAI produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_supertonic() {
    local text="$1"
    local lang="$2"

    if [ ! -x "$SUPERTONIC_SH" ]; then
        echo "tts.sh: Supertonic wrapper not found: $SUPERTONIC_SH" >&2
        return 1
    fi

    echo "[tts] Supertonic lang=${lang} url=${SUPERTONIC_URL}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
d = {'text': sys.argv[1]}
if sys.argv[2]:
    d['language'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" 2>/dev/null || printf '{"text":"%s"}' "$text")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${SUPERTONIC_URL}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: Supertonic request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: Supertonic HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: Supertonic produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    afplay "$OUTPUT"
    rm -f "$OUTPUT"
}

engine="$(printf '%s' "${TTS_ENGINE}" | tr '[:upper:]' '[:lower:]')"
case "$engine" in
    neutts|neuphonic)
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying xAI fallback…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] xAI failed, trying Supertonic…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    xai)
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] xAI failed, trying NeuTTS fallback…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying Supertonic…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    supertonic|coreml-tts)
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed, trying NeuTTS fallback…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed, trying xAI…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    *)
        echo "tts.sh: unknown TTS_ENGINE=${TTS_ENGINE}. Use: neutts, xai, supertonic." >&2
        exit 2
        ;;
esac
