#!/bin/bash
# setup.sh — One-command automated setup for OpenCode Voice Service
#
# Installs the complete voice stack:
#   1. Voice Service Core  — Silero VAD + STT/TTS orchestrator
#   2. Parakeet STT Backend — ONNX-based ASR on :5093 (auto-installed)
#   3. Supertonic TTS       — ONNX-based TTS on :8766 (auto-installed)
#   4. launchd auto-start   — all services survive reboots
#
# Usage:
#   ./setup.sh                          # full setup (all backends)
#   ./setup.sh --skip-parakeet          # skip Parakeet STT installation
#   ./setup.sh --skip-supertonic        # skip Supertonic TTS installation
#   ./setup.sh --venv-only              # only create the voice venv
#   ./setup.sh --skip-voices            # skip reference voice generation
#   ./setup.sh --force                  # overwrite existing plists (DESTRUCTIVE)
#   ./setup.sh --uninstall              # remove everything installed by setup.sh
#
# Re-running setup.sh on an existing installation is SAFE by default:
# existing plists, venvs, and cloned repos are preserved. Pass --force to
# overwrite existing launchd plists (will replace any customized service).

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HOME}/.config/opencode"
SKILL_DIR="${CONFIG_DIR}/skills/talk"
VENV_DIR="${CONFIG_DIR}/tts-venv"
PYTHON="${VENV_DIR}/bin/python"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"

# Backend install paths
PARAKEET_DIR="${CONFIG_DIR}/parakeet-stt"
PARAKEET_VENV="${PARAKEET_DIR}/.venv"
PARAKEET_PORT="${PARAKEET_PORT:-5093}"

SUPERTONIC_DIR="${CONFIG_DIR}/supertonic-tts"
SUPERTONIC_VENV="${SUPERTONIC_DIR}/.venv"
# Default 8766 to coexist with the existing Chatterbox TTS server on :8765.
# Override with SUPERTONIC_PORT=8765 if you want to use Supertonic in place
# of Chatterbox (and stop the tts-server plist).
SUPERTONIC_PORT="${SUPERTONIC_PORT:-8766}"

# Colors
info()  { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[setup]\033[0m \342\234\223 %s\n" "$*"; }
warn()  { printf "\033[1;33m[setup]\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31m[setup]\033[0m %s\n" "$*"; }

# --- Parse flags -------------------------------------------------------------
SKIP_PARAKEE=false
SKIP_SUPERTONIC=false
SKIP_VOICES=false
VENV_ONLY=false
FORCE=false
UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --skip-parakeet)   SKIP_PARAKEE=true ;;
        --skip-supertonic) SKIP_SUPERTONIC=true ;;
        --skip-voices)     SKIP_VOICES=true ;;
        --venv-only)       VENV_ONLY=true ;;
        --force|-f)        FORCE=true ;;
        --uninstall)       UNINSTALL=true ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *) warn "Unknown flag: $arg (use --help)" ;;
    esac
done

# --- Uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" = true ]; then
    info "── Uninstalling OpenCode Voice Service ──────────────────────"

    for label in com.opencode.parakeet-stt com.opencode.supertonic com.opencode.tts-server; do
        plist="$LAUNCHD_DIR/$label.plist"
        if [ -f "$plist" ]; then
            if launchctl list 2>/dev/null | grep -q "$label"; then
                launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
                    || launchctl unload "$plist" 2>/dev/null \
                    || true
                ok "launchd: $label stopped"
            fi
            if [ "$FORCE" = true ]; then
                rm -f "$plist"
                ok "removed: $plist"
            else
                warn "kept plist (use --force to remove): $plist"
            fi
        fi
    done

    warn "Backend directories NOT removed (manual cleanup):"
    warn "  rm -rf $PARAKEET_DIR"
    warn "  rm -rf $SUPERTONIC_DIR"
    warn "  rm -rf $VENV_DIR"
    warn "  rm -rf $SKILL_DIR"
    warn "To remove everything: ./setup.sh --uninstall --force"
    exit 0
fi

