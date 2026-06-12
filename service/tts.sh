#!/bin/bash
# tts.sh — Multi-engine TTS CLI for OpenCode / talk skill.
#
# Engines: supertonic (default, local) → neutts (local) → xai (cloud, last resort).
# supertonic2 (optional local on :8880, Supertonic Express 2) is selectable via
# TTS_ENGINE=supertonic2 once installed (integrations/supertonic2/install.sh).
# Set TTS_ENGINE to override. Local engines are always tried before the xAI
# cloud; xAI is only used if every local engine fails. macOS say is intentionally
# not available.

set -e

# Cross-platform WAV playback (macOS afplay, Linux ffplay/aplay/paplay)
play_wav() {
    local f="$1"
    [ -f "$f" ] || return 1
    case "$(uname -s 2>/dev/null)" in
        Darwin) afplay "$f" ;;
        *)
            if command -v ffplay &>/dev/null; then
                ffplay -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null
            elif command -v aplay &>/dev/null; then
                aplay -q "$f" 2>/dev/null
            elif command -v paplay &>/dev/null; then
                paplay "$f" 2>/dev/null
            else
                echo "[tts] No audio player found (install ffmpeg)" >&2; return 1
            fi ;;
    esac
}

# --- Engine config -----------------------------------------------------------
: "${TTS_ENGINE:=supertonic}"
: "${XAI_API_KEY:=${XAI_API_KEY:-}}"
: "${XAI_TTS_VOICE:=eve}"
: "${XAI_TTS_MODEL:=grok-2-audio}"
: "${SUPERTONIC_URL:=http://127.0.0.1:8766}"
: "${SUPERTONIC_SH:=$HOME/.config/opencode/skills/supertonic-tts/supertonic.sh}"
: "${SUPERTONIC_VOICE:=F4}"   # Supertonic 3 voices: F1–F5 / M1–M5 (default F4)
# Quality presets: normal = 8 steps (fast), high = 20 steps (best). Set
# TTS_QUALITY=high for HQ, or override SUPERTONIC_STEPS=<1-20> directly (wins).
: "${TTS_QUALITY:=normal}"
case "$(printf '%s' "${TTS_QUALITY}" | tr '[:upper:]' '[:lower:]')" in
    high|hq|best) _q_steps=20 ;;
    *)            _q_steps=8  ;;
esac
: "${SUPERTONIC_STEPS:=$_q_steps}"   # denoising steps (1–20)
: "${SUPERTONIC_SPEED:=1.05}"
# Supertonic 2 (optional) — Supertonic Express 2, onnx-community/Supertonic-TTS-2-ONNX.
# Same OpenAI-compatible /v1/audio/speech API as Supertonic 3, served on :8880.
# Not auto-installed; opt in with: bash integrations/supertonic2/install.sh
: "${SUPERTONIC2_URL:=http://127.0.0.1:8880}"
: "${SUPERTONIC2_VOICE:=M1}"          # Supertonic 2 voices: F1–F5 / M1–M5 (default M1)
: "${SUPERTONIC2_STEPS:=$_q_steps}"   # denoising steps (1–20), shares TTS_QUALITY preset
: "${SUPERTONIC2_SPEED:=1.05}"
: "${NEUTTS_URL:=http://127.0.0.1:8020}"
: "${NEUTTS_MODEL:=neuphonic/neutts-nano-q8-gguf}"
: "${NEUTTS_MODEL_ES:=neuphonic/neutts-nano-spanish-q8-gguf}"
: "${NEUTTS_MODEL_DE:=neuphonic/neutts-nano-german-q8-gguf}"
: "${NEUTTS_MODEL_FR:=neuphonic/neutts-nano-french-q8-gguf}"
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
        es*)  model="${NEUTTS_MODEL_ES}" ;;
        de*)  model="${NEUTTS_MODEL_DE}" ;;
        fr*)  model="${NEUTTS_MODEL_FR}" ;;
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
    play_wav "$OUTPUT"
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

    # TTS_NO_PLAY (barge-in mode) — use single-request path
    if [ "${TTS_NO_PLAY:-0}" = "1" ]; then
        _speak_xai_single "$text" "$lang" "$voice"
        return $?
    fi

    # Split into sentence chunks on . ! ?
    local chunks_json
    chunks_json=$(python3 -c "
import sys, re, json
text = sys.stdin.read().strip()
parts = re.split(r'(?<=[.!?])\s+', text)
merged, buf = [], ''
for p in parts:
    p = p.strip()
    if not p:
        continue
    if buf:
        buf = buf + ' ' + p
    else:
        buf = p
    if len(buf.split()) >= 2:
        merged.append(buf)
        buf = ''
if buf:
    if merged:
        merged[-1] = merged[-1] + ' ' + buf
    else:
        merged.append(buf)
print(json.dumps(merged))
" <<<"$text")

    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$chunks_json")

    if [ "$count" -le 1 ]; then
        _speak_xai_single "$text" "$lang" "$voice"
        return $?
    fi

    echo "[tts] Chunking into $count sentences (parallel xAI)" >&2
    _speak_xai_chunked "$chunks_json" "$count" "$lang" "$voice"
}

