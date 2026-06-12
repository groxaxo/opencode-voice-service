#!/usr/bin/env python3
"""
TTS backend comparison — CPU only.

Measures the Supertonic backends head-to-head against the *running* local
servers, using the same sentences and methodology as run_benchmark.py:

  * Supertonic 3  — supertonic-express-3 (FP16 ONNX), default :8766
  * Supertonic 2  — supertonic-express  (onnx-community/Supertonic-TTS-2-ONNX), :8880

Both expose the OpenAI-compatible /v1/audio/speech API, so the same request
drives either one. One warm-up call per (backend, steps) is discarded so the
per-voice style cache is primed equally; then `--runs` calls are timed and the
median reported. RTF = synthesis time ÷ audio duration.

Usage:
    python benchmarks/compare_tts_backends.py
    python benchmarks/compare_tts_backends.py \
        --backend "Supertonic 3=http://127.0.0.1:8766" \
        --backend "Supertonic 2=http://127.0.0.1:8880" \
        --voice F4 --runs 5 --out benchmarks/TTS_BACKENDS.md

Pure standard library. Make sure the servers are up (they are CPU-only:
USE_GPU=false), then run.
"""
import argparse, io, json, platform, statistics, subprocess, time, urllib.request, wave
from datetime import datetime, timezone

SENTENCES = {
    "short (10 words)": "Hey, can you run that test for me real quick?",
    "medium (22 words)": "I just finished setting up the local voice pipeline and it "
                          "runs entirely on the CPU without touching the cloud at all.",
    "long (45 words)": "The whole point of this project is privacy and speed on commodity "
                        "hardware. You speak, a neural voice detector catches the end of your "
                        "sentence, a local model transcribes it, your language model answers, "
                        "and a local synthesizer reads the reply back to you.",
}
STEP_PRESETS = [("Normal (8 steps)", 8), ("High (20 steps)", 20)]


def wav_duration(b: bytes) -> float:
    return wave.open(io.BytesIO(b)).getnframes() / wave.open(io.BytesIO(b)).getframerate()


def post_json(url: str, obj: dict, timeout: int = 120):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    t = time.perf_counter()
    body = urllib.request.urlopen(req, timeout=timeout).read()
    return time.perf_counter() - t, body


def cpu_name() -> str:
    try:
        for line in subprocess.check_output(["lscpu"], text=True).splitlines():
            if line.startswith("Model name:"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return platform.processor() or platform.machine()


def bench(url, voice, steps, runs):
    """Return {label: (audio_dur, median_latency_s, rtf)} for one backend+steps."""
    out = {}
    for label, text in SENTENCES.items():
        payload = {"input": text, "voice": voice, "response_format": "wav",
                   "stream": False, "total_steps": steps, "speed": 1.05}
        _, wav = post_json(f"{url}/v1/audio/speech", payload)   # warm-up (discarded)
        times = []
        for _ in range(runs):
            dt, wav = post_json(f"{url}/v1/audio/speech", payload)
            times.append(dt)
        dur = wav_duration(wav)
        med = statistics.median(times)
        out[label] = (dur, med, med / dur)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", action="append", default=[],
                    help='"Label=URL"; repeatable. Defaults to Supertonic 3 + Supertonic 2.')
    ap.add_argument("--voice", default="F4")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--out", default="benchmarks/TTS_BACKENDS.md")
    args = ap.parse_args()

    backends = []
    for spec in (args.backend or ["Supertonic 3=http://127.0.0.1:8766",
                                   "Supertonic 2=http://127.0.0.1:8880"]):
        label, url = spec.split("=", 1)
        backends.append((label.strip(), url.strip()))

    cpu = cpu_name()
    print(f"Host CPU: {cpu}\nRuns per measurement: {args.runs} (median, 1 warm-up discarded)\n")

    # results[steps_label][backend_label] = {sentence: (dur, med, rtf)}
    results = {}
    for steps_label, steps in STEP_PRESETS:
        results[steps_label] = {}
        for label, url in backends:
            print(f"{label} — {steps_label}…")
            results[steps_label][label] = bench(url, args.voice, steps, args.runs)

    # ---- render markdown ----
    L = ["# TTS backend comparison (CPU only)\n"]
    L.append(f"- **Host CPU:** {cpu}")
    L.append("- **Mode:** CPU only, no GPU (`USE_GPU=false` on every server)")
    L.append(f"- **Voice:** {args.voice} · **Runs:** {args.runs} (median, 1 warm-up discarded)")
    L.append(f"- **Date:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}\n")

    L.append("**Backends**")
    for label, url in backends:
        L.append(f"- **{label}** — {url}")
    L.append("")

    labels = [b[0] for b in backends]
    for steps_label, _steps in STEP_PRESETS:
        L.append(f"### {steps_label}")
        header = "| Reply | Audio | " + " | ".join(f"{l} | RTF" for l in labels) + " |"
        sep = "|-------|-------|" + "|".join(["------|-----"] * len(labels)) + "|"
        L.append(header)
        L.append(sep)
        for sentence in SENTENCES:
            dur = results[steps_label][labels[0]][sentence][0]
            cells = [f"{sentence}", f"{dur:.2f}s"]
            for l in labels:
                _, med, rtf = results[steps_label][l][sentence]
                cells.append(f"{med*1000:.0f} ms")
                cells.append(f"{rtf:.3f}")
            L.append("| " + " | ".join(cells) + " |")
        L.append("")

    # ---- speed summary (mean RTF + relative speed of last vs first backend) ----
    if len(labels) >= 2:
        L.append("### Summary — mean RTF across the three replies")
        L.append("| Quality | " + " | ".join(labels) + " | " +
                 f"{labels[-1]} vs {labels[0]} |")
        L.append("|---------|" + "|".join(["------"] * len(labels)) + "|------|")
        for steps_label, _steps in STEP_PRESETS:
            means = {l: statistics.mean(results[steps_label][l][s][2] for s in SENTENCES)
                     for l in labels}
            speed = means[labels[0]] / means[labels[-1]]
            faster = f"{speed:.2f}× faster" if speed >= 1 else f"{1/speed:.2f}× slower"
            row = [steps_label] + [f"{means[l]:.3f}" for l in labels] + [faster]
            L.append("| " + " | ".join(row) + " |")
        L.append("")

    L.append("_RTF = synthesis time ÷ audio duration (lower is faster; <1.0 is faster "
             "than realtime). Both servers run the ONNX CPU backend; no GPU._")

    md = "\n".join(L) + "\n"
    with open(args.out, "w") as f:
        f.write(md)
    print("\n" + md)
    print(f"Wrote {args.out}")


if __name__ == "__main__":
    main()
