#!/usr/bin/env python3
"""VAD-driven voice activity recorder using Silero VAD.

Models OpenVoiceApp endpointing:
- 512-sample frames @ 16kHz (~32ms per frame)
- Silero VAD for speech detection
- Configurable trailing silence threshold (default 500ms)
- Pre-speech audio padding for natural starts
- Ring buffer avoids unbounded memory growth
- Idle timeout exits cleanly if no speech detected
- Thread-safe state via threading primitives

Protocol (JSON lines on stdout):
  {"event":"listening"}
  {"event":"speech_end","file":"/tmp/opencode-turn.wav","duration_ms":2500}
  {"event":"idle_timeout","elapsed_s":30}

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
import threading
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


def unique_output_path(output_dir: str, output_file: str) -> str:
    """Generate a unique output path using PID + timestamp to avoid collisions."""
    stem = Path(output_file).stem
    suffix = Path(output_file).suffix or ".wav"
    unique_name = f"{stem}-{os.getpid()}-{int(time.time() * 1000) % 100000}{suffix}"
    return str(Path(output_dir) / unique_name)


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
    """Find a suitable microphone device index (cross-platform).

    Never selects virtual/remote audio adapters (NoMachine, VirtualBox, VMware).

    Priority:
      1. Substring match on --mic-query (if provided), skipping blocked devices.
      2. Platform default: MacBook Air Microphone (macOS), or first non-blocked device.
      3. First non-blocked input device.
      4. Absolute fallback: first input device of any kind.
    """
    import platform as _platform
    devices = sd.query_devices()

    _BLOCKED = ("nomachine", "virtualbox", "vmware", "virtual audio", "vb-audio")

    def _is_blocked(name: str) -> bool:
        n = name.lower()
        return any(b in n for b in _BLOCKED)

    # 1. Query match, skip blocked devices
    if query:
        q = query.lower()
        for i, dev in enumerate(devices):
            if dev["max_input_channels"] <= 0:
                continue
            name = dev["name"]
            if q in name.lower() and not _is_blocked(name):
                return i

    # 2. macOS: prefer built-in MacBook microphone
    if _platform.system() == "Darwin":
        for i, dev in enumerate(devices):
            if dev["max_input_channels"] > 0:
                name = dev["name"]
                if "macbook" in name.lower() and "microphone" in name.lower() and not _is_blocked(name):
                    return i

    # 3. First non-blocked input device (works on Linux, Windows, macOS)
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] > 0:
            if not _is_blocked(dev["name"]):
                return i

    # 4. Absolute fallback
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

    Thread-safe: uses threading.Event for stop signaling and
    threading.Lock for shared state accessed from the audio callback.

    Usage:
        recorder = VADRecorder(args)
        recorder.run()
    """

    def __init__(self, args):
        self.args = args
        self.output_path = unique_output_path(args.output_dir, args.output_file)
        self.pre_speech_padding = int(args.pre_speech_ms * SAMPLE_RATE / 1000)
        self.max_duration_frames = int(args.max_duration_s * SAMPLE_RATE / FRAME_SIZE)

        self.vad = None
        self.ring = RingBuffer(capacity_frames=3000)
        self.stream = None

        # Thread-safe state: audio_callback runs on audio thread
        self._stop_event = threading.Event()
        self._lock = threading.Lock()
        self.speech_active = False
        self.speech_start_sample = 0
        self.frames_since_speech = 0
        self._heard_speech = False  # for idle timeout tracking
        self._listen_start = 0.0
        self._ignore_until = 0.0
        self._vad_offset = 0  # ring-buffer sample count at VAD reset (fixes coordinate mismatch)

    @property
    def _stop_requested(self):
        return self._stop_event.is_set()

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
        if self._ignore_until and time.time() < self._ignore_until:
            return
        if self._ignore_until:
            self._ignore_until = 0.0
            # Capture VAD reset offset: ring._total includes the current frame.
            # VAD.reset_states() zeroes current_sample, so VAD coordinates restart
            # from the first sample of this frame = ring._total - FRAME_SIZE.
            self._vad_offset = self.ring._total - FRAME_SIZE
            self.vad.reset_states()
            with self._lock:
                self.speech_active = False
                self.frames_since_speech = 0

        tensor = torch.from_numpy(frame).unsqueeze(0)
        result = self.vad(tensor)

        with self._lock:
            if self.speech_active:
                self.frames_since_speech += 1
                if self.frames_since_speech > self.max_duration_frames:
                    end_sample = self.ring.first_sample + sum(len(f) for f in self.ring.frames)
                    self._finalize_turn(end_sample + self._vad_offset, reason="max_duration")
                    self.speech_active = False

            if result is not None:
                if "start" in result:
                    self.speech_active = True
                    self.speech_start_sample = result["start"] + self._vad_offset
                    self.frames_since_speech = 0
                    self._heard_speech = True
                    # Barge-in mode: just detect speech start and exit
                    if self.args.barge_in:
                        emit_json("barge_in", sample=result["start"])
                        self._stop_event.set()
                        return
                elif "end" in result:
                    self._finalize_turn(result["end"] + self._vad_offset)
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
            self._stop_event.set()

        self.vad.reset_states()
        self.ring.clear()
        self.frames_since_speech = 0

    def _check_idle_timeout(self) -> bool:
        """Check if idle timeout has been exceeded (no speech heard). Returns True if timed out."""
        idle_timeout = getattr(self.args, 'idle_timeout_s', 0)
        if idle_timeout <= 0:
            return False
        if self._heard_speech:
            return False
        elapsed = time.time() - self._listen_start
        if elapsed >= idle_timeout:
            emit_json("idle_timeout", elapsed_s=round(elapsed, 1))
            return True
        return False

    def audio_callback(self, indata, frames, time_info, status):
        """sounddevice.InputStream callback — called from audio thread."""
        if self._stop_event.is_set():
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
        if self.args.ready_delay_ms > 0:
            self._ignore_until = time.time() + self.args.ready_delay_ms / 1000.0
        self._listen_start = time.time()
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
            # Unified loop for both oneshot and continuous modes
            # Uses polling with sd.sleep instead of signal.pause()
            # so it works reliably across platforms and checks idle timeout
            while not self._stop_event.is_set():
                sd.sleep(100)
                if self._check_idle_timeout():
                    self._stop_event.set()
                    break