# =============================================================================
# Step 1: Python venv (voice core — Silero VAD, sounddevice, torch, ONNX)
# =============================================================================
if [ -d "$VENV_DIR" ]; then
    info "Venv exists at $VENV_DIR"
    PY_VER=$("$VENV_DIR/bin/python" --version 2>&1 | sed -n 's/.* \([0-9]*\.[0-9]*\).*/\1/p')
    if [ -n "$PY_VER" ]; then
        PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
        PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
        if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 11 ]; }; then
            warn "Python $PY_VER < 3.11, recreating venv"
            rm -rf "$VENV_DIR"
        fi
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python 3.12 venv at $VENV_DIR..."
    if command -v uv &>/dev/null; then
        uv venv --python 3.12 "$VENV_DIR" 2>/dev/null || uv venv "$VENV_DIR" 2>/dev/null || {
            python3.12 -m venv "$VENV_DIR" 2>/dev/null || python3 -m venv "$VENV_DIR"
        }
    elif python3.12 -m venv "$VENV_DIR" 2>/dev/null; then
        :
    else
        python3 -m venv "$VENV_DIR"
    fi
    ok "Voice venv created"
fi

# --- Step 2: Install Python packages (voice core) ----------------------------
info "Installing voice core Python dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip setuptools wheel 2>/dev/null

"$VENV_DIR/bin/pip" install --quiet \
    silero-vad \
    sounddevice \
    onnxruntime \
    torch \
    torchaudio \
    numpy \
    2>&1 | grep -v "^$" || true

ok "Voice core dependencies installed"

if [ "$VENV_ONLY" = true ]; then
    ok "Venv-only setup complete"
    exit 0
fi

# =============================================================================
# Step 3: Install Parakeet STT Backend (ONNX-based, :5093)
# =============================================================================
install_parakeet() {
    if [ "$SKIP_PARAKEE" = true ]; then
        info "Skipping Parakeet STT (--skip-parakeet)"
        return
    fi

    info "── Parakeet STT Backend (ONNX) ────────────────────────────────"

    # Clone or update
    if [ -d "$PARAKEET_DIR/.git" ]; then
        info "Parakeet repo exists, pulling latest..."
        git -C "$PARAKEET_DIR" pull --ff-only 2>&1 | sed 's/^/  /'
    else
        info "Cloning Parakeet STT repo..."
        rm -rf "$PARAKEET_DIR"
        git clone https://github.com/groxaxo/parakeet-tdt-0.6b-v3-fastapi-openai "$PARAKEET_DIR" 2>&1 | sed 's/^/  /'
    fi

    # Create venv
    if [ ! -d "$PARAKEET_VENV" ]; then
        info "Creating Parakeet venv..."
        python3 -m venv "$PARAKEET_VENV"
        ok "Parakeet venv created"
    fi

    # Install: ONNX runtime CPU variant (macOS doesn't have onnxruntime-gpu)
    info "Installing Parakeet dependencies..."
    "$PARAKEET_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null

    # macOS: use onnxruntime (no GPU variant available)
    if [ "$(uname -s)" = "Darwin" ]; then
        sed 's/onnxruntime-gpu==1.26.0/onnxruntime/' "$PARAKEET_DIR/requirements.txt" > "$PARAKEET_DIR/requirements-darwin.txt"
        REQ_FILE="$PARAKEET_DIR/requirements-darwin.txt"
    else
        REQ_FILE="$PARAKEET_DIR/requirements.txt"
    fi

    "$PARAKEET_VENV/bin/pip" install --quiet -r "$REQ_FILE" 2>&1 | grep -v "^$" || true

    # Install server.py deps (uvicorn + FastAPI)
    "$PARAKEET_VENV/bin/pip" install --quiet \
        uvicorn[standard] \
        fastapi \
        python-multipart \
        silero-vad \
        2>&1 | grep -v "^$" || true

    ok "Parakeet dependencies installed"

    # Install launchd plist
    info "Installing Parakeet launchd plist..."
    PARAKEE_PLIST="$LAUNCHD_DIR/com.opencode.parakeet-stt.plist"

    # Detect existing working service (e.g. precompiled speech-server).
    # If the existing plist does NOT point at our Python venv, leave it
    # alone — the user has a working STT service already. We install
    # under a separate label so both can coexist (e.g. for migration).
    if [ -f "$PARAKEE_PLIST" ] && ! grep -q "$PARAKEET_VENV" "$PARAKEE_PLIST" 2>/dev/null; then
        if grep -q "/Users/op/bin/speech-server\|speech-server" "$PARAKEE_PLIST" 2>/dev/null; then
            warn "Existing speech-server install detected at $PARAKEE_PLIST"
            warn "Skipping plist overwrite (use --force to replace with ONNX server)"
        else
            warn "Existing plist at $PARAKEE_PLIST is unrelated to ONNX backend"
            warn "Skipping overwrite (use --force to replace)"
        fi
    elif [ -f "$REPO_DIR/launchd/com.opencode.parakeet-stt.plist" ]; then
        sed "s|HOME_PLACEHOLDER|$HOME|g" \
            "$REPO_DIR/launchd/com.opencode.parakeet-stt.plist" > "$PARAKEE_PLIST"
        ok "Parakeet launchd plist installed to $PARAKEE_PLIST"
    else
        warn "Parakeet plist missing — creating from template"
        cat > "$PARAKEE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.opencode.parakeet-stt</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PARAKEET_VENV/bin/python</string>
        <string>$PARAKEET_DIR/server.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$PARAKEET_VENV/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>PARAKEET_PORT</key>
        <string>$PARAKEET_PORT</string>
        <key>PARAKEET_USE_GPU</key>
        <string>false</string>
        <key>PARAKEET_DEFAULT_MODEL</key>
        <string>parakeet-tdt-0.6b-v3</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/parakeet-stt.log</string>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/parakeet-stt.log</string>
    <key>WorkingDirectory</key>
    <string>$PARAKEET_DIR</string>
</dict>
</plist>
PLIST
        ok "Parakeet launchd plist created at $LAUNCHD_DIR/com.opencode.parakeet-stt.plist"
    fi
}

