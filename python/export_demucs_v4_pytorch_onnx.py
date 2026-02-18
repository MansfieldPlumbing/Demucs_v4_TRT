"""
export_htdemucs.py
------------------
Exports htdemucs_6s (Demucs v4) to a single-input ONNX with the STFT
internalized in the graph — required for TensorRT kernel fusion.

The output ONNX (~240MB) takes a single waveform input [1, 2, 343980]
and returns all 6 stems [1, 6, 2, 343980]. This is different from the
demucs.onnx approach which externalizes the spectrogram as a second input.
Keeping _spec() inside the graph is what allows TRT to fuse the FFT kernels.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SETUP WITH MICROMAMBA  (recommended — keeps this isolated from everything)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Install micromamba if you don't have it:
    https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html

    Windows (PowerShell):
        Invoke-Expression ((Invoke-WebRequest -Uri https://micro.mamba.pm/install.ps1).Content)

Create and activate the environment:
    micromamba create -n demucs-export python=3.11 -c conda-forge -y
    micromamba activate demucs-export

Install dependencies:
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    pip install demucs

Run the export:
    python export_htdemucs.py

Output:
    htdemucs_6s_waveform.onnx  (~240MB)

Then build the TRT engine for your GPU (separate step, needs TensorRT installed):
    python build_engine.py --onnx htdemucs_6s_waveform.onnx

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTE: This export can take a few minutes and uses significant RAM.
      A GPU is not required for the export step itself — CPU is fine.
      The resulting ONNX will be slow on ONNX Runtime. That's expected.
      Speed comes from the TRT compilation step, not from the ONNX.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""

import torch
from demucs.pretrained import get_model
import warnings

warnings.filterwarnings('ignore', category=UserWarning)

# ---------------------------------------------------------------------------
# Load model
# ---------------------------------------------------------------------------
name = 'htdemucs_6s'
print(f"\nLoading {name}...")
wrapper_bag  = get_model(name)
real_model   = wrapper_bag.models[0]
real_model.cpu()
real_model.eval()

# ---------------------------------------------------------------------------
# Wrap so that _spec() (the STFT) runs inside the exported graph.
#
# Why this matters:
#   HTDemucs has a dual-path architecture — a time-domain branch and a
#   frequency-domain branch. They cross-communicate through a transformer
#   at the innermost layers. If the spectrogram is fed as an external input,
#   the connections between the internal spectrogram computation and the
#   cross-domain attention layers get severed or wrong-valued during export.
#
#   With _spec() inside the graph, TRT sees the complete STFT → attention →
#   ISTFT subgraph and can fuse the FFT kernel chains. This is why inference
#   drops from several minutes (ONNX Runtime) to ~5 seconds (TRT on RTX 3090).
# ---------------------------------------------------------------------------
class WaveformOnlyWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_waveform):
        # STFT computed inside the graph — critical for TRT kernel fusion
        z = self.model._spec(input_waveform)
        return self.model(input_waveform, z)

print("Wrapping model (STFT internalized)...")
wrapped_model = WaveformOnlyWrapper(real_model)

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
segment      = 343980   # model's fixed chunk size at 44100 Hz
dummy_input  = torch.randn(1, 2, segment)
output_file  = "htdemucs_6s_waveform.onnx"

print(f"Exporting to {output_file}  (this may take a few minutes)...")

torch.onnx.export(
    wrapped_model,
    dummy_input,
    output_file,
    opset_version=17,
    input_names=['input'],
    output_names=['output'],
    dynamic_axes={
        'input':  {0: 'batch', 2: 'time'},
        'output': {0: 'batch', 3: 'time'},
    },
    do_constant_folding=True,
    export_params=True,
    verbose=False,
)

import os
size_mb = os.path.getsize(output_file) / 1024 / 1024
print(f"\n  Export complete: {output_file}  ({size_mb:.0f} MB)")
print()
print("  Next step — build the TRT engine for your GPU:")
print("    python build_engine.py --onnx htdemucs_6s_waveform.onnx")
print()
print("  Or rename it and use the default:")
print(f"    rename {output_file} demucsv4.onnx")
print("    python build_engine.py")
print()