def main():
    p = argparse.ArgumentParser(description="Silero VAD voice recorder")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--oneshot", action="store_true", default=True,
                       help="Record one turn and exit (default)")
    mode.add_argument("--continuous", action="store_true",
                       help="Loop forever, output JSON per turn")
    p.add_argument("--output-dir", default="/tmp",
                   help="Directory for WAV files")
    p.add_argument("--output-file", default="opencode-turn.wav",
                   help="WAV filename (PID+timestamp appended for uniqueness)")
    p.add_argument("--min-silence-ms", type=int, default=500,
                   help="Silence after speech to end turn (default: 500ms)")
    p.add_argument("--vad-threshold", type=float, default=0.5,
                   help="VAD speech probability threshold (default: 0.5)")
    p.add_argument("--pre-speech-ms", type=int, default=800,
                   help="Audio before detected speech to include (default: 400ms)")
    p.add_argument("--ready-delay-ms", type=int, default=0,
                   help="Ignore mic/VAD for N ms after start (post ready-cue)")
    p.add_argument("--max-duration-s", type=float, default=30,
                   help="Max recording duration (default: 30s)")
    p.add_argument("--idle-timeout-s", type=float, default=0,
                   help="Exit if no speech detected within N seconds (0=disabled)")
    p.add_argument("--mic-device", type=int, default=None,
                   help="Audio input device index")
    p.add_argument("--mic-query", default=None,
                   help="Substring match for mic device name")
    p.add_argument("--list-devices", action="store_true",
                   help="List input devices and exit")
    p.add_argument("--print-selected-mic", action="store_true",
                   help="Print the mic that find_mic() + --mic-query would select and exit")
    p.add_argument("--barge-in", action="store_true",
                   help="Detect speech start only (for interrupt detection), then exit")
    p.add_argument("--debug", action="store_true",
                   help="Debug logging to stderr")

    args = p.parse_args()

    if args.list_devices:
        list_devices()
        sys.exit(0)

    if args.print_selected_mic:
        dev_idx = args.mic_device
        if dev_idx is None:
            dev_idx = find_mic(args.mic_query)
        if dev_idx is not None:
            try:
                info = sd.query_devices(dev_idx)
                name = info.get("name", "?")
                ins = int(info.get("max_input_channels", 0))
                sr = int(info.get("default_samplerate", 0))
                print(f"[{dev_idx}] {name}  inputs={ins}  default_sr={sr}")
            except Exception as e:
                print(f"[{dev_idx}] (query error: {e})")
        else:
            print("No suitable input device found")
        sys.exit(0)

    # --continuous overrides --oneshot (mutually exclusive group ensures only one)
    if args.continuous:
        args.oneshot = False

    recorder = VADRecorder(args)
    recorder.run()


if __name__ == "__main__":
    main()