# =============================================================================
# Step 4: Install Supertonic TTS Backend (ONNX-based, :8766)
# =============================================================================
install_supertonic() {
    if [ "$SKIP_SUPERTONIC" = true ]; then
        info "Skipping Supertonic TTS (--skip-supertonic)"
        return
    fi

    info "── Supertonic TTS Backend (ONNX) ──────────────────────────────"

    # Clone or update
    if [ -d "$SUPERTONIC_DIR/.git" ]; then
        info "Supertonic repo exists, pulling latest..."
        git -C "$SUPERTONIC_DIR" pull --ff-only 2>&1 | sed 's/^/  /'
    else
        info "Cloning Supertonic Express repo..."
        rm -rf "$SUPERTONIC_DIR"
        git clone https://github.com/groxaxo/supertonic-express "$SUPERTONIC_DIR" 2>&1 | sed 's/^/  /'
    fi

    # Create venv
    if [ ! -d "$SUPERTONIC_VENV" ]; then
        info "Creating Supertonic venv..."
        python3 -m venv "$SUPERTONIC_VENV"
        ok "Supertonic venv created"
    fi

    # Install dependencies
    info "Installing Supertonic dependencies..."
    "$SUPERTONIC_VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null

    "$SUPERTONIC_VENV/bin/pip" install --quiet \
        -r "$SUPERTONIC_DIR/py/requirements.txt" \
        2>&1 | grep -v "^$" || true

    # Also install huggingface_hub for model download
    "$SUPERTONIC_VENV/bin/pip" install --quiet \
        huggingface-hub \
        transformers \
        2>&1 | grep -v "^$" || true

    ok "Supertonic dependencies installed"

    # Download ONNX model if not present
    local ONNX_DIR="$SUPERTONIC_DIR/assets"
    if [ ! -f "$ONNX_DIR/model_q4.onnx" ] && [ ! -f "$ONNX_DIR/model.onnx" ]; then
        info "Downloading Supertonic ONNX model (~500MB, one-time)..."
        mkdir -p "$ONNX_DIR"
        "$SUPERTONIC_VENV/bin/python" -c "
from huggingface_hub import snapshot_download
print('Downloading Supertonic-TTS-2-ONNX from Hugging Face...')
snapshot_download('onnx-community/Supertonic-TTS-2-ONNX', local_dir='$ONNX_DIR', ignore_patterns=['*.md','.gitattributes'])
print('Model download complete.')
" || warn "Model download failed — run setup.sh again or download manually"
        ok "Supertonic ONNX model downloaded to $ONNX_DIR"
    else
        ok "Supertonic ONNX model already present at $ONNX_DIR"
    fi

    # Install launchd plist
    info "Installing Supertonic launchd plist..."
    SUPERTONIC_PLIST="$LAUNCHD_DIR/com.opencode.supertonic.plist"

    # The Chatterbox TTS server in com.opencode.tts-server.plist uses
    # port 8765. Supertonic defaults to 8766 so the two can coexist on
    # different ports with different labels. To use Supertonic in place
    # of Chatterbox, run with SUPERTONIC_PORT=8765 and stop the
    # com.opencode.tts-server plist manually.
    if [ -f "$REPO_DIR/launchd/com.opencode.supertonic.plist" ]; then
        sed "s|HOME_PLACEHOLDER|$HOME|g" \
            "$REPO_DIR/launchd/com.opencode.supertonic.plist" > "$SUPERTONIC_PLIST"
        ok "Supertonic launchd plist installed to $SUPERTONIC_PLIST"
    else
        warn "Supertonic plist missing — creating from template"
        cat > "$SUPERTONIC_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.opencode.supertonic</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SUPERTONIC_VENV/bin/python</string>
        <string>-m</string>
        <string>uvicorn</string>
        <string>api.src.main:app</string>
        <string>--host</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>$SUPERTONIC_PORT</string>
        <string>--app-dir</string>
        <string>$SUPERTONIC_DIR/py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$SUPERTONIC_VENV/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>ONNX_DIR</key>
        <string>$SUPERTONIC_DIR/assets</string>
        <key>VOICE_STYLES_DIR</key>
        <string>$SUPERTONIC_DIR/assets</string>
        <key>USE_GPU</key>
        <string>false</string>
        <key>LOG_LEVEL</key>
        <string>INFO</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/supertonic.log</string>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/supertonic.log</string>
    <key>WorkingDirectory</key>
    <string>$SUPERTONIC_DIR</string>
</dict>
</plist>
PLIST
        ok "Supertonic launchd plist created at $LAUNCHD_DIR/com.opencode.supertonic.plist"
    fi
}

