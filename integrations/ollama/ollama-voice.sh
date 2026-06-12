#!/bin/bash
# ollama-voice — Hands-free spoken conversation with Ollama models
#
# Mic→Silero VAD→Parakeet STT→Ollama LLM→Supertonic TTS→Speaker
# All CPU-only. Auto-installed by `ollama-voice --setup`.
#
# Usage:
#   ollama-voice <model>        Talk to a model (e.g. llama3.2)
#   ollama-voice --setup         Install voice backends + this command
#   ollama-voice --status        Health check for all components

set -euo pipefail

TALK_SH="${TALK_SH:-$HOME/.config/opencode/skills/talk/talk.sh}"
: "${OLLAMA_HOST:=http://127.0.0.1:11434}"
: "${OLLAMA_VOICE_NO_THINK:=1}"
: "${OLLAMA_VOICE_MAX_TOKENS:=250}"

bold()   { printf '\033[1m%s\033[0m'  "$*"; }
green()  { printf '\033[1;32m%s\033[0m' "$*"; }
cyan()   { printf '\033[1;36m%s\033[0m' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m' "$*"; }
red()    { printf '\033[1;31m%s\033[0m' "$*"; }

PID_FILE="${PID_FILE:-/tmp/ollama-voice.pid}"
echo $$ > "$PID_FILE"
_cleanup() { rm -f "$PID_FILE" /tmp/ollama-voice-msg.json 2>/dev/null; echo; green "Goodbye!"; }
trap _cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════════
# Health check
cmd_status() {
    echo "$(bold '=== ollama-voice Status ===')"
    echo ""
    [ -x "$TALK_SH" ] && echo "$(green '[OK]') talk.sh" || echo "$(red '[MISSING]') talk.sh — run: ollama-voice --setup"
    curl -sfm 2 http://127.0.0.1:5093/health >/dev/null 2>&1 && echo "$(green '[OK]') Parakeet STT on :5093" || echo "$(red '[DOWN]') Parakeet STT on :5093"
    curl -sfm 2 http://127.0.0.1:8766/health >/dev/null 2>&1 && echo "$(green '[OK]') Supertonic TTS on :8766" || echo "$(red '[DOWN]') Supertonic TTS on :8766"
    if curl -sfm 2 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
        echo "$(green '[OK]') Ollama at $OLLAMA_HOST"
        echo ""
        echo "$(bold 'Models:')"
        curl -sf "${OLLAMA_HOST}/api/tags" | python3 -c "
import sys,json
for m in json.load(sys.stdin.buffer).get('models',[]):
    sz=m.get('size',0)
    print(f'  {m[\"name\"]:50s} {sz/1e9:.1f}GB' if sz>1e9 else f'  {m[\"name\"]:50s} {sz/1e6:.0f}MB')
"
    else
        echo "$(red '[DOWN]') Ollama at $OLLAMA_HOST"
    fi
    echo ""
    echo "$(bold 'Try:') ollama-voice llama3.2"
}

# ═══════════════════════════════════════════════════════════════
# One-time setup: run setup.sh + install this command to PATH
cmd_setup() {
    echo "$(cyan 'Installing Voice Service for Ollama...')"
    local setup_sh="$HOME/Local-VoiceMode-LLM/setup.sh"
    if [ ! -f "$setup_sh" ]; then
        setup_sh="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../../setup.sh"
    fi
    if [ ! -f "$setup_sh" ]; then
        echo "$(red 'ERROR:') setup.sh not found."
        echo "  git clone https://github.com/groxaxo/Local-VoiceMode-LLM.git ~/Local-VoiceMode-LLM"
        exit 1
    fi
    yellow "Running setup.sh --no-integrations ..."
    bash "$setup_sh" --no-integrations
    green "Voice stack installed."

    local self dest
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    dest="/usr/local/bin/ollama-voice"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    if [ -w "$(dirname "$dest")" ] || [ "$(id -u)" -eq 0 ]; then
        cp "$self" "$dest" && chmod +x "$dest" && green "Installed: $dest"
    elif command -v sudo &>/dev/null; then
        sudo cp "$self" "$dest" && sudo chmod +x "$dest" && green "Installed: $dest"
    else
        yellow "To install globally: sudo cp $self /usr/local/bin/ollama-voice"
    fi
    echo ""
    green '=== Done! ==='
    echo "  ollama-voice llama3.2    # start talking"
    echo "  ollama-voice --status    # health check"
}

# ═══════════════════════════════════════════════════════════════
# Chat with Ollama — returns cleaned response text on stdout
ollama_chat() {
    local messages_json="$1" model="$2"
    local opts payload resp

    opts=$(python3 -c "
import json,os
d={'num_predict':int(os.environ.get('OLLAMA_VOICE_MAX_TOKENS','250')),'temperature':0.7}
try: d.update(json.loads(os.environ.get('OLLAMA_OPTIONS','{}')))
except: pass
print(json.dumps(d))
")

    payload=$(python3 -c "
import json,sys
m=json.loads(sys.argv[1])
opts=json.loads(sys.argv[2])
no_think=sys.argv[4]=='1'
p={'model':sys.argv[3],'stream':False,'messages':m,'options':opts}
if no_think: p['think']=False
print(json.dumps(p))
" "$messages_json" "$opts" "$model" "$OLLAMA_VOICE_NO_THINK")

    if ! resp=$(curl -sS --max-time 180 -H "Content-Type: application/json" -d "$payload" \
                   "${OLLAMA_HOST}/api/chat" 2>&1); then
        echo "[voice] Ollama error: $resp" >&2
        return 1
    fi

    echo "$resp" | python3 -c "
import sys,json,re
r=json.load(sys.stdin.buffer)
c=r.get('message',{}).get('content','')
if not c: sys.exit(1)
c=re.sub(r'</?think>','',c)
print(c.strip())
"
}

# ═══════════════════════════════════════════════════════════════
# Main conversation loop
talk_loop() {
    local model="$1"
    local msg_file="/tmp/ollama-voice-msg.json"
    local turn=0 text reply

    echo ""
    cyan "Talking to $(bold "$model") — Ctrl+C to stop"
    echo ""

    # System prompt: keep responses voice-friendly
    local sys_prompt="You are a helpful AI assistant. Keep answers concise and conversational — this is voice mode. Reply in 1-3 short sentences unless asked for detail. Use natural spoken language, never markdown or code blocks."

    # Init message history
    python3 -c "
import json,sys
sys.stdout.buffer.write(json.dumps([{'role':'system','content':sys.argv[1]}]).encode())
" "$sys_prompt" > "$msg_file"

    # First turn: listen
    echo "$(cyan 'Listening... (speak now)')" >&2
    text=$(bash "$TALK_SH" listen 2>/dev/null || true)
    text="${text%"${text##*[![:space:]]}"}"
    text="${text#"${text%%[![:space:]]*}"}"

    if [ -z "$text" ]; then
        echo "$(yellow 'No speech detected. Listening again...')" >&2
        text=$(bash "$TALK_SH" listen 2>/dev/null || true)
        text="${text%"${text##*[![:space:]]}"}"
        text="${text#"${text%%[![:space:]]*}"}"
    fi

    if [ -z "$text" ]; then
        echo "$(red 'No speech detected. Exiting.')"
        return 1
    fi

    while true; do
        echo "" >&2
        echo "$(green 'You:') $text" >&2

        # Append user message
        python3 -c "
import json,sys
f=open(sys.argv[1],'r+')
msgs=json.load(f)
msgs.append({'role':'user','content':sys.argv[2]})
f.seek(0); f.truncate()
json.dump(msgs,f)
f.close()
" "$msg_file" "$text"

        # Get Ollama response
        echo "$(yellow 'Thinking...')" >&2
        messages_json=$(python3 -c "
import json,sys
with open(sys.argv[1]) as f: msgs=json.load(f)
# Keep only last 20 messages for context window
print(json.dumps(msgs[-20:]))
" "$msg_file")

        if ! reply=$(ollama_chat "$messages_json" "$model"); then
            echo "$(red 'Error getting response from Ollama.')" >&2
            sleep 2
            text=$(bash "$TALK_SH" listen 2>/dev/null || true)
            continue
        fi

        reply="${reply%"${reply##*[![:space:]]}"}"
        reply="${reply#"${reply%%[![:space:]]*}"}"

        if [ -z "$reply" ]; then
            echo "$(red 'Empty response from model.')" >&2
            sleep 2
            text=$(bash "$TALK_SH" listen 2>/dev/null || true)
            continue
        fi

        echo "$(bold 'Model:') $reply" >&2

        # Append assistant message
        python3 -c "
import json,sys
f=open(sys.argv[1],'r+')
msgs=json.load(f)
msgs.append({'role':'assistant','content':sys.argv[2]})
f.seek(0); f.truncate()
json.dump(msgs,f)
f.close()
" "$msg_file" "$reply"

        # Speak and auto-listen (talk.sh speak does both)
        echo "$(cyan 'Speaking...')" >&2
        text=$(bash "$TALK_SH" speak "$reply" 2>/dev/null || true)
        text="${text%"${text##*[![:space:]]}"}"
        text="${text#"${text%%[![:space:]]*}"}"

        if [ -z "$text" ]; then
            echo "$(yellow 'No reply heard. Listening again...')" >&2
            text=$(bash "$TALK_SH" listen 2>/dev/null || true)
            text="${text%"${text##*[![:space:]]}"}"
            text="${text#"${text%%[![:space:]]*}"}"
        fi

        if [ -z "$text" ]; then
            echo "$(red 'No speech detected. Exiting.')"
            return 0
        fi
    done
}

# ═══════════════════════════════════════════════════════════════
# Entry point
case "${1:-}" in
    --setup|-s)
        cmd_setup
        ;;
    --status|-S)
        cmd_status
        ;;
    -h|--help)
        echo "Usage: ollama-voice <model> [--setup] [--status]"
        echo ""
        echo "  ollama-voice llama3.2     Talk to llama3.2 with voice"
        echo "  ollama-voice --setup       One-time: install voice backends"
        echo "  ollama-voice --status      Health check for all components"
        echo ""
        echo "Environment:"
        echo "  OLLAMA_HOST=$OLLAMA_HOST"
        echo "  OLLAMA_VOICE_MAX_TOKENS=$OLLAMA_VOICE_MAX_TOKENS"
        echo "  OLLAMA_VOICE_NO_THINK=$OLLAMA_VOICE_NO_THINK"
        ;;
    "")
        echo "Usage: ollama-voice <model>"
        echo "Try: ollama-voice llama3.2"
        exit 1
        ;;
    *)
        if [ ! -x "$TALK_SH" ]; then
            red "Voice stack not installed. Run: ollama-voice --setup"
            exit 1
        fi
        talk_loop "$1"
        ;;
esac
