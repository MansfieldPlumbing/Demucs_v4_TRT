# Demucs v4 TRT

HTDemucs exported to a single-graph ONNX checkpoint, compiled to TensorRT for native Windows inference.

`drums` · `bass` · `other` · `vocals` · `guitar` · `piano`

~5 seconds on an RTX 3090. No Python required at runtime.

---

## What is HTDemucs?

[HTDemucs (Hybrid Transformer Demucs)](https://github.com/facebookresearch/demucs) is Meta AI's state-of-the-art music source separation model, introduced in [*Hybrid Transformers for Music Source Separation* (Rouard et al., ICASSP 2023)](https://arxiv.org/abs/2211.08553). It is the fourth generation of the Demucs family and represents a significant architectural leap over its predecessors.

Where earlier Demucs models processed audio purely in the time domain, HTDemucs runs **two parallel encoders simultaneously** — one operating on the raw waveform, the other on the STFT spectrogram. These two streams cross-communicate at their innermost layers through a **Transformer Encoder with cross-attention**, allowing the model to correlate time-domain and frequency-domain features before decoding. The result is a richer representation than either stream could produce alone, and measurably better separation quality — particularly on instruments like piano and guitar that are spectrally complex but temporally sparse.

The 6-stem variant (`htdemucs_6s`) extends the standard 4-stem separation (drums, bass, other, vocals) with dedicated guitar and piano stems, making it the most capable publicly available separation model for music production use cases.

**Key properties:**
- Dual-path hybrid architecture (time domain + frequency domain, cross-attending)
- Transformer Encoder at the bottleneck — full self-attention across the chunk
- 6-stem output: drums, bass, other, vocals, guitar, piano
- Trained on a large internal dataset; weights released under the Meta AI license
- Reference implementation: [github.com/facebookresearch/demucs](https://github.com/facebookresearch/demucs)

---

## Why is HTDemucs hard to deploy efficiently?

HTDemucs presents three specific problems for high-performance inference:

### 1. The STFT problem

The frequency-domain branch requires STFT and ISTFT operations. These involve **complex-valued tensors**, which ONNX does not natively support. The standard workaround — used by [demucs.onnx](https://github.com/sevagh/demucs.onnx) and similar projects — is to externalize the FFT: run STFT in host code and pass the spectrogram as a second model input alongside the waveform.

This produces a valid ONNX graph, but it comes at a cost. TensorRT only sees the core network. The FFT operations live outside the graph in Python/C++ host code, which means they cannot be fused with the surrounding convolutions. Memory has to move between host and device for every chunk boundary. The optimization budget TensorRT has to work with is fundamentally smaller.

### 2. The size and complexity problem

HTDemucs is a large model. The Transformer Encoder at the bottleneck involves full self-attention across the temporal dimension of the chunk, which is expensive. Naively running it in ONNX Runtime — even with CUDA execution — takes several minutes per song. This is the baseline: correct output, unusable speed.

### 3. The export fragility problem

PyTorch's `torch.onnx.export` does not handle complex tensor operations gracefully. Getting a clean, valid ONNX out of HTDemucs without manually decomposing the STFT into real/imaginary components requires careful wrapper design. Most export attempts either fail outright or produce a graph that runs correctly in ONNX Runtime but fails TensorRT's parser due to unsupported op patterns.

---

## How this repo solves it

### Single-graph export via WaveformOnlyWrapper

Rather than externalizing the FFT, this repo wraps HTDemucs in a `WaveformOnlyWrapper` that calls `model._spec()` **inside the forward pass** before handing off to the model proper. The STFT runs inside the exported graph. TensorRT then receives the complete computation — both encoder branches, all cross-attention, STFT and ISTFT — as a single subgraph.

This matters because TensorRT's optimizer can now see the full dataflow. FFT kernel chains get fused with the surrounding convolutions. The frequency-domain encoder and the time-domain encoder are compiled together. The Transformer layers are optimized as a unit. Nothing crosses the host-device boundary mid-inference.

### TensorRT FP16 compilation

With the complete graph visible, TensorRT compiles the model to FP16 using Tensor Core acceleration. The RTX 30-series (sm86) has 328 Tensor Core units on a 3090; FP16 matrix operations run at roughly 2x the throughput of FP32 on that hardware. The fusion plus precision together account for the difference between several minutes and ~5 seconds.

### The ONNX as canonical checkpoint

`models/demucsv4.onnx` is the **single source of truth** for this repo. It is a full-graph export of `htdemucs_6s` with STFT internalized. All TRT engines are compiled from this file — same weights, same graph, different GPU target. The pre-built `demucsv4_sm86_trt10.15.trt` is simply what that ONNX looks like after TensorRT has compiled and optimized it for Ampere (sm86).

For any other GPU architecture, `build_engine.py` reads the same ONNX and compiles a fresh engine targeting your hardware. The model does not change. Only the compiled representation does.

```
demucsv4.onnx                         ← canonical checkpoint, HuggingFace
    │
    ├─ build_engine.py (sm86) ──────→  demucsv4_sm86_trt10.15.trt   (RTX 30-series)
    ├─ build_engine.py (sm89) ──────→  demucsv4_sm89_trt10.15.trt   (RTX 40-series)
    ├─ build_engine.py (sm75) ──────→  demucsv4_sm75_trt10.15.trt   (RTX 20-series)
    └─ build_engine.py (sm61) ──────→  demucsv4_sm61_trt10.15.trt   (GTX 10-series, FP32)
```

Both the ONNX and the pre-built sm86 engine are distributed via GitHub Releases and HuggingFace. The ONNX can also be reproduced from scratch using `export_htdemucs.py` — no GPU required for export, CPU is sufficient.

---

## Quick Start

### RTX 3090 / 3080 / 3070 / 3060 Ti (sm86) — pre-built engine

Download the [latest release](../../releases/latest), extract, and run:

```powershell
.\Demucs_v4_TRT.exe "song.mp3"
```

Stems land in `.\stems\<song name>\`.

### Other NVIDIA GPUs — build engine first

```powershell
# 1. Clone and run first-time setup
git clone https://github.com/mansfieldPlumbing/Demucs_v4_TRT
cd Demucs_v4_TRT
.\launch.bat

# 2. From the menu: [2] Preflight, then [4] Python environment
# 3. Build an engine for your GPU
& "$env:LOCALAPPDATA\micromamba\micromamba.exe" run -n demucs-trt python build_engine.py

# 4. Run
.\Demucs_v4_TRT.exe "song.mp3"
```

---

## Usage

```
Demucs_v4_TRT.exe <input> [options]

Options:
  -m <model.trt>    TRT engine path (auto-discovers *.trt in models\ if omitted)
  -o <dir>          Output directory  (default: .\stems\<song name>)
  -s                Single-chunk debug mode (first chunk only)

Examples:
  .\Demucs_v4_TRT.exe "song.mp3"
  .\Demucs_v4_TRT.exe "song.mp3" -m models\demucsv4_sm89_trt10.15.trt
  .\Demucs_v4_TRT.exe "song.mp3" -o D:\my_stems
```

Supported input formats: anything Windows Media Foundation decodes — MP3, WAV, FLAC, AAC, M4A.

---

## GPU Compatibility

TRT engines are compiled per GPU architecture. `build_engine.py` auto-detects your GPU and names the output correctly.

| Architecture | Cards | Notes |
|---|---|---|
| sm89 | RTX 4090, 4080, 4070 Ti | Build with `build_engine.py` |
| sm86 | RTX 3090, 3080, 3070, 3060 Ti | ✅ Pre-built included in release |
| sm80 | A100, A6000 | Build with `build_engine.py` |
| sm75 | RTX 2080, 2070, 2060, T4 | Build with `build_engine.py` |
| sm70 | Tesla V100 | Build with `build_engine.py` |
| sm61 | GTX 1080, 1070, 1060 | `build_engine.py --fp32` — no FP16 Tensor Cores on Pascal |
| < sm61 | GTX 900 series and older | ❌ Not supported by TRT 10 |

> **GTX 1060 (sm61) is untested.** Results welcome — open an issue.

---

## Requirements

### PowerShell 7.5+

All scripts require PowerShell 7.5 or later. Windows ships with PS 5.1 — upgrade once:

```powershell
winget install Microsoft.PowerShell
```

> Scripts will hard-exit with a clear message if run under PS 5.

### Runtime (pre-built release)

Nothing. The release bundle is self-contained — NVIDIA runtime DLLs included, .NET runtime embedded in the exe.

### Build dependencies (source builds only)

| Dependency | Version | Notes |
|---|---|---|
| NVIDIA Driver | ≥ 561.0 | https://www.nvidia.com/drivers |
| CUDA Toolkit | ≥ 13.0 | https://developer.nvidia.com/cuda-downloads — custom installer |
| TensorRT SDK | ≥ 10.0 | https://developer.nvidia.com/tensorrt — zip extract |
| VS Build Tools 2022 | C++ workload | `winget install Microsoft.VisualStudio.2022.BuildTools` |
| .NET SDK 9 | ≥ 9.0 | `winget install Microsoft.DotNet.SDK.9` |

Python is **not required at runtime.** It is only needed for engine building and ONNX export, managed via the opt-in `[4] Python environment` step in setup.

---

## Setup

```powershell
git clone https://github.com/mansfieldPlumbing/Demucs_v4_TRT
cd Demucs_v4_TRT

# Double-click launch.bat — or from a terminal:
.\launch.bat
```

`launch.bat` is MOTW-immune and elevates once via UAC to unblock all scripts. It drops into `setup.ps1` — an interactive menu where **every step is opt-in**:

```
  [1]  Unblock scripts      remove Mark of the Web (once after clone)
  [2]  Preflight checks     validate dependencies, discover SDK paths, write config.ini
  [3]  Install dependencies  winget-installable items offered one at a time
  [4]  Python environment   micromamba + demucs-trt conda env (~4-6 GB, optional)
  [5]  Build                compile DLL + exe, bundle NVIDIA runtime DLLs, demo offer
  [Q]  Quit
```

### Building a TRT engine for your GPU

```powershell
& "$env:LOCALAPPDATA\micromamba\micromamba.exe" run -n demucs-trt python build_engine.py
& "$env:LOCALAPPDATA\micromamba\micromamba.exe" run -n demucs-trt python build_engine.py --fp32        # Pascal GPUs (sm61)
& "$env:LOCALAPPDATA\micromamba\micromamba.exe" run -n demucs-trt python build_engine.py --workspace 4 # low VRAM
```

Output is named and written to `models\` automatically: `demucsv4_sm{arch}_trt{version}.trt`

Engine builds take 5–20 minutes depending on GPU and workspace size. This is a one-time cost.

---

## Python Environment

All Python tooling runs in a self-contained [micromamba](https://github.com/mamba-org/micromamba-releases) environment. No system Python, no PATH changes, no conda conflicts.

```
micromamba.exe   →  %LOCALAPPDATA%\micromamba\
demucs-trt env   →  %USERPROFILE%\micromamba\envs\demucs-trt\
```

```powershell
# Shorthand for your PowerShell profile
function mrun { & "$env:LOCALAPPDATA\micromamba\micromamba.exe" run -n demucs-trt @args }

mrun python build_engine.py
mrun python stemsplit.py "song.mp3" --engine models\demucsv4_sm86_trt10.15.trt
```

---

## Reproducing the ONNX Export

```powershell
# Export HTDemucs 6s → ONNX (CPU sufficient, no GPU needed)
mrun python export_htdemucs.py
# → models\demucsv4.onnx

# Compile ONNX → TRT engine for your GPU
mrun python build_engine.py
# → models\demucsv4_sm{arch}_trt{version}.trt
```

The critical detail: `_spec()` runs **inside** the graph via `WaveformOnlyWrapper`. If you substitute a two-input ONNX (waveform + pre-computed spectrogram as separate inputs), TensorRT will not see the FFT operations and kernel fusion will not occur. The graph must be single-input for the optimization to work.

---

## Python Validation

`stemsplit.py` is a reference Python separator that uses identical normalization, chunking, and overlap-add windowing to the C# runtime. Use it to validate a new engine before distributing:

```powershell
mrun python stemsplit.py "song.mp3" --engine models\demucsv4_sm86_trt10.15.trt
mrun python stemsplit.py "song.mp3" --engine models\demucsv4_sm86_trt10.15.trt --single-chunk
```

---

## How It Works

```
song.mp3
  │
  ▼  AudioFileReader + MediaFoundationResampler  (NAudio)
  │  → 44100 Hz · stereo · float32
  │
  ▼  Whole-song normalization  (mean/std of mono mix)
  │
  ▼  Chunked overlap-add inference
  │  chunk = 343980 samples (~7.8s)
  │  25% overlap · linear fade windowing
  │  [1, 2, 343980] → GPU → [1, 6, 2, 343980]
  │
  ▼  demucs_v4_trt.dll  (C++ TRT bridge, P/Invoke from C#)
  │  cudaMemcpyAsync → enqueueV3 → cudaMemcpyAsync
  │
  ▼  Denormalize · overlap-add accumulate · save
  │
  ▼  stems/<song name>/
       drums.wav  bass.wav  other.wav  vocals.wav  guitar.wav  piano.wav
```

---

## Project Structure

```
launch.bat                      MOTW-immune first-run bootstrap — double-click after clone
setup.ps1                       Root orchestrator — opt-in menu, discovers paths, delegates

models/
  .gitkeep                      Keeps folder tracked; contents are git-ignored
  demucsv4.onnx                 Canonical checkpoint — source for all TRT engine builds
  demucsv4_sm86_trt10.15.trt    Pre-built sm86 engine — download from releases

samples/
  NEFFEX - Fight Back.mp3       Reference track (CC BY 3.0) — used for dev and demo

scripts/
  setup_preflight.ps1           Validates dependencies, discovers SDK paths, writes config.ini
  setup_deps.ps1                Offers to install winget-installable dependencies
  setup_python.ps1              Installs micromamba + creates demucs-trt conda env
  build_demucs_v4_trt.ps1       Compiles DLL + exe, bundles DLLs, offers demo on sm86
  publish_release.ps1           Standalone full build + bundle pipeline

src/
  demucs_v4_trt.cpp             C++ TRT bridge → demucs_v4_trt.dll
  Program.cs                    C# host: audio I/O, normalization, chunking, overlap-add
  Demucs_v4_TRT.csproj          .NET 9 self-contained single-file publish

export_htdemucs.py              PyTorch htdemucs_6s → single-graph ONNX (WaveformOnlyWrapper)
build_engine.py                 ONNX → TRT engine (auto-named per GPU arch + TRT version)
stemsplit.py                    Python reference separator / engine validator

python/
  environment.yml               Full conda env spec (recommended)
  requirements.txt              Pip fallback for existing Python envs
```

---

## config.ini

Generated by `setup_preflight.ps1` during `[2] Preflight`. Never committed (git-ignored). Stores machine-local SDK paths used by both the build pipeline and the runtime exe. Your system PATH is never modified — the exe prepends these directories to its own process PATH at startup.

```ini
[machine]
preflight_passed  = true
cuda_root         = C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1
cuda_bin          = C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1\bin\x64
tensorrt_root     = C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT-10.15.1.29
tensorrt_bin      = C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT-10.15.1.29\bin

[runtime]
TRT_BIN  = C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT-10.15.1.29\bin
CUDA_BIN = C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1\bin\x64
```

Re-run `[2] Preflight` to regenerate if SDK paths change.

---

## Author

**Mr. Mansfield** — [github.com/MansfieldPlumbing](https://github.com/MansfieldPlumbing)

> *I fix the pipes.*

Windows GPU tooling, native C++ inference pipelines, and making things that should be fast actually fast.
This repo lives at [github.com/MansfieldPlumbing/Demucs_v4_TRT](https://github.com/MansfieldPlumbing/Demucs_v4_TRT).

---

## Prior Art and Differentiation

This repo builds on and departs from several existing approaches:

**[demucs.onnx](https://github.com/sevagh/demucs.onnx)** (sevagh) — the most complete prior art on native Demucs inference. Takes the two-input approach: STFT/ISTFT are moved outside the model, and the C++ host runs FFT manually before every inference call. Excellent Linux C++ implementation, but the externalized FFT means TensorRT can't see or fuse those operations. This is the baseline this repo improves on — and the reason `WaveformOnlyWrapper` exists.

**Mixxx GSoC 2025** — independently arrived at a self-contained ONNX by rewriting STFT/ISTFT with real-valued tensors rather than wrapping `_spec()`. Targets ONNX Runtime and C++ deployment, not TensorRT, and has no Windows binary release.

**[ZFTurbo/MSS_ONNX_TensorRT](https://github.com/ZFTurbo/MSS_ONNX_TensorRT)** — a general-purpose Python research framework supporting HTDemucs → ONNX → TRT across multiple model types. Still requires Python at runtime; no native Windows binary.

What this repo adds: a single-graph ONNX with STFT internalized for full TRT kernel fusion, compiled to a native Windows exe with no Python dependency at runtime, a bundled pre-built sm86 engine, and a setup system that handles the entire stack from dependency discovery to demo separation.

---

## Acknowledgements

- [Meta AI / Demucs](https://github.com/facebookresearch/demucs) — HTDemucs model, weights, and research
- [demucs.onnx](https://github.com/sevagh/demucs.onnx) — prior art on ONNX export; understanding why the two-input approach blocks TRT fusion was the key insight that led to `WaveformOnlyWrapper`
- [NAudio](https://github.com/naudio/NAudio) — audio I/O
- [NEFFEX](https://www.youtube.com/c/NEFFEX) — *Fight Back* (CC BY 3.0) used as reference track throughout development and bundled as demo

**Paper:** Rouard, S., Massa, F., & Défossez, A. (2023). Hybrid Transformers for Music Source Separation. *ICASSP 2023*. [arXiv:2211.08553](https://arxiv.org/abs/2211.08553)

---

## License

Code and tooling: MIT
HTDemucs model weights: [Meta AI license](https://github.com/facebookresearch/demucs/blob/main/LICENSE)
NEFFEX - Fight Back: [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) — credit NEFFEX
