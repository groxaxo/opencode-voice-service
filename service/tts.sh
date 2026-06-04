#!/bin/bash
# tts.sh — TTS CLI for OpenCode / talk skill
#
# Default: xAI TTS (same contract as OpenVoiceApp VoiceBridge)
#   POST https://api.x.ai/v1/tts  { text, voice_id, language }
#
# Optional: local Chatterbox via mlx-audio (TTS_ENGINE=chatterbox)

: "${TTS_ENGINE:=xai}"
: "${XAI_TTS_URL:=https://api.x.ai/v1/tts}"
: "${XAI_TTS_VOICE:=eve}"
: "${XAI_TTS_LANGUAGE:=auto}"
: "${TTS_ENABLE_CHATTERBOX_FALLBACK:=1}"

: "${TTS_HOST:=localhost}"
: "${TTS_PORT:=8765}"
: "${REF_DIR:=$HOME/.config/opencode}"
: "${REF_AUDIO_DEFAULT:=$REF_DIR/ref_voice_monica.wav}"
: "${REF_TEXT_FILE_DEFAULT:=$REF_DIR/ref_voice_monica.txt}"

TEXT="${1:-Hello.}"
LANG="${2:-es}"
OUTPUT="/tmp/opencode-speech.wav"

load_xai_api_key() {
    if [ -n "${XAI_API_KEY:-}" ]; then
        return 0
    fi
    local f
    for f in \
        "$HOME/Documents/IOSAPP/voice-bridge/.env" \
        "$HOME/.hermes/.env" \
        "$HOME/.config/opencode/.env"; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC1090
        set -a
        # shellcheck source=/dev/null
        . "$f"
        set +a
        [ -n "${XAI_API_KEY:-}" ] && return 0
    done
    return 1
}

speak_xai() {
    local text="$1"
    if ! load_xai_api_key; then
        echo "tts.sh: XAI_API_KEY not set" >&2
        return 1
    fi

    local py="${HOME}/.config/opencode/tts-venv/bin/python3"
    [ -x "$py" ] || py="python3"

    local ext
    ext=$("$py" - "$XAI_TTS_URL" "$text" "$XAI_TTS_VOICE" "$XAI_TTS_LANGUAGE" "$OUTPUT" <<'PY'
import json
import sys
import urllib.error
import urllib.request

url, text, voice, language, output = sys.argv[1:6]
allowed = {"ara", "eve", "leo", "rex", "sal"}
voice = voice.strip().lower()
if voice not in allowed:
    voice = "eve"

payload = json.dumps(
    {"text": text, "voice_id": voice, "language": language}
).encode("utf-8")
req = urllib.request.Request(
    url,
    data=payload,
    headers={
        "Authorization": f"Bearer {__import__('os').environ['XAI_API_KEY']}",
        "Content-Type": "application/json",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
        media = resp.headers.get("Content-Type", "audio/mpeg")
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8", errors="replace")[:500]
    print(f"xAI TTS HTTP {e.code}: {body}", file=sys.stderr)
    sys.exit(1)

out = output
if "mpeg" in media or "mp3" in media:
    out = output.replace(".wav", ".mp3")
elif "wav" in media:
    out = output if output.endswith(".wav") else output + ".wav"

with open(out, "wb") as f:
    f.write(data)
print(out)
PY
) || return 1

    afplay "$ext"
}

speak_chatterbox() {
    local text="$1"
    local lang="$2"
    local ref_audio="${3:-$REF_AUDIO_DEFAULT}"
    local ref_text_file="${4:-$REF_TEXT_FILE_DEFAULT}"

    local ref_text
    if [ -n "${5:-}" ]; then
        ref_text="$5"
    elif [ -f "$ref_text_file" ]; then
        ref_text="$(tr '\n' ' ' < "$ref_text_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    else
        ref_text="Definitivamente el departamento tiene que tener terraza o balcón."
    fi

    local tts_url="http://${TTS_HOST}:${TTS_PORT}/v1/audio/speech"
    local py="${HOME}/.config/opencode/tts-venv/bin/python3"
    [ -x "$py" ] || py="python3"

    "$py" - "$tts_url" "$text" "$lang" "$ref_audio" "$ref_text" "$OUTPUT" <<'PY'
import json
import sys
import urllib.request

url, text, lang, ref_audio, ref_text, output = sys.argv[1:7]
payload = {
    "model": "theoracleguy/Chatterbox-Multilingual-MLX-v2-Q8",
    "input": text,
    "lang_code": lang,
    "ref_audio": ref_audio,
    "ref_text": ref_text,
    "response_format": "wav",
}
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req) as resp:
    data = resp.read()
with open(output, "wb") as f:
    f.write(data)
PY

    afplay "$OUTPUT"
}

detect_lang() {
    if echo "$TEXT" | LC_ALL=C grep -q '[áéíóúñü¿¡ÁÉÍÓÚÑÜ]'; then
        echo "es"
    else
        echo "en"
    fi
}

[ -n "$LANG" ] || LANG="$(detect_lang "$TEXT")"

_engine=$(printf '%s' "$TTS_ENGINE" | tr '[:upper:]' '[:lower:]')
case "$_engine" in
    chatterbox|local|mlx|chatterbox_mlx)
        speak_chatterbox "$TEXT" "$LANG" || exit 1
        ;;
    xai|grok|*)
        if speak_xai "$TEXT"; then
            exit 0
        fi
        if [ "${TTS_ENABLE_CHATTERBOX_FALLBACK}" = "1" ]; then
            echo "tts.sh: xAI failed, trying Chatterbox fallback" >&2
            speak_chatterbox "$TEXT" "$LANG" || exit 1
            exit 0
        fi
        exit 1
        ;;
esac
