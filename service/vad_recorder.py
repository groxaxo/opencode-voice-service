#!/usr/bin/env python3
"""VAD-driven voice activity recorder using Silero VAD.

Models OpenVoiceApp endpointing:
- 512-sample frames @ 16kHz (~32ms per frame)
- Silero VAD for speech detection
- Configurable trailing silence threshold (default 500ms)
- Pre-speech audio padding for natural starts
- Ring buffer avoids unbounded memory growth

Protocol (JSON lines on stdout):
  {"event":"listening"}
  {"event":"speech_end","file":"/tmp/opencode-turn.wav","duration_ms":2500}

--oneshot: record one utterance, exit with path on stdout.
--continuous: loop forever, printing JSON events per turn.
--output-dir: where to save WAV files (default: /tmp)
"""

import argparse
import collections
import json
import os
import signal
import sys
import time
import wave
from pathlib import Path

import numpy as np
import sounddevice as sd
import torch
from silero_vad import VADIterator, load_silero_vad

FRAME_SIZE = 512
SAMPLE_RATE = 16000


class RingBuffer:
    """Fixed-capacity rolling buffer of audio frames.

    Keeps the last N frames for pre-speech padding extraction.
    """
    def __init__(self, capacity_frames=3000):
        self.capacity = capacity_frames
        self.frames: collections.deque[np.ndarray] = collections.deque()
        self._total = 0

    def append(self, frame: np.ndarray):
        self.frames.append(frame.copy())
        self._total += len(frame)
        while len(self.frames) > self.capacity:
            self._total -= len(self.frames[0])
            self.frames.popleft()

    @property
    def first_sample(self) -> int:
        return self._total - sum(len(f) for f in self.frames)

    def slice(self, start_sample: int, end_sample: int) -> np.ndarray:
        pieces = []
        cursor = self.first_sample
        for frame in self.frames:
            f_end = cursor + len(frame)
            if f_end > start_sample and cursor < end_sample:
                s = max(0, start_sample - cursor)
                e = min(len(frame), end_sample - cursor)
                if e > s:
                    pieces.append(frame[s:e])
            cursor += len(frame)
        return np.concatenate(pieces) if pieces else np.array([], dtype=np.float32)

    def clear(self):
        self.frames.clear()
        self._total = 0


def normalize_audio(audio: np.ndarray, target_rms_dbfs: float = -20,
                    max_gain: float = 4, ceiling: float = 0.98) -> np.ndarray:
    """Normalize audio gain to a target RMS level.

    Mirrors OpenVoiceApp's AudioLevelAnalyzer.normalize().
    Applies up to max_gain amplification to reach target RMS,
    then soft-limits to ceiling.
    """
    if len(audio) == 0:
        return audio
    rms = np.sqrt(np.mean(audio ** 2))
    if rms < 1e-10:
        return audio
    target = 10 ** (target_rms_dbfs / 20)
    gain = min(max_gain, target / rms)
    normalized = np.clip(audio * gain, -ceiling, ceiling)
    return normalized


def save_wav(path: str, audio: np.ndarray, normalize: bool = True):
    """Save float32 [-1,1] audio as 16-bit mono WAV."""
    if normalize and len(audio) > 0:
        audio = normalize_audio(audio)
    clipped = np.clip(audio, -1.0, 1.0)
    int_data = (clipped * 32767).astype(np.int16)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(int_data.tobytes())


def list_devices():
    """Print available audio input devices to stderr."""
    devices = sd.query_devices()
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] > 0:
            print(f"[{i}] {dev['name']}  "
                  f"inputs={int(dev['max_input_channels'])}  "
                  f"default_sr={int(dev['default_samplerate'])}",
                  file=sys.stderr)


def find_mic(query=None):
    """Find a suitable microphone device index.

    Priority: query match > MacBook Air Microphone > first input device.
    """
    devices = sd.query_devices()
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] <= 0:
            continue
        if query and query.lower() in dev["name"].lower():
            return i
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] > 0:
            if "macbook air microphone" in dev["name"].lower():
                return i
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] > 0:
            return i
    return None


def emit_json(event, **kwargs):
    """Output a JSON event line to stdout."""
    obj = {"event": event, "timestamp": time.time()}
    obj.update(kwargs)
    print(json.dumps(obj), flush=True)