_speak_xai_single() {
    local text="$1"
    local lang="$2"
    local voice="$3"

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
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

_speak_xai_chunked() {
    local chunks_json="$1"
    local count="$2"
    local lang="$3"
    local voice="$4"

    local chunk_dir
    chunk_dir=$(mktemp -d /tmp/opencode-tts-chunks.XXXXXX)

    # Fire all chunk TTS requests in parallel
    local i chunk_text wav_prefix
    for ((i=0; i<count; i++)); do
        chunk_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[$i])" "$chunks_json")
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        (
            input_json=$(printf '{"text":%s,"voice_id":"%s","language":"%s"}' \
                "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$chunk_text")" \
                "$voice" "$lang")
            if curl -sS -m 30 -o "${wav_prefix}.wav" \
                "https://api.x.ai/v1/tts" \
                -H "Authorization: Bearer $XAI_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$input_json" 2>/dev/null && [ -f "${wav_prefix}.wav" ] && [ -s "${wav_prefix}.wav" ]; then
                touch "${wav_prefix}.ready"
            else
                echo "[tts] xAI chunk $i failed" >&2
                touch "${wav_prefix}.failed"
            fi
        ) &
    done

    # Play in order — starts faster vs single-path, may still wait for late chunks
    for ((i=0; i<count; i++)); do
        wav_prefix="${chunk_dir}/chunk_$(printf '%03d' $i)"
        while [ ! -f "${wav_prefix}.ready" ] && [ ! -f "${wav_prefix}.failed" ]; do
            sleep 0.05
        done
        if [ -f "${wav_prefix}.ready" ]; then
            play_wav "${wav_prefix}.wav"
        fi
    done

    rm -rf "$chunk_dir"
    return 0
}

# Supertonic Express 2 and 3 share the same OpenAI-compatible /v1/audio/speech
# endpoint: required field is `input`; voice is one of F1–F5 / M1–M5; lang via
# `lang_code`. This helper drives either server.
#   args: label url voice steps speed text lang
_speak_supertonic_endpoint() {
    local label="$1" url="$2" voice="$3" steps="$4" speed="$5" text="$6" lang="$7"

    echo "[tts] ${label} voice=${voice} steps=${steps} (${TTS_QUALITY}) lang=${lang} url=${url}" >&2

    local payload
    payload=$(python3 -c "
import json, sys
d = {'input': sys.argv[1], 'voice': sys.argv[3],
     'response_format': 'wav', 'stream': False,
     'total_steps': int(sys.argv[4]), 'speed': float(sys.argv[5])}
if sys.argv[2]:
    d['lang_code'] = sys.argv[2]
print(json.dumps(d))
" "$text" "$lang" "$voice" "$steps" "$speed" 2>/dev/null \
        || printf '{"input":"%s","voice":"%s","response_format":"wav"}' "$text" "$voice")

    local http_code
    http_code=$(curl -sS -m 60 \
        -o "$OUTPUT" \
        -w '%{http_code}' \
        "${url}/v1/audio/speech" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "tts.sh: ${label} request failed (curl exit $?)" >&2
        return 1
    }

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "tts.sh: ${label} HTTP $http_code" >&2
        rm -f "$OUTPUT"
        return 1
    fi

    [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ] || { echo "tts.sh: ${label} produced no audio" >&2; return 1; }
    [ "$TTS_NO_PLAY" = "1" ] && { echo "$OUTPUT"; return 0; }
    play_wav "$OUTPUT"
    rm -f "$OUTPUT"
}

speak_supertonic() {
    _speak_supertonic_endpoint "Supertonic" "$SUPERTONIC_URL" "$SUPERTONIC_VOICE" \
        "$SUPERTONIC_STEPS" "$SUPERTONIC_SPEED" "$1" "$2"
}

# Supertonic 2 (Supertonic Express 2) — optional local engine on :8880.
speak_supertonic2() {
    _speak_supertonic_endpoint "Supertonic2" "$SUPERTONIC2_URL" "$SUPERTONIC2_VOICE" \
        "$SUPERTONIC2_STEPS" "$SUPERTONIC2_SPEED" "$1" "$2"
}

# --- Fallback policy ---------------------------------------------------------
# Always exhaust the LOCAL engines before the xAI cloud. The selected engine
# runs first, then the remaining local engine(s); xAI is the final resort, used
# only if every local engine fails. Selecting TTS_ENGINE=xai explicitly honors
# that choice first, then still falls back to the local engines.
engine="$(printf '%s' "${TTS_ENGINE}" | tr '[:upper:]' '[:lower:]')"
case "$engine" in
    supertonic|coreml-tts)
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    supertonic2|supertonic-2)
        if speak_supertonic2 "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic2 failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    neutts|neuphonic)
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] NeuTTS failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → xAI cloud (last resort)…" >&2
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    xai)
        # Explicit cloud selection: honored first, then local fallbacks.
        if speak_xai "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] xAI failed → trying Supertonic (local)…" >&2
        if speak_supertonic "$TEXT" "$LANG"; then exit 0; fi
        echo "[tts] Supertonic failed → trying NeuTTS (local)…" >&2
        if speak_neutts "$TEXT" "$LANG"; then exit 0; fi
        echo "tts.sh: all TTS engines failed; no macOS say fallback is available" >&2
        exit 1
        ;;
    *)
        echo "tts.sh: unknown TTS_ENGINE=${TTS_ENGINE}. Use: supertonic, supertonic2, neutts, xai." >&2
        exit 2
        ;;
esac
