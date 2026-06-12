#!/usr/bin/env bash
# install.sh — opt-in installer for the Supertonic 2 TTS backend.
#
# Supertonic Express 2 (groxaxo/supertonic-express, model
# onnx-community/Supertonic-TTS-2-ONNX) is a 66M-param, ONNX, CPU-only TTS that
# serves the SAME OpenAI-compatible /v1/audio/speech API as the default
# Supertonic 3 backend — so it slots straight into tts.sh as `TTS_ENGINE=supertonic2`.
# It is multilingual (en/ko/es/pt/fr) and very fast on CPU.
#
# This backend is OPTIONAL and not installed by the main setup.sh. It runs on
# its own port (:8880) so it coexists with Supertonic 3 (:8766) — you can keep
# both and switch with TTS_ENGINE.
#
# What it does:
#   1. Clones (or updates) groxaxo/supertonic-express into the install dir.
#   2. Creates a venv and installs the server deps + huggingface-hub/transformers.
#   3. Downloads the ONNX model (~one-time) from Hugging Face.
#   4. Registers an auto-start service on :8880 (systemd --user on Linux,
#      launchd on macOS) and starts it.
#   5. Smoke-checks the server and prints how to use it.
#
# Usage:
#   bash integrations/supertonic2/install.sh            # install / update
#   bash integrations/supertonic2/install.sh --yes      # no prompts
#   bash integrations/supertonic2/install.sh --port 8881
#   bash integrations/supertonic2/install.sh --skip-model
#   bash integrations/supertonic2/install.sh --uninstall

set -euo pipefail

# --- paths / config ----------------------------------------------------------
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
INSTALL_DIR="${SUPERTONIC2_DIR:-$CONFIG_DIR/supertonic2-tts}"
VENV_DIR="$INSTALL_DIR/.venv"
ASSETS_DIR="$INSTALL_DIR/assets"
REPO_URL="https://github.com/groxaxo/supertonic-express"
HF_MODEL="onnx-community/Supertonic-TTS-2-ONNX"
PORT="${SUPERTONIC2_PORT:-8880}"
LOG_FILE="$CONFIG_DIR/supertonic2.log"
SERVICE_NAME="opencode-supertonic2"
PLIST_LABEL="com.opencode.supertonic2"

# --- options -----------------------------------------------------------------
ASSUME_YES=0
SKIP_MODEL=0
UNINSTALL=0

# --- pretty logging ----------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BLU=$'\033[1;34m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; Z=$'\033[0m'
else
    BLU=""; GRN=""; YLW=""; RED=""; Z=""
fi
info() { printf "%s[supertonic2]%s %s\n" "$BLU" "$Z" "$*"; }
ok()   { printf "%s[supertonic2]%s \xE2\x9C\x93 %s\n" "$GRN" "$Z" "$*"; }
warn() { printf "%s[supertonic2]%s %s\n" "$YLW" "$Z" "$*" >&2; }
die()  { printf "%s[supertonic2]%s %s\n" "$RED" "$Z" "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)     ASSUME_YES=1 ;;
        --port)       PORT="${2:?--port needs a value}"; shift ;;
        --port=*)     PORT="${1#--port=}" ;;
        --skip-model) SKIP_MODEL=1 ;;
        --uninstall)  UNINSTALL=1 ;;
        -h|--help)    usage ;;
        *)            warn "Unknown flag: $1 (use --help)" ;;
    esac
    shift
done

case "$(uname -s 2>/dev/null)" in
    Darwin) PLATFORM="macos" ;;
    *)      PLATFORM="linux" ;;
esac

# =============================================================================
# Uninstall
# =============================================================================
if [ "$UNINSTALL" = 1 ]; then
    info "Uninstalling Supertonic 2 backend…"
    if [ "$PLATFORM" = "linux" ] && command -v systemctl &>/dev/null; then
        systemctl --user disable --now "$SERVICE_NAME.service" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/$SERVICE_NAME.service"
        systemctl --user daemon-reload 2>/dev/null || true
    elif [ "$PLATFORM" = "macos" ]; then
        launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null \
            || launchctl unload "$HOME/Library/LaunchAgents/$PLIST_LABEL.plist" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
    fi
    rm -rf "$INSTALL_DIR"
    ok "Removed service and $INSTALL_DIR"
    info "Note: tts.sh still accepts TTS_ENGINE=supertonic2 but will fall back to other engines."
    exit 0
fi

# =============================================================================
# 1. Clone / update the repo
# =============================================================================
command -v git >/dev/null 2>&1 || die "git not found — install git first."
command -v python3 >/dev/null 2>&1 || die "python3 not found — install Python 3.10+ first."
mkdir -p "$CONFIG_DIR"

if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing checkout in $INSTALL_DIR…"
    git -C "$INSTALL_DIR" pull --ff-only 2>&1 | sed 's/^/  /' || warn "git pull failed — keeping current checkout"
else
    info "Cloning Supertonic Express 2 → $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>&1 | sed 's/^/  /'
fi
[ -f "$INSTALL_DIR/py/requirements.txt" ] || die "Repo layout unexpected: $INSTALL_DIR/py/requirements.txt missing."

# =============================================================================
# 2. venv + dependencies
# =============================================================================
if [ ! -d "$VENV_DIR" ]; then
    info "Creating venv…"
    python3 -m venv "$VENV_DIR"
