# TTS backend comparison (CPU only)

- **Host CPU:** 12th Gen Intel(R) Core(TM) i7-12700KF
- **Mode:** CPU only, no GPU (`USE_GPU=false` on every server)
- **Voice:** F4 · **Runs:** 5 (median, 1 warm-up discarded)
- **Date:** 2026-06-12 12:47 UTC

**Backends**
- **Supertonic 3** — http://127.0.0.1:8766
- **Supertonic 2** — http://127.0.0.1:8880

### Normal (8 steps)
| Reply | Audio | Supertonic 3 | RTF | Supertonic 2 | RTF |
|-------|-------|------|-----|------|-----|
| short (10 words) | 2.42s | 1984 ms | 0.818 | 777 ms | 0.294 |
| medium (22 words) | 6.55s | 3115 ms | 0.476 | 989 ms | 0.148 |
| long (45 words) | 13.42s | 5439 ms | 0.405 | 1436 ms | 0.095 |

### High (20 steps)
| Reply | Audio | Supertonic 3 | RTF | Supertonic 2 | RTF |
|-------|-------|------|-----|------|-----|
| short (10 words) | 2.42s | 3202 ms | 1.321 | 1316 ms | 0.497 |
| medium (22 words) | 6.55s | 6607 ms | 1.009 | 1917 ms | 0.287 |
| long (45 words) | 13.42s | 11834 ms | 0.882 | 2364 ms | 0.157 |

### Summary — mean RTF across the three replies
| Quality | Supertonic 3 | Supertonic 2 | Supertonic 2 vs Supertonic 3 |
|---------|------|------|------|
| Normal (8 steps) | 0.566 | 0.179 | 3.17× faster |
| High (20 steps) | 1.071 | 0.314 | 3.41× faster |

_RTF = synthesis time ÷ audio duration (lower is faster; <1.0 is faster than realtime). Both servers run the ONNX CPU backend; no GPU._