# --- Run backend installations in parallel -----------------------------------
install_parakeet &
PARAKEE_PID=$!
install_supertonic &
SUPERTONIC_PID=$!
wait $PARAKEE_PID $SUPERTONIC_PID

# =============================================================================
# Step 5: Install service files to OpenCode skill directory
# =============================================================================
info "Installing service files to $SKILL_DIR..."
mkdir -p "$SKILL_DIR"

cp "$REPO_DIR/service/vad_recorder.py" "$SKILL_DIR/vad_recorder.py"
cp "$REPO_DIR/service/talk.sh" "$SKILL_DIR/talk.sh"
cp "$REPO_DIR/service/tts.sh" "$SKILL_DIR/tts.sh"
cp "$REPO_DIR/service/tts_lang.sh" "$SKILL_DIR/tts_lang.sh"
cp "$REPO_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"

chmod +x "$SKILL_DIR/vad_recorder.py" "$SKILL_DIR/talk.sh" "$SKILL_DIR/tts.sh" "$SKILL_DIR/tts_lang.sh"
ok "Service files installed to $SKILL_DIR"

# Backward compat: tts.sh at config root
cp "$REPO_DIR/service/tts.sh" "$CONFIG_DIR/tts.sh"
cp "$REPO_DIR/service/tts_lang.sh" "$CONFIG_DIR/tts_lang.sh"
chmod +x "$CONFIG_DIR/tts.sh" "$CONFIG_DIR/tts_lang.sh"
ok "TTS wrapper + lang helper installed to $CONFIG_DIR"

