#!/bin/bash
# install-ollama-voice.sh — One-command autoinstaller for Ollama + Voice
#
# This script:
#   1. Installs the OpenCode Voice Service (Silero VAD + STT + TTS backends)
#   2. Installs the `ollama-voice` command to /usr/local/bin
#   3. Verifies everything is working
#
# Prerequisites: Ollama already installed (ollama serve running)
#
# Usage:
#   bash install-ollama-voice.sh
#
# After install:
#   ollama-voice llama3.2     # start talking
#   ollama-voice --status     # health check

set -euo pipefail

info()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[install]\033[0m ✓ %s\n' "$*"; }
warn()  { printf '\033[1;33m[install]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[install]\033[0m %s\n' "$*"; }

echo ""
printf '\033[1;36m  ╔══════════════════════════════════════════════════════╗\033[0m\n'
printf '\033[1;36m  ║   Ollama Voice Installer — Talk to your models!     ║\033[0m\n'
printf '\033[1;36m  ║   CPU-only · Local · No API keys needed             ║\033[0m\n'
printf '\033[1;36m  ╚══════════════════════════════════════════════════════╝\033[0m\n'
echo ""

# ── Determine paths ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DEST="/usr/local/bin/ollama-voice"
SETUP_SH="$REPO_DIR/setup.sh"
OLLAMA_VOICE_SH="$SCRIPT_DIR/ollama-voice.sh"

# ── Prerequisites check ──────────────────────────────────────────────
info "Checking prerequisites..."

if ! command -v ollama &>/dev/null; then
    err "ollama not found. Install it first: curl -fsSL https://ollama.com/install.sh | sh"
    exit 1
fi
ok "ollama found: $(ollama --version 2>&1 | head -1)"

if ! curl -sfm 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    warn "ollama serve is not running. Start it in another terminal: ollama serve"
    warn "Continuing with voice stack install (you can start ollama later)..."
else
    ok "ollama serve is running on :11434"
fi

if ! command -v python3 &>/dev/null; then
    err "python3 not found. Install Python 3.11+ first."
    exit 1
fi
ok "python3: $(python3 --version)"

# ── Step 1: Install Voice Service stack ──────────────────────────────
info "━━━━ Installing OpenCode Voice Service ━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "$SETUP_SH" ]; then
    info "Running setup.sh --no-integrations (non-interactive)..."
    bash "$SETUP_SH" --no-integrations
    ok "Voice stack installed"
else
    err "setup.sh not found at $SETUP_SH"
    err "Make sure you're running this from the integrations/ollama/ directory"
    exit 1
fi

# ── Step 2: Install ollama-voice command ─────────────────────────────
info "━━━━ Installing ollama-voice command ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$OLLAMA_VOICE_SH" ]; then
    err "ollama-voice.sh not found at $OLLAMA_VOICE_SH"
    exit 1
fi

mkdir -p "$(dirname "$BIN_DEST")" 2>/dev/null || true
if [ -w "$(dirname "$BIN_DEST")" ] || [ "$(id -u)" -eq 0 ]; then
    cp "$OLLAMA_VOICE_SH" "$BIN_DEST"
    chmod +x "$BIN_DEST"
    ok "Installed: $BIN_DEST"
elif command -v sudo &>/dev/null; then
    sudo cp "$OLLAMA_VOICE_SH" "$BIN_DEST"
    sudo chmod +x "$BIN_DEST"
    ok "Installed (sudo): $BIN_DEST"
else
    warn "Cannot install to /usr/local/bin (no sudo)."
    warn "Run manually: sudo cp $OLLAMA_VOICE_SH /usr/local/bin/ollama-voice"
fi

# ── Step 3: Verify ──────────────────────────────────────────────────
info "━━━━ Verification ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TALK_SH="$HOME/.config/opencode/skills/talk/talk.sh"
pass=0; total=4

if [ -x "$TALK_SH" ]; then
    ok "talk.sh installed"
    pass=$((pass+1))
else
    warn "talk.sh missing"
fi

if curl -sfm 2 http://127.0.0.1:5093/health >/dev/null 2>&1; then
    ok "Parakeet STT running on :5093"
    pass=$((pass+1))
else
    warn "Parakeet STT not responding"
    warn "  Linux: systemctl --user start opencode-parakeet-stt"
fi

if curl -sfm 2 http://127.0.0.1:8766/health >/dev/null 2>&1; then
    ok "Supertonic TTS running on :8766"
    pass=$((pass+1))
else
    warn "Supertonic TTS not responding"
    warn "  Linux: systemctl --user start opencode-supertonic"
fi

if command -v ollama-voice &>/dev/null || [ -x "$BIN_DEST" ]; then
    ok "ollama-voice command installed"
    pass=$((pass+1))
else
    warn "ollama-voice not on PATH yet (may need new terminal)"
fi

echo ""
info "━━━━ Done! ($pass/$total checks passed) ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -x "$BIN_DEST" ]; then
    echo "  $(printf '\033[1m%s\033[0m' 'Start talking:')  ollama-voice llama3.2"
    echo "  $(printf '\033[1m%s\033[0m' 'Health check:')   ollama-voice --status"
    echo ""
    echo "  $(printf '\033[1m%s\033[0m' 'Other models:')   ollama-voice <model-name>"
    echo "                     $(printf '\033[2m%s\033[0m' '# any model in ollama ls')"
fi

echo ""
echo "────────────────────────────────────────────────────────────────────"
echo "  Voice engine:  Supertonic 3 ONNX (CPU, :8766)"
echo "  STT engine:    Parakeet TDT 0.6B ONNX (CPU, :5093)"
echo "  VAD engine:    Silero VAD (ONNX)"
echo "  LLM backend:   Ollama (:11434)"
echo ""
echo "  Config:  ~/.config/opencode/skills/talk/talk.sh"
echo "  Docs:    $REPO_DIR/README.md"
echo "  Repo:    https://github.com/groxaxo/Local-VoiceMode-LLM"
echo "────────────────────────────────────────────────────────────────────"
