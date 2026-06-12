# Benchmarks

Reproducible CPU benchmark for the voice stack (Silero VAD, Parakeet STT,
Supertonic 3 TTS). It measures against the **running** local services, so make
sure they're up (they auto-start after `setup.sh`).

```bash
# default: STT :5093, TTS :8766, voice F4, 5 runs each
python benchmarks/run_benchmark.py

# options
python benchmarks/run_benchmark.py \
  --tts-url http://127.0.0.1:8766 \
  --stt-url http://127.0.0.1:5093 \
  --voice F4 --runs 5 --out benchmarks/RESULTS.md
```

Run it with the installed voice venv (`~/.config/opencode/tts-venv/bin/python`)
to include the Silero VAD micro-benchmark; otherwise the HTTP STT/TTS numbers are
still measured and the VAD line is skipped.

Latest results for the reference machine are in [`RESULTS.md`](RESULTS.md).

## TTS backend comparison

Compare the Supertonic backends head-to-head (CPU only, identical sentences and
methodology). Needs both servers up — Supertonic 3 on `:8766` and the optional
Supertonic 2 on `:8880` (`bash integrations/supertonic2/install.sh`).

```bash
python benchmarks/compare_tts_backends.py     # writes benchmarks/TTS_BACKENDS.md
```

Latest comparison: [`TTS_BACKENDS.md`](TTS_BACKENDS.md).
