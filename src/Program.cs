// src/Program.cs
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Diagnostics;
using NAudio.Wave;
using NAudio.MediaFoundation;
using System.Linq;
using System.Collections.Generic;

namespace Demucs_v4_TRT;

class Program
{
    // =========================================================================
    //  P/INVOKE - demucs_v4_trt.dll
    // =========================================================================
    [DllImport("demucs_v4_trt.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr Trt_Init(string modelPath, out int chunkLen, out int numSources);

    [DllImport("demucs_v4_trt.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int Trt_Process(IntPtr ctx, float[] input, float[] output);

    [DllImport("demucs_v4_trt.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void Trt_Destroy(IntPtr ctx);

    // =========================================================================
    //  CONSTANTS
    // =========================================================================
    const int   ModelSampleRate = 44100;
    const float OverlapRatio    = 0.25f;

    static readonly string[] Sources6 = ["drums", "bass", "other", "vocals", "guitar", "piano"];
    static readonly string[] Sources4 = ["drums", "bass", "other", "vocals"];

    // =========================================================================
    //  ENTRY POINT
    // =========================================================================
    static void Main(string[] args)
    {
        // Prepend TRT/CUDA paths from config.ini before any DLL load is attempted
        ConfigureEnvironment();

        var cfg = ParseArgs(args);
        if (cfg == null) { PrintUsage(); return; }

        if (!File.Exists(cfg.InputPath)) {
            Console.WriteLine($"[Error] Input file not found: {cfg.InputPath}");
            return;
        }

        string modelPath = Path.GetFullPath(cfg.ModelPath);
        if (!File.Exists(modelPath)) {
            Console.WriteLine($"[Error] Model file not found: {modelPath}");
            Console.WriteLine("        Pass a path with -m, or place a .trt file next to the exe.");
            return;
        }

        string outputDir = Path.GetFullPath(
            Path.Combine(cfg.OutputDir,
                         Path.GetFileNameWithoutExtension(cfg.InputPath)));
        Directory.CreateDirectory(outputDir);

        Console.WriteLine(new string('═', 60));
        Console.WriteLine($"  Input:   {Path.GetFileName(cfg.InputPath)}");
        Console.WriteLine($"  Model:   {Path.GetFileName(modelPath)}");
        Console.WriteLine($"  Output:  {outputDir}");
        Console.WriteLine(new string('═', 60));

        // 1. Load + resample audio
        Console.Write("  + Loading Audio... ");
        float[] left, right;
        try {
            (left, right) = LoadAndResample(cfg.InputPath, ModelSampleRate);
        } catch (Exception ex) {
            Console.WriteLine($"FAILED.\n  [Audio Error] {ex.Message}");
            return;
        }
        int N = left.Length;
        Console.WriteLine($"{N:N0} samples.");

        // 2. Normalize (match Python reference)
        double sum = 0;
        for (int i = 0; i < N; i++) sum += (left[i] + right[i]) * 0.5;
        float mean = (float)(sum / N);
        double sumSq = 0;
        for (int i = 0; i < N; i++) {
            double m = (left[i] + right[i]) * 0.5 - mean;
            sumSq += m * m;
        }
        float std = (float)Math.Sqrt(sumSq / N) + 1e-8f;
        Console.WriteLine($"  + Normalization: mean={mean:F6} std={std:F6}");

        // 3. Initialize TRT engine
        IntPtr ctx = IntPtr.Zero;
        try {
            Console.Write("  + Initializing TensorRT Engine... ");
            ctx = Trt_Init(modelPath, out int chunkLen, out int numSources);

            if (ctx == IntPtr.Zero) {
                Console.WriteLine("FAILED.");
                Console.WriteLine("  [Hint] Check that demucs_v4_trt.dll, nvinfer_10.dll, and cudart64_13.dll");
                Console.WriteLine("         are present next to the exe, or set paths in config.ini.");
                return;
            }
            Console.WriteLine($"OK (Chunk={chunkLen}, Sources={numSources})");

            // 4. Chunked inference with overlap-add
            RunInference(ctx, cfg, left, right, N, mean, std, chunkLen, numSources, outputDir);
        }
        catch (DllNotFoundException ex) {
            Console.WriteLine($"\n[Error] DLL not found: {ex.Message}");
            Console.WriteLine("  Required files next to exe:");
            Console.WriteLine("    demucs_v4_trt.dll  - built by setup.ps1 [5] Build");
            Console.WriteLine("    nvinfer_10.dll     - from TensorRT-10.x.x.x\\bin\\");
            Console.WriteLine("    nvinfer_plugin_10.dll");
            Console.WriteLine("    cudart64_13.dll    - from CUDA\\v13.x\\bin\\x64\\");
            Console.WriteLine("  Or run setup.ps1 → [2] Preflight → [5] Build to auto-detect and bundle.");
        }
        catch (Exception ex) {
            Console.WriteLine($"\n[Error] {ex.GetType().Name}: {ex.Message}");
            Console.WriteLine(ex.StackTrace);
        }
        finally {
            if (ctx != IntPtr.Zero) Trt_Destroy(ctx);
        }
    }

    // =========================================================================
    //  ENVIRONMENT SETUP
    //  Modifies PATH for this process only — never touches system or user PATH.
    //
    //  Priority order for DLL loading:
    //    1. DLLs sitting next to the exe   (deployed bundle — no config.ini needed)
    //    2. Paths from config.ini [runtime] section (dev machine / SDK layout)
    //
    //  config.ini is written by setup_preflight.ps1 and lives next to the exe.
    //  It contains a [runtime] section with TRT_BIN and CUDA_BIN keys pointing
    //  to the exact directories where the DLLs were found during preflight.
    //
    //  ini format (INI with sections, key = value, ; comments):
    //    [runtime]
    //    TRT_BIN  = C:\...\TensorRT-10.x\bin
    //    CUDA_BIN = C:\...\CUDA\v13.1\bin\x64
    // =========================================================================
    static void ConfigureEnvironment()
    {
        string baseDir     = AppContext.BaseDirectory;
        string processPath = Environment.GetEnvironmentVariable("PATH") ?? "";

        // 1. Prepend our own directory first so bundled DLLs always win
        if (!processPath.StartsWith(baseDir, StringComparison.OrdinalIgnoreCase))
            processPath = baseDir + Path.PathSeparator + processPath;

        // 2. If config.ini exists, read [runtime] section and append SDK paths as fallback.
        //    Only meaningful on a dev/build machine where DLLs live in the SDK rather
        //    than next to the exe. In a deployed bundle this is a no-op.
        string iniPath = Path.Combine(baseDir, "config.ini");
        if (File.Exists(iniPath)) {
            try {
                bool inRuntimeSection = false;

                foreach (var rawLine in File.ReadAllLines(iniPath)) {
                    string line = rawLine.Trim();

                    // Skip comments and blank lines
                    if (line.StartsWith(';') || line.Length == 0) continue;

                    // Section header
                    if (line.StartsWith('[') && line.EndsWith(']')) {
                        inRuntimeSection = line.Equals("[runtime]", StringComparison.OrdinalIgnoreCase);
                        continue;
                    }

                    if (!inRuntimeSection) continue;

                    // key = value  (trim whitespace around both)
                    int eq = line.IndexOf('=');
                    if (eq < 1) continue;

                    string key = line[..eq].Trim();
                    string val = line[(eq + 1)..].Trim();

                    if (!string.IsNullOrEmpty(val) &&
                        (key.Equals("TRT_BIN",  StringComparison.OrdinalIgnoreCase) ||
                         key.Equals("CUDA_BIN", StringComparison.OrdinalIgnoreCase)))
                    {
                        if (Directory.Exists(val) &&
                            !processPath.Contains(val, StringComparison.OrdinalIgnoreCase))
                        {
                            processPath = processPath + Path.PathSeparator + val;
                        }
                    }
                }
            }
            catch { /* non-fatal — DLLs next to exe will still load fine */ }
        }

        Environment.SetEnvironmentVariable("PATH", processPath);
    }

    // =========================================================================
    //  AUDIO LOADING  (MediaFoundation - handles mp3/wav/flac/aac/m4a)
    // =========================================================================
    static (float[] L, float[] R) LoadAndResample(string path, int targetSr)
    {
        using var reader    = new AudioFileReader(path);
        var outFormat       = new WaveFormat(targetSr, reader.WaveFormat.Channels);
        using var resampler = new MediaFoundationResampler(reader, outFormat) { ResamplerQuality = 60 };

        var provider = resampler.ToSampleProvider();
        int ch       = reader.WaveFormat.Channels;
        var samples  = new List<float>();
        float[] buf  = new float[targetSr * ch];
        int read;
        while ((read = provider.Read(buf, 0, buf.Length)) > 0)
            samples.AddRange(buf.Take(read));

        int n     = samples.Count / ch;
        float[] L = new float[n];
        float[] R = new float[n];
        for (int i = 0; i < n; i++) {
            L[i] = samples[i * ch];
            R[i] = ch > 1 ? samples[i * ch + 1] : L[i];
        }
        return (L, R);
    }

    // =========================================================================
    //  INFERENCE  (chunked overlap-add, matches Python trt_runner.py)
    // =========================================================================
    static void RunInference(IntPtr ctx, Config cfg,
                             float[] left, float[] right, int N,
                             float mean, float std,
                             int chunkLen, int numSources, string outputDir)
    {
        int overlapFrames = (int)(OverlapRatio * chunkLen);
        int hopLen        = chunkLen - overlapFrames;

        var stemsL  = new float[numSources][];
        var stemsR  = new float[numSources][];
        var weights = new float[N];
        for (int s = 0; s < numSources; s++) {
            stemsL[s] = new float[N];
            stemsR[s] = new float[N];
        }

        float[] inputBuf  = new float[2 * chunkLen];
        float[] outputBuf = new float[numSources * 2 * chunkLen];

        int  start    = 0;
        int  chunkIdx = 0;
        var  sw       = Stopwatch.StartNew();

        while (start < N)
        {
            if (cfg.SingleChunk && chunkIdx > 0) break;

            int end    = Math.Min(start + chunkLen, N);
            int segLen = end - start;

            if (chunkIdx % 5 == 0) {
                int pct = (int)((double)start / N * 100);
                Console.Write($"\r  + Separating... {pct,3}%");
            }

            // Fill input buffer (zero-padded at end if last chunk)
            Array.Clear(inputBuf, 0, inputBuf.Length);
            for (int i = 0; i < segLen; i++) {
                inputBuf[i]            = (left[start + i]  - mean) / std;
                inputBuf[chunkLen + i] = (right[start + i] - mean) / std;
            }

            int result = Trt_Process(ctx, inputBuf, outputBuf);
            if (result != 0) {
                Console.WriteLine($"\n  [Error] GPU inference failed (code {result}).");
                return;
            }

            // Overlap-add with linear fade at boundaries
            for (int t = 0; t < segLen; t++) {
                int   g = start + t;
                float w = 1.0f;
                if (chunkIdx > 0 && t < overlapFrames)               w = (float)t / overlapFrames;
                if (end < N      && t > chunkLen - overlapFrames)     w = (float)(chunkLen - t) / overlapFrames;

                weights[g] += w;
                for (int s = 0; s < numSources; s++) {
                    stemsL[s][g] += outputBuf[s * 2 * chunkLen + t]           * w;
                    stemsR[s][g] += outputBuf[(s * 2 + 1) * chunkLen + t]     * w;
                }
            }

            start += hopLen;
            chunkIdx++;
        }

        sw.Stop();
        Console.WriteLine($"\r  + Separating... Done in {sw.Elapsed.TotalSeconds:F2}s   ");

        // Denormalize + save
        string[] stemNames = numSources == 6 ? Sources6 : Sources4;
        Console.WriteLine("  + Saving wav files...");

        for (int s = 0; s < numSources; s++) {
            for (int i = 0; i < N; i++) {
                float w      = weights[i] > 1e-7f ? weights[i] : 1.0f;
                stemsL[s][i] = (stemsL[s][i] / w) * std + mean;
                stemsR[s][i] = (stemsR[s][i] / w) * std + mean;
            }
            SaveWav(Path.Combine(outputDir, $"{stemNames[s]}.wav"), stemsL[s], stemsR[s], ModelSampleRate);
        }

        Console.WriteLine("  All stems saved.");
    }

    // =========================================================================
    //  WAV OUTPUT
    // =========================================================================
    static void SaveWav(string path, float[] L, float[] R, int sr)
    {
        using var writer = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(sr, 2));
        for (int i = 0; i < L.Length; i++) {
            writer.WriteSample(L[i]);
            writer.WriteSample(R[i]);
        }
    }

    // =========================================================================
    //  ARG PARSING
    //  Search order for model auto-discovery:
    //    1. models\ next to exe          (repo / dev layout)
    //    2. next to exe                  (flat release layout)
    //    3. models\ in working directory
    //    4. working directory
    // =========================================================================
    class Config {
        public string InputPath   = "";
        public string ModelPath   = "";
        public string OutputDir   = "stems";
        public bool   SingleChunk = false;
    }

    static Config? ParseArgs(string[] args)
    {
        if (args.Length < 1) return null;
        var cfg = new Config { InputPath = args[0] };
        for (int i = 1; i < args.Length; i++) {
            if (args[i] == "-m" && i + 1 < args.Length) cfg.ModelPath  = args[++i];
            if (args[i] == "-o" && i + 1 < args.Length) cfg.OutputDir  = args[++i];
            if (args[i] == "-s")                         cfg.SingleChunk = true;
        }

        // Auto-discover model if not specified.
        // Search order:
        //   1. models\ next to exe          (repo / dev layout)
        //   2. next to exe                  (flat release layout)
        //   3. models\ in working directory
        //   4. working directory
        if (string.IsNullOrEmpty(cfg.ModelPath)) {
            string baseDir   = AppContext.BaseDirectory;
            string modelsDir = Path.Combine(baseDir, "models");
            string cwdModels = Path.Combine(".", "models");

            string? found =
                // preferred named engine first, then any *.trt, across all search dirs
                new[] {
                    Path.Combine(modelsDir, "demucsv4_sm86_trt10.15.trt"),
                    Path.Combine(baseDir,   "demucsv4_sm86_trt10.15.trt"),
                }
                .FirstOrDefault(File.Exists)
                ??
                new[] { modelsDir, baseDir, cwdModels, "." }
                .Where(Directory.Exists)
                .SelectMany(d => Directory.GetFiles(d, "*.trt"))
                .FirstOrDefault();

            if (found != null) cfg.ModelPath = found;
        }

        if (string.IsNullOrEmpty(cfg.ModelPath)) {
            Console.WriteLine("[Error] No .trt engine found.");
            Console.WriteLine("        Place engine in .\\models\\ or pass -m <path\\to\\engine.trt>");
            return null;
        }
        return cfg;
    }

    static void PrintUsage()
    {
        Console.WriteLine();
        Console.WriteLine("  Demucs v4 TRT - 6-stem audio separator");
        Console.WriteLine();
        Console.WriteLine("  Usage:  Demucs_v4_TRT.exe <input.mp3> [options]");
        Console.WriteLine();
        Console.WriteLine("  Options:");
        Console.WriteLine("    -m <model.trt>    Path to TRT engine (auto-discovers *.trt if omitted)");
        Console.WriteLine("    -o <dir>          Output directory   (default: .\\stems\\<song name>)");
        Console.WriteLine("    -s                Single-chunk debug mode (first chunk only)");
        Console.WriteLine();
        Console.WriteLine("  Stems:  drums.wav  bass.wav  other.wav  vocals.wav  guitar.wav  piano.wav");
        Console.WriteLine();
    }
}