# =============================================================================
# Step 6: Install launchd plists from repo (if present)
# =============================================================================
# SAFETY: this step is NON-DESTRUCTIVE by default. Existing plists are
# preserved unless --force is passed. This protects pre-existing services
# (e.g. a working speech-server install on com.opencode.parakeet-stt, or
# a custom TTS engine on com.opencode.tts-server) from being clobbered.
if [ -d "$REPO_DIR/launchd" ]; then
    for src_plist in "$REPO_DIR"/launchd/*.plist; do
        [ -f "$src_plist" ] || continue
        name=$(basename "$src_plist")
        dst_plist="$LAUNCHD_DIR/$name"
        if [ -f "$dst_plist" ] && [ "$FORCE" = false ]; then
            warn "Skipping $name (already exists, use --force to overwrite)"
            continue
        fi
        sed "s|HOME_PLACEHOLDER|$HOME|g" "$src_plist" > "$dst_plist"
        if [ -f "$dst_plist" ] && [ "$FORCE" = true ] && [ "$name" != "${name%.plist}.plist" ]; then
            : # never reached (defensive)
        fi
        ok "Launchd plist installed: $name"
    done
fi

# =============================================================================
# Step 7: Generate reference voices (unless skipped)
# =============================================================================
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
        info "Generating Spanish reference voice (Monica)..."
        say -v "Mónica" -o /tmp/opencode-ref.aiff \
            "Hola, soy tu asistente de inteligencia artificial." 2>/dev/null
        ffmpeg -i /tmp/opencode-ref.aiff -ar 22050 -ac 1 \
            "$CONFIG_DIR/ref_voice_es.wav" -y 2>/dev/null || {
            warn "Could not generate Spanish reference voice (ffmpeg or Monica voice missing?)"
        }
        rm -f /tmp/opencode-ref.aiff
        [ -f "$CONFIG_DIR/ref_voice_es.wav" ] && ok "Spanish reference voice created"
    else
        info "Spanish reference voice already exists"
    fi
fi

# =============================================================================
# Step 8: Load launchd services (start them if not running)
# =============================================================================
info "Loading launchd services..."
launchctl_load_or_kick() {
    local label="$1"
    local plist="$LAUNCHD_DIR/$label.plist"
    if [ ! -f "$plist" ]; then
        return 0
    fi
    if launchctl list 2>/dev/null | grep -q "$label"; then
        launchctl kickstart -k "gui/$(id -u)/$label" 2>/dev/null || launchctl load "$plist" 2>/dev/null || true
        ok "$label: restarted"
    else
        launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load "$plist" 2>/dev/null || true
        ok "$label: started"
    fi
}

launchctl_load_or_kick "com.opencode.parakeet-stt"
launchctl_load_or_kick "com.opencode.supertonic"
launchctl_load_or_kick "com.opencode.tts-server"

# =============================================================================
# Summary
# =============================================================================
echo ""
info "── Setup Complete ─────────────────────────────────────────────"
echo ""
echo "  Voice skill:   $SKILL_DIR/talk.sh"
echo "  VAD engine:    $SKILL_DIR/vad_recorder.py"
echo "  TTS CLI:       $CONFIG_DIR/tts.sh"
echo "  Voice venv:    $VENV_DIR"
echo ""
echo "  Backends (launchd auto-start):"
echo "    STT — Parakeet ONNX       :${PARAKEET_PORT}  $(launchctl list 2>/dev/null | grep -q com.opencode.parakeet-stt && echo '✓ loaded' || echo 'not loaded')  log: ${CONFIG_DIR}/parakeet-stt.log"
echo "    TTS — Supertonic ONNX     :${SUPERTONIC_PORT}  $(launchctl list 2>/dev/null | grep -q com.opencode.supertonic && echo '✓ loaded' || echo 'not loaded')  log: ${CONFIG_DIR}/supertonic.log"
echo ""
echo "  Quick test:"
echo "    $SKILL_DIR/talk.sh status"
echo "    $SKILL_DIR/talk.sh listen"
echo "    TTS_ENGINE=supertonic $CONFIG_DIR/tts.sh 'Hello'"
echo ""
echo "  Engines (TTS_ENGINE=):  xai   neutts   supertonic   vibevoice"
echo "  STT engine:             parakeet ONNX (local, :${PARAKEET_PORT})"
echo ""
echo "───────────────────────────────────────────────────────────────"