class VADRecorder:
    """Silero VAD-driven continuous voice recorder.

    Usage:
        recorder = VADRecorder(args)
        recorder.run()
    """

    def __init__(self, args):
        self.args = args
        self.output_path = str(Path(args.output_dir) / args.output_file)
        self.pre_speech_padding = int(args.pre_speech_ms * SAMPLE_RATE / 1000)
        self.max_duration_frames = int(args.max_duration_s * SAMPLE_RATE / FRAME_SIZE)

        self.vad = None
        self.ring = RingBuffer(capacity_frames=3000)
        self.stream = None

        self.speech_active = False
        self.speech_start_sample = 0
        self.frames_since_speech = 0
        self._stop_requested = False

    def load_vad(self):
        """Lazily load the Silero VAD model."""
        model = load_silero_vad()
        self.vad = VADIterator(
            model,
            threshold=self.args.vad_threshold,
            sampling_rate=SAMPLE_RATE,
            min_silence_duration_ms=self.args.min_silence_ms,
            speech_pad_ms=30,
        )

    def process_frame(self, frame: np.ndarray):
        """Feed one 512-sample frame through VAD and update state."""
        self.ring.append(frame)
        tensor = torch.from_numpy(frame).unsqueeze(0)
        result = self.vad(tensor)

        if self.speech_active:
            self.frames_since_speech += 1
            if self.frames_since_speech > self.max_duration_frames:
                end_sample = self.ring.first_sample + sum(len(f) for f in self.ring.frames)
                self._finalize_turn(end_sample, reason="max_duration")
                self.speech_active = False

        if result is not None:
            if "start" in result:
                self.speech_active = True
                self.speech_start_sample = result["start"]
                self.frames_since_speech = 0
            elif "end" in result:
                self._finalize_turn(result["end"])
                self.speech_active = False

    def _finalize_turn(self, end_sample: int, reason=None):
        """Save the recorded utterance and signal completion."""
        start = max(0, self.speech_start_sample - self.pre_speech_padding)
        audio = self.ring.slice(start, end_sample)
        dur_ms = len(audio) / SAMPLE_RATE * 1000

        if dur_ms < 100:
            self.ring.clear()
            return

        save_wav(self.output_path, audio)
        payload = {"file": self.output_path, "duration_ms": round(dur_ms)}
        if reason:
            payload["reason"] = reason
        emit_json("speech_end", **payload)

        if self.args.oneshot:
            self._stop_requested = True

        self.vad.reset_states()
        self.ring.clear()
        self.frames_since_speech = 0

    def audio_callback(self, indata, frames, time_info, status):
        """sounddevice.InputStream callback — called from audio thread."""
        if self._stop_requested:
            raise sd.CallbackStop()

        if status and self.args.debug:
            print(f"[vad] status: {status}", file=sys.stderr)

        mono = indata.ravel().astype(np.float32)
        offset = 0
        while offset + FRAME_SIZE <= len(mono):
            self.process_frame(mono[offset:offset + FRAME_SIZE])
            offset += FRAME_SIZE

    def run(self):
        """Start microphone capture and VAD processing loop."""
        device = self.args.mic_device
        if device is None:
            device = find_mic(self.args.mic_query)
        if device is None:
            emit_json("error", message="No input audio device found")
            sys.exit(1)

        if self.args.debug:
            dev_info = sd.query_devices(device)
            print(f"[vad] device [{device}]: {dev_info['name']}", file=sys.stderr)

        self.load_vad()
        emit_json("listening")

        self.stream = sd.InputStream(
            device=device,
            channels=1,
            samplerate=SAMPLE_RATE,
            blocksize=FRAME_SIZE * 2,
            callback=self.audio_callback,
            dtype=np.float32,
        )

        with self.stream:
            if self.args.oneshot:
                while not self._stop_requested:
                    sd.sleep(100)
            else:
                try:
                    signal.pause()
                except AttributeError:
                    while True:
                        sd.sleep(500)


def main():
    p = argparse.ArgumentParser(description="Silero VAD voice recorder")
    p.add_argument("--oneshot", action="store_true", default=True,
                   help="Record one turn and exit (default)")
    p.add_argument("--continuous", action="store_true",
                   help="Loop forever, output JSON per turn")
    p.add_argument("--output-dir", default="/tmp",
                   help="Directory for WAV files")
    p.add_argument("--output-file", default="opencode-turn.wav",
                   help="WAV filename")
    p.add_argument("--min-silence-ms", type=int, default=500,
                   help="Silence after speech to end turn (default: 500ms)")
    p.add_argument("--vad-threshold", type=float, default=0.5,
                   help="VAD speech probability threshold (default: 0.5)")
    p.add_argument("--pre-speech-ms", type=int, default=400,
                   help="Audio before detected speech to include (default: 400ms)")
    p.add_argument("--max-duration-s", type=float, default=30,
                   help="Max recording duration (default: 30s)")
    p.add_argument("--mic-device", type=int, default=None,
                   help="Audio input device index")
    p.add_argument("--mic-query", default=None,
                   help="Substring match for mic device name")
    p.add_argument("--list-devices", action="store_true",
                   help="List input devices and exit")
    p.add_argument("--debug", action="store_true",
                   help="Debug logging to stderr")

    args = p.parse_args()

    if args.list_devices:
        list_devices()
        sys.exit(0)

    recorder = VADRecorder(args)
    recorder.run()


if __name__ == "__main__":
    main()
