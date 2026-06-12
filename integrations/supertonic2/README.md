# Supertonic 2 — optional TTS backend

[Supertonic Express 2](https://github.com/groxaxo/supertonic-express) is a
lightning-fast, on-device TTS built on the
[`onnx-community/Supertonic-TTS-2-ONNX`](https://huggingface.co/onnx-community/Supertonic-TTS-2-ONNX)
model — only **66M parameters**, ONNX, **CPU-only**, and multilingual
(English, Korean, Spanish, Portuguese, French).

It exposes the **same OpenAI-compatible `/v1/audio/speech` API** as the default
Supertonic 3 backend, so the voice pipeline (`tts.sh`, the `talk` skill, the
dashboard) drives it with no code changes — you just pick it with
`TTS_ENGINE=supertonic2`.

It runs on its **own port (`:8880`)**, so it coexists with Supertonic 3
(`:8766`). Install both and switch whenever you like.

## Install

```bash
bash integrations/supertonic2/install.sh
```

This clones the repo into `~/.config/opencode/supertonic2-tts`, builds a venv,
downloads the ONNX model from Hugging Face, and registers an auto-start service
(`systemd --user` on Linux, `launchd` on macOS) listening on `:8880`.

Flags:

| Flag | Effect |
|------|--------|
| `--yes` | No prompts |
| `--port 8881` | Serve on a different port |
| `--skip-model` | Don't (re)download the model |
| `--uninstall` | Stop the service and remove the install dir |

## Use it

```bash
# One-off
TTS_ENGINE=supertonic2 ~/.config/opencode/tts.sh "Hola, soy Supertonic dos."

# Make it the default — add to ~/.config/opencode/.env or your shell
TTS_ENGINE=supertonic2
```

### Tunables (env vars, read by `tts.sh`)

| Var | Default | Notes |
|-----|---------|-------|
| `SUPERTONIC2_URL` | `http://127.0.0.1:8880` | Server endpoint |
| `SUPERTONIC2_VOICE` | `M1` | `F1`–`F5` / `M1`–`M5` |
| `SUPERTONIC2_STEPS` | follows `TTS_QUALITY` (8 normal / 20 high) | Denoising steps, 1–20 |
| `SUPERTONIC2_SPEED` | `1.05` | Speed multiplier |

## Fallback behaviour

Selecting `TTS_ENGINE=supertonic2` keeps the project's "local engines before the
cloud" policy:

```
supertonic2 → supertonic → neutts → xai (last resort)
```

If the Supertonic 2 server is down, `tts.sh` transparently falls back to
Supertonic 3, then NeuTTS, then xAI.

## Manage the service

```bash
# Linux
systemctl --user status opencode-supertonic2
systemctl --user restart opencode-supertonic2
journalctl --user -u opencode-supertonic2 -f      # or: tail -f ~/.config/opencode/supertonic2.log

# macOS
launchctl kickstart -k gui/$(id -u)/com.opencode.supertonic2
tail -f ~/.config/opencode/supertonic2.log
```

## Uninstall

```bash
bash integrations/supertonic2/install.sh --uninstall
```
