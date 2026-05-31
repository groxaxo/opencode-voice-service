#!/bin/bash
# tts.sh — Local TTS CLI wrapper for Chatterbox-Multilingual-MLX
#
# Calls the local mlx-audio server at localhost:8765.
# The server autostarts via launchd on login.
#
# Usage:
#   tts.sh "text to speak" [lang] [ref_audio] [ref_text]
#
# Examples:
#   tts.sh "Hello, world."
#   tts.sh "Hola, mundo." es
#   tts.sh "Bonjour." fr ~/voices/ref_fr.wav "Bonjour le monde."
#
# Language defaults:
#   en → ~/.config/opencode/ref_voice_en.wav  (Samantha clone)
#   es → ~/.config/opencode/ref_voice_es.wav  (Mónica clone)
#   *  → ~/.config/opencode/ref_voice_en.wav  (fallback)

: "${TTS_HOST:=localhost}"
: "${TTS_PORT:=8765}"
: "${REF_DIR:=$HOME/.config/opencode}"

TTS_URL="http://${TTS_HOST}:${TTS_PORT}/v1/audio/speech"
TEXT="${1:-Hello.}"
LANG="${2:-en}"

case "$LANG" in
  en) REF_AUDIO="${3:-$REF_DIR/ref_voice_en.wav}" ;;
  es) REF_AUDIO="${3:-$REF_DIR/ref_voice_es.wav}" ;;
  *)  REF_AUDIO="${3:-$REF_DIR/ref_voice_en.wav}" ;;
esac
REF_TEXT="${4:-Hello, I am your AI assistant.}"

curl -s "$TTS_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"theoracleguy/Chatterbox-Multilingual-MLX-v2-Q8\",
    \"input\": \"$TEXT\",
    \"lang_code\": \"$LANG\",
    \"ref_audio\": \"$REF_AUDIO\",
    \"ref_text\": \"$REF_TEXT\",
    \"response_format\": \"wav\"
  }" -o /tmp/opencode-speech.wav && afplay /tmp/opencode-speech.wav
