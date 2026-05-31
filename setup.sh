#!/bin/bash
# setup.sh — One-command setup for OpenCode Voice Service
#
# Creates Python venv, installs dependencies, installs service files
# to ~/.config/opencode, and optionally generates reference voices.
#
# Usage:
#   ./setup.sh                     # full setup
#   ./setup.sh --skip-voices       # skip voice generation
#   ./setup.sh --venv-only         # only create the venv
#   TTS_SERVER_PORT=9876 ./setup.sh # custom port

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HOME}/.config/opencode"
SKILL_DIR="${CONFIG_DIR}/skills/talk"
VENV_DIR="${CONFIG_DIR}/tts-venv"
PYTHON="${VENV_DIR}/bin/python"

# Colors
info()  { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[setup]\033[0m ✓ %s\n" "$*"; }
warn()  { printf "\033[1;33m[setup]\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31m[setup]\033[0m %s\n" "$*"; }

# --- Parse flags -------------------------------------------------------------
SKIP_VOICES=false
VENV_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --skip-voices) SKIP_VOICES=true ;;
        --venv-only)   VENV_ONLY=true ;;
        *) warn "Unknown flag: $arg" ;;
    esac
done

# --- Step 1: Python venv -----------------------------------------------------
if [ -d "$VENV_DIR" ]; then
    info "Venv exists at $VENV_DIR"
    # Check python version
    PY_VER=$("$VENV_DIR/bin/python" --version 2>&1 | grep -oP '\d+\.\d+')
    if [ "$(echo "$PY_VER >= 3.11" | bc -l 2>/dev/null)" != "1" ]; then
        warn "Python $PY_VER < 3.11, recreating venv"
        rm -rf "$VENV_DIR"
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python 3.12 venv at $VENV_DIR..."

    # Try uv first, then python3.12, then python3
    if command -v uv &>/dev/null; then
        uv venv --python 3.12 "$VENV_DIR" 2>/dev/null || uv venv "$VENV_DIR" 2>/dev/null || {
            python3.12 -m venv "$VENV_DIR" 2>/dev/null || python3 -m venv "$VENV_DIR"
        }
    elif python3.12 -m venv "$VENV_DIR" 2>/dev/null; then
        :
    else
        python3 -m venv "$VENV_DIR"
    fi
    ok "Venv created"
fi

# --- Step 2: Install Python packages ----------------------------------------
info "Installing Python dependencies..."

"$VENV_DIR/bin/pip" install --quiet --upgrade pip setuptools wheel 2>/dev/null

# Core voice stack
"$VENV_DIR/bin/pip" install --quiet \
    silero-vad \
    sounddevice \
    onnxruntime \
    torch \
    torchaudio \
    numpy \
    2>&1 | grep -v "^$" || true

# TTS dependencies (optional, for reference)
"$VENV_DIR/bin/pip" install --quiet \
    mlx-audio \
    soundfile \
    scipy \
    2>&1 | grep -v "^$" || true

ok "Dependencies installed"

if [ "$VENV_ONLY" = true ]; then
    ok "Venv-only setup complete"
    exit 0
fi

# --- Step 3: Install service files ------------------------------------------
info "Installing service files to $SKILL_DIR..."
mkdir -p "$SKILL_DIR"

cp "$REPO_DIR/service/vad_recorder.py" "$SKILL_DIR/vad_recorder.py"
cp "$REPO_DIR/service/talk.sh" "$SKILL_DIR/talk.sh"
cp "$REPO_DIR/service/tts.sh" "$SKILL_DIR/tts.sh"
cp "$REPO_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"

chmod +x "$SKILL_DIR/vad_recorder.py" "$SKILL_DIR/talk.sh" "$SKILL_DIR/tts.sh"
ok "Service files installed to $SKILL_DIR"

# Also install tts.sh for backward compat
cp "$REPO_DIR/service/tts.sh" "$CONFIG_DIR/tts.sh"
chmod +x "$CONFIG_DIR/tts.sh"
ok "TTS wrapper installed to $CONFIG_DIR/tts.sh"

# --- Step 4: Install launchd plist ------------------------------------------
if [ -d "$REPO_DIR/launchd" ]; then
    PLIST_SRC=$(ls "$REPO_DIR"/launchd/*.plist 2>/dev/null | head -1)
    if [ -n "$PLIST_SRC" ]; then
        PLIST_DST="$HOME/Library/LaunchAgents/com.opencode.tts-server.plist"
        sed "s|HOME_PLACEHOLDER|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
        ok "Launchd plist installed to $PLIST_DST (with HOME=$HOME)"
    fi
fi

# --- Step 5: Generate reference voices (unless skipped) ----------------------
if [ "$SKIP_VOICES" = false ]; then
    if [ ! -f "$CONFIG_DIR/ref_voice_en.wav" ]; then
        info "Generating English reference voice (Samantha)..."
        say -v "Samantha" -o /tmp/opencode-ref.aiff \
            "Hello, I am your AI assistant." 2>/dev/null
        ffmpeg -i /tmp/opencode-ref.aiff -ar 22050 -ac 1 \
            "$CONFIG_DIR/ref_voice_en.wav" -y 2>/dev/null || {
            warn "Could not generate English reference voice (ffmpeg missing?)"
        }
        rm -f /tmp/opencode-ref.aiff
        [ -f "$CONFIG_DIR/ref_voice_en.wav" ] && ok "English reference voice created"
    else
        info "English reference voice already exists"
    fi

    if [ ! -f "$CONFIG_DIR/ref_voice_es.wav" ]; then
        info "Generating Spanish reference voice (Mónica)..."
        say -v "Mónica" -o /tmp/opencode-ref.aiff \
            "Hola, soy tu asistente de inteligencia artificial." 2>/dev/null
        ffmpeg -i /tmp/opencode-ref.aiff -ar 22050 -ac 1 \
            "$CONFIG_DIR/ref_voice_es.wav" -y 2>/dev/null || {
            warn "Could not generate Spanish reference voice (ffmpeg or Mónica voice missing?)"
        }
        rm -f /tmp/opencode-ref.aiff
        [ -f "$CONFIG_DIR/ref_voice_es.wav" ] && ok "Spanish reference voice created"
    else
        info "Spanish reference voice already exists"
    fi
fi

# --- Summary ----------------------------------------------------------------
echo ""
info "── Setup Complete ─────────────────────────────────────────────"
echo ""
echo "  Service:   $SKILL_DIR/talk.sh"
echo "  Skill:     $SKILL_DIR/SKILL.md"
echo "  Venv:      $VENV_DIR"
echo "  TTS:       $(launchctl list | grep -q opencode.tts && echo 'RUNNING' || echo 'not running')"
echo ""
echo "  Try it:    $SKILL_DIR/talk.sh listen"
echo "  Status:    $SKILL_DIR/talk.sh status"
echo ""
echo "───────────────────────────────────────────────────────────────"