fi
info "Installing dependencies (this can take a minute)…"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
"$VENV_DIR/bin/pip" install --quiet -r "$INSTALL_DIR/py/requirements.txt" 2>&1 | grep -v "^$" || true
# helper.py loads the tokenizer via transformers + AutoTokenizer; not in requirements.txt.
"$VENV_DIR/bin/pip" install --quiet huggingface-hub transformers 2>&1 | grep -v "^$" || true
ok "Dependencies installed"

# =============================================================================
# 3. Download the ONNX model (one-time)
# =============================================================================
if [ "$SKIP_MODEL" = 1 ]; then
    info "Skipping model download (--skip-model)"
elif [ -f "$ASSETS_DIR/onnx/voice_decoder.onnx" ]; then
    ok "Model already present at $ASSETS_DIR"
else
    info "Downloading $HF_MODEL → $ASSETS_DIR (one-time)…"
    "$VENV_DIR/bin/python" - "$HF_MODEL" "$ASSETS_DIR" <<'PY' 2>&1 | sed 's/^/  /'
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1], local_dir=sys.argv[2])
PY
    [ -f "$ASSETS_DIR/onnx/voice_decoder.onnx" ] \
        && ok "Model ready at $ASSETS_DIR" \
        || die "Model download incomplete — re-run, or fetch manually with huggingface-cli."
fi

# =============================================================================
# 4. Register + start the service
# =============================================================================
EXEC_PY="$VENV_DIR/bin/python"

if [ "$PLATFORM" = "linux" ]; then
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_USER_DIR"
    info "Writing systemd --user unit: $SERVICE_NAME.service (:$PORT)"
    cat > "$SYSTEMD_USER_DIR/$SERVICE_NAME.service" <<SVCEOF
[Unit]
Description=Supertonic 2 TTS Server (ONNX, CPU-only) on :${PORT}
After=network.target

[Service]
Type=simple
ExecStart=${EXEC_PY} -m uvicorn api.src.main:app \\
    --host 0.0.0.0 --port ${PORT} --app-dir ${INSTALL_DIR}/py
WorkingDirectory=${INSTALL_DIR}/py
Restart=always
RestartSec=5
Environment=HOME=${HOME}
Environment=ONNX_DIR=${ASSETS_DIR}
Environment=VOICE_STYLES_DIR=${ASSETS_DIR}
Environment=USE_GPU=false
Environment=SUPERTONIC_ORT_BACKEND=cpu
Environment=PORT=${PORT}
Environment=LOG_LEVEL=INFO
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
SVCEOF
    if command -v systemctl &>/dev/null && systemctl --user status >/dev/null 2>&1; then
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable --now "$SERVICE_NAME.service" 2>/dev/null || true
        ok "systemd: $SERVICE_NAME started (log: $LOG_FILE)"
    else
        warn "systemctl --user not available. Enable manually:"
        warn "  systemctl --user daemon-reload && systemctl --user enable --now $SERVICE_NAME.service"
    fi
else
    LAUNCHD_DIR="$HOME/Library/LaunchAgents"
    PLIST="$LAUNCHD_DIR/$PLIST_LABEL.plist"
    mkdir -p "$LAUNCHD_DIR"
    info "Writing launchd plist: $PLIST_LABEL (:$PORT)"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${EXEC_PY}</string>
        <string>-m</string>
        <string>uvicorn</string>
        <string>api.src.main:app</string>
        <string>--host</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>${PORT}</string>
        <string>--app-dir</string>
        <string>${INSTALL_DIR}/py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>PATH</key>
        <string>${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>ONNX_DIR</key>
        <string>${ASSETS_DIR}</string>
        <key>VOICE_STYLES_DIR</key>
        <string>${ASSETS_DIR}</string>
        <key>USE_GPU</key>
        <string>false</string>
        <key>SUPERTONIC_ORT_BACKEND</key>
        <string>cpu</string>
        <key>PORT</key>
        <string>${PORT}</string>
        <key>LOG_LEVEL</key>
        <string>INFO</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}/py</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl load "$PLIST" 2>/dev/null || true
    ok "launchd: $PLIST_LABEL loaded (log: $LOG_FILE)"
fi

# =============================================================================
# 5. Smoke check
# =============================================================================
info "Waiting for the server to come up on :$PORT…"
URL="http://127.0.0.1:$PORT"
up=0
for _ in $(seq 1 30); do
    if curl -fsS -m 2 "$URL/health" >/dev/null 2>&1 || curl -fsS -m 2 "$URL/" >/dev/null 2>&1; then
        up=1; break
    fi
    sleep 1
done

echo ""
if [ "$up" = 1 ]; then
    ok "Supertonic 2 is up on $URL"
else
    warn "Server not reachable yet — model load can take a while on first boot."
    warn "Check the log: $LOG_FILE"
fi

info "── Done ───────────────────────────────────────────────────────"
echo "  Use it as the TTS engine:"
echo "    TTS_ENGINE=supertonic2 $CONFIG_DIR/tts.sh 'Hola, soy Supertonic dos.'"
echo ""
echo "  Make it the default in $CONFIG_DIR/.env (or your shell):"
echo "    TTS_ENGINE=supertonic2"
echo ""
echo "  Falls back automatically: supertonic2 → supertonic → neutts → xai"
echo "  Coexists with Supertonic 3 (:8766); this one is on :$PORT."
