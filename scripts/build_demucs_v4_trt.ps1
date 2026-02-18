#Requires -Version 7.5
# scripts/build_demucs_v4_trt.ps1
# Compiles demucs_v4_trt.dll, builds Demucs_v4_TRT.exe, bundles NVIDIA DLLs.
# Preflight must have passed before this runs — enforced by setup.ps1.
# Called by setup.ps1 — do not run directly.

param(
    [Parameter(Mandatory)][PSCustomObject] $Paths,
    [Parameter(Mandatory)][array]          $DllManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = $Paths.ProjectRoot
$TrtRoot     = $Paths.TrtRoot
$TrtBin      = $Paths.TrtBin
$CudaRoot    = $Paths.CudaRoot
$CudaBin     = $Paths.CudaBin
$SrcFile     = $Paths.SrcCpp
$OutDll      = $Paths.OutDll

$NvToolkitRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit'

Write-Host "  ── [5] Build ───────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# [5.1] DLL MANIFEST CHECK
# For each DLL:
#   1. Check the path from config.ini (primary)
#   2. Recursive fallback scan under NVIDIA GPU Computing Toolkit root
#   3. If still missing and required → hard stop
# ---------------------------------------------------------------------------
Write-Host "  [5.1] DLL manifest check..." -ForegroundColor Yellow
Write-Host ""

# Helper: find a DLL anywhere under the NVIDIA toolkit root
function Find-DllRecursive ([string]$DllName) {
    if (-not (Test-Path $NvToolkitRoot)) { return $null }
    $hit = Get-ChildItem -Path $NvToolkitRoot -Filter $DllName -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    return $hit
}

$dllResults  = @()
$dllMissing  = 0
$dllTotal    = $DllManifest.Count
$nameWidth   = ($DllManifest | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum + 2

foreach ($dll in $DllManifest) {

    $sourcePath = switch ($dll.Source) {
        'tensorrt_bin' { $TrtBin }
        'cuda_bin'     { $CudaBin }
        'system'       { "$env:SystemRoot\System32" }
        default        { $null }
    }

    $found    = $false
    $fullPath = ''
    $note     = ''

    # Primary: check config.ini path
    if ($sourcePath -and (Test-Path $sourcePath)) {
        $candidate = Join-Path $sourcePath $dll.Name
        if (Test-Path $candidate) {
            $found    = $true
            $fullPath = $candidate
        }
    }

    # Fallback: recursive scan under NVIDIA toolkit root (skip system DLLs)
    if (-not $found -and $dll.Source -ne 'system') {
        $hit = Find-DllRecursive $dll.Name
        if ($hit) {
            $found    = $true
            $fullPath = $hit.FullName
            $note     = '  (found via scan)'

            # Update the in-memory paths so the build and bundle steps use the real location
            if ($dll.Source -eq 'cuda_bin') {
                $script:CudaBin = $hit.DirectoryName
            } elseif ($dll.Source -eq 'tensorrt_bin') {
                $script:TrtBin = $hit.DirectoryName
            }
        }
    }

    $status = if ($found) { "✅" } else { "❌" }
    $color  = if ($found) { 'Green' } else { 'Red' }
    $detail = if ($found) { "$fullPath$note" } else { "not found  [config: $sourcePath]" }

    Write-Host "  $status  $($dll.Name.PadRight($nameWidth)) $detail" -ForegroundColor $color

    if (-not $found -and $dll.Required) { $dllMissing++ }
    $dllResults += [PSCustomObject]@{ Dll = $dll; Found = $found; Path = $fullPath }
}

Write-Host ""

if ($dllMissing -gt 0) {
    $dllFound = $dllTotal - $dllMissing
    Write-Host "  ❌ $dllFound of $dllTotal DLLs found.  $dllMissing required DLL(s) missing." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Cannot build a complete bundle. Resolve missing DLLs first:" -ForegroundColor DarkYellow
    Write-Host ""

    foreach ($r in $dllResults | Where-Object { -not $_.Found -and $_.Dll.Required }) {
        $src = $r.Dll.Source
        Write-Host "  · $($r.Dll.Name)" -ForegroundColor White
        switch ($src) {
            'tensorrt_bin' {
                Write-Host "    Expected in TensorRT bin: $TrtBin" -ForegroundColor DarkGray
                Write-Host "    Also scanned recursively under: $NvToolkitRoot" -ForegroundColor DarkGray
                Write-Host "    https://developer.nvidia.com/tensorrt" -ForegroundColor DarkGray
            }
            'cuda_bin'     {
                Write-Host "    Expected in CUDA bin: $CudaBin" -ForegroundColor DarkGray
                Write-Host "    Also scanned recursively under: $NvToolkitRoot" -ForegroundColor DarkGray
                Write-Host "    https://developer.nvidia.com/cuda-downloads" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }
    Write-Host "  Re-run [2] Preflight after resolving, then try [5] Build again." -ForegroundColor DarkYellow
    return
}

Write-Host "  ✅ $dllTotal of $dllTotal DLLs found." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# [5.2] LOCATE SDK PATHS + ENSURE cl.exe
# ---------------------------------------------------------------------------
Write-Host "  [5.2] Locating build tools..." -ForegroundColor Yellow

# Find nvinfer_10.lib under TrtRoot
$nvinferLib = Get-ChildItem -Path $TrtRoot -Filter "nvinfer_10.lib" -Recurse -ErrorAction SilentlyContinue |
              Select-Object -First 1
if (-not $nvinferLib) {
    Write-Host "  ❌ nvinfer_10.lib not found under $TrtRoot" -ForegroundColor Red
    Write-Host "  Your TensorRT installation may be incomplete." -ForegroundColor DarkYellow
    return
}

# Derive CUDA include/lib from the real CudaBin (may have been updated by fallback scan above)
# CudaBin is bin\x64 — CUDA root is two levels up
$cudaBinResolved = $script:CudaBin
$cudaRootResolved = if ($cudaBinResolved -match '\\bin\\x64$') {
    $cudaBinResolved -replace '\\bin\\x64$', ''
} elseif ($cudaBinResolved -match '\\bin$') {
    $cudaBinResolved -replace '\\bin$', ''
} else {
    Split-Path $cudaBinResolved
}

$incTrt  = "$TrtRoot\include"
$incCuda = "$cudaRootResolved\include"
$libTrt  = $nvinferLib.DirectoryName
$libCuda = if (Test-Path "$cudaRootResolved\lib\x64") { "$cudaRootResolved\lib\x64" } else { "$cudaRootResolved\lib" }

Write-Host "  + TensorRT include : $incTrt" -ForegroundColor DarkGray
Write-Host "  + TensorRT lib     : $libTrt" -ForegroundColor DarkGray
Write-Host "  + CUDA include     : $incCuda" -ForegroundColor DarkGray
Write-Host "  + CUDA lib         : $libCuda" -ForegroundColor DarkGray
Write-Host "  + CUDA DLL bin     : $cudaBinResolved" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Locate vcvars64.bat — we always compile through it so the MSVC headers,
# libs, and linker are fully configured regardless of whether this session
# started from a Developer shell or plain PowerShell.
# Search order:
#   1. config.ini  vcvars key  (set by preflight — most reliable)
#   2. vswhere     Build Tools → Community → Professional → Enterprise
#   3. Known install paths (hardcoded fallback for common layouts)
# ---------------------------------------------------------------------------
$vcvars64 = $null

# 1. config.ini
$cfgVcvars = $Paths.PSObject.Properties['Vcvars']?.Value
if (-not $cfgVcvars) {
    # Read directly from ini in case Build-Paths didn't expose it
    if (Test-Path $Paths.ConfigFile) {
        $cfgVcvars = (Get-Content $Paths.ConfigFile |
            Where-Object { $_ -match '^\s*vcvars\s*=' } |
            Select-Object -First 1) -replace '^\s*vcvars\s*=\s*', ''
        $cfgVcvars = $cfgVcvars.Trim()
    }
}
if ($cfgVcvars -and $cfgVcvars -ne 'already active' -and (Test-Path $cfgVcvars)) {
    $vcvars64 = $cfgVcvars
    Write-Host "  + vcvars64         : $vcvars64  (from config.ini)" -ForegroundColor DarkGray
}

# 2. vswhere
if (-not $vcvars64) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * `
                    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                    -property installationPath 2>$null | Select-Object -First 1
        if ($vsPath) {
            $candidate = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $candidate) {
                $vcvars64 = $candidate
                Write-Host "  + vcvars64         : $vcvars64  (via vswhere)" -ForegroundColor DarkGray
            }
        }
    }
}

# 3. Hardcoded known locations (VS 2022 Build Tools and Community, typical installs)
if (-not $vcvars64) {
    $knownPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    )
    foreach ($p in $knownPaths) {
        if (Test-Path $p) {
            $vcvars64 = $p
            Write-Host "  + vcvars64         : $vcvars64  (hardcoded path)" -ForegroundColor DarkGray
            break
        }
    }
}

if (-not $vcvars64) {
    Write-Host "  ❌ vcvars64.bat not found." -ForegroundColor Red
    Write-Host "  Run [3] Install dependencies → VS Build Tools, then re-run [2] Preflight." -ForegroundColor DarkYellow
    return
}

Write-Host "  ✅ Build tools located." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# [5.3] BUILD C++ BRIDGE DLL
# Always invoked as: cmd /c "vcvars64.bat" && cl ...
# This self-contains the MSVC environment without touching the PowerShell
# session — no Developer shell required, no PATH pollution after the build.
# ---------------------------------------------------------------------------
Write-Host "  [5.3] Building demucs_v4_trt.dll..." -ForegroundColor Yellow
Write-Host ""

$clCmd    = "cl /LD /O2 /EHsc `"$SrcFile`"" +
            " /I `"$incTrt`" /I `"$incCuda`"" +
            " /link /LIBPATH:`"$libTrt`" /LIBPATH:`"$libCuda`"" +
            " nvinfer_10.lib cudart.lib" +
            " /OUT:`"$OutDll`"" +
            " /IMPLIB:`"$ProjectRoot\demucs_v4_trt.lib`""

$buildCmd = "cd /d `"$ProjectRoot`" && `"$vcvars64`" > nul && $clCmd"

cmd /c $buildCmd

if (-not (Test-Path $OutDll)) {
    Write-Host ""
    Write-Host "  ❌ DLL build failed. Check MSVC output above." -ForegroundColor Red
    return
}

# Clean build artifacts
Remove-Item "$ProjectRoot\demucs_v4_trt.lib" -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\demucs_v4_trt.exp" -ErrorAction SilentlyContinue
Get-ChildItem "$ProjectRoot\*.obj" | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ✅ demucs_v4_trt.dll built." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# [5.4] BUILD C# EXE
# ---------------------------------------------------------------------------
Write-Host "  [5.4] Building Demucs_v4_TRT.exe..." -ForegroundColor Yellow
Write-Host ""

$distDir = "$ProjectRoot\dist"
if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }

dotnet publish "$ProjectRoot\src\Demucs_v4_TRT.csproj" `
    -c Release -r win-x64 -o $distDir

if (-not (Test-Path "$distDir\Demucs_v4_TRT.exe")) {
    Write-Host ""
    Write-Host "  ❌ C# build failed. Check dotnet output above." -ForegroundColor Red
    Write-Host "  Common causes:" -ForegroundColor DarkYellow
    Write-Host "    · .NET 9 SDK not installed  →  winget install Microsoft.DotNet.SDK.9" -ForegroundColor DarkYellow
    Write-Host "    · Missing NuGet packages    →  dotnet restore src\Demucs_v4_TRT.csproj" -ForegroundColor DarkYellow
    return
}

Copy-Item "$distDir\Demucs_v4_TRT.exe" -Destination $ProjectRoot -Force
Write-Host ""
Write-Host "  ✅ Demucs_v4_TRT.exe built." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# [5.5] BUNDLE DLLs
# ---------------------------------------------------------------------------
Write-Host "  [5.5] Bundling DLLs..." -ForegroundColor Yellow
Write-Host ""

$bundleOk      = $true
$bundleMissing = @()

foreach ($r in $dllResults) {
    if ($r.Found) {
        if ($r.Dll.Source -ne 'system') {
            Copy-Item $r.Path -Destination $ProjectRoot -Force
            Write-Host "  + $($r.Dll.Name)" -ForegroundColor DarkGray
        } else {
            Write-Host "  · $($r.Dll.Name)  (system — not bundled)" -ForegroundColor DarkGray
        }
    } else {
        $bundleMissing += $r.Dll.Name
        $bundleOk = $false
    }
}

Write-Host ""

if (-not $bundleOk) {
    Write-Host "  ⚠  Some DLLs could not be bundled:" -ForegroundColor DarkYellow
    foreach ($m in $bundleMissing) { Write-Host "    · $m" -ForegroundColor DarkYellow }
    Write-Host "  The exe will work if these are on the user's system PATH." -ForegroundColor DarkYellow
    Write-Host "  For a fully portable release, resolve missing DLLs and rebuild." -ForegroundColor DarkYellow
    Write-Host ""
} else {
    Write-Host "  ✅ All DLLs bundled." -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# [5.6] VERIFY BUNDLE
# ---------------------------------------------------------------------------
Write-Host "  [5.6] Verifying bundle..." -ForegroundColor Yellow
Write-Host ""

$required   = @('Demucs_v4_TRT.exe', 'demucs_v4_trt.dll')
$allPresent = $true

foreach ($f in $required) {
    $p = Join-Path $ProjectRoot $f
    if (Test-Path $p) {
        $size = (Get-Item $p).Length / 1MB
        Write-Host "  ✅ $($f.PadRight(32)) $([math]::Round($size, 1)) MB" -ForegroundColor Green
    } else {
        Write-Host "  ❌ $f  MISSING" -ForegroundColor Red
        $allPresent = $false
    }
}

foreach ($r in $dllResults | Where-Object { $_.Dll.Source -ne 'system' }) {
    $p = Join-Path $ProjectRoot $r.Dll.Name
    if (Test-Path $p) {
        $size = (Get-Item $p).Length / 1MB
        Write-Host "  ✅ $($r.Dll.Name.PadRight(32)) $([math]::Round($size, 1)) MB" -ForegroundColor Green
    } else {
        Write-Host "  ⚠  $($r.Dll.Name)  not in project root (may be on PATH)" -ForegroundColor DarkYellow
    }
}

Write-Host ""

# ---------------------------------------------------------------------------
# CLEANUP
# ---------------------------------------------------------------------------
Remove-Item $distDir                -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\src\obj"  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\src\bin"  -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
if ($allPresent) {
    Write-Host "  ████████████████████████████████████████████████████████" -ForegroundColor Green
    Write-Host "  ██  BUILD COMPLETE                                    ██" -ForegroundColor Green
    Write-Host "  ████████████████████████████████████████████████████████" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Run it:" -ForegroundColor Cyan
    Write-Host "    .\Demucs_v4_TRT.exe `"song.mp3`"" -ForegroundColor White
    Write-Host "    .\Demucs_v4_TRT.exe `"song.mp3`" -m demucsv4_sm89_trt10.15.trt" -ForegroundColor White
    Write-Host "    .\Demucs_v4_TRT.exe `"song.mp3`" -o D:\my_stems" -ForegroundColor White
    Write-Host ""
    Write-Host "  Stems: drums.wav  bass.wav  other.wav  vocals.wav  guitar.wav  piano.wav" -ForegroundColor DarkGray
    Write-Host ""

    # -----------------------------------------------------------------------
    # DEMO OFFER — detect GPU architecture and gate on sm86 + engine present
    # -----------------------------------------------------------------------
    $sampleTrack  = "$ProjectRoot\samples\NEFFEX - Fight Back.mp3"
    $prebuiltEngine = "$ProjectRoot\models\demucsv4_sm86_trt10.15.trt"
    $exePath      = "$ProjectRoot\Demucs_v4_TRT.exe"

    # Detect GPU compute capability via nvidia-smi
    $gpuArch   = ''
    $gpuLabel  = ''
    try {
        $smArch = nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>&1 |
                  Select-Object -First 1
        if ($smArch -match '(\d+)\.(\d+)') {
            $gpuArch  = "sm$($Matches[1])$($Matches[2])"   # e.g. sm86
            $gpuLabel = $smArch.Trim()                      # e.g. 8.6
        }
    } catch {}

    $isSm86        = $gpuArch -eq 'sm86'
    $hasEngine     = Test-Path $prebuiltEngine
    $hasSample     = Test-Path $sampleTrack

    Write-Host "  ── Demo ────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    if (-not $gpuArch) {
        Write-Host "  ⚠  Could not detect GPU architecture (nvidia-smi unavailable)." -ForegroundColor DarkYellow
        Write-Host "     Cannot determine if the pre-built sm86 engine matches your GPU." -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  If you have an RTX 3090 / 3080 / 3070 / 3060 Ti (sm86), run:" -ForegroundColor White
        Write-Host "    .\Demucs_v4_TRT.exe `"samples\NEFFEX - Fight Back.mp3`"" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Otherwise, build an engine for your GPU first:" -ForegroundColor White
        Write-Host "    See [4] Python environment, then:" -ForegroundColor DarkGray
        Write-Host "    micromamba run -n demucs-trt python build_engine.py" -ForegroundColor Cyan

    } elseif (-not $isSm86) {
        # Wrong architecture — running sm86 engine on this GPU won't work.
        # Be direct: they need to build an engine before they can use this.
        Write-Host "  ℹ  Your GPU is compute $gpuLabel ($gpuArch)." -ForegroundColor Cyan
        Write-Host "     The bundled engine targets sm86 (RTX 30-series Ampere) and will" -ForegroundColor DarkYellow
        Write-Host "     not run correctly on your hardware." -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  You need to build a TRT engine for $gpuArch before separating audio." -ForegroundColor White
        Write-Host ""
        Write-Host "  Step 1 — set up the Python environment (if you haven't already):" -ForegroundColor Cyan
        Write-Host "    Select [4] Python environment from the main menu." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Step 2 — build your engine:" -ForegroundColor Cyan

        # Suggest the right command based on known arch
        $engineHint = switch ($gpuArch) {
            'sm89' { "build_engine.py                    # RTX 40-series (Ada Lovelace)" }
            'sm90' { "build_engine.py                    # RTX 50-series / H100 (Hopper)" }
            'sm80' { "build_engine.py                    # A100 / A6000 (Ampere datacenter)" }
            'sm75' { "build_engine.py                    # RTX 20-series (Turing)" }
            'sm70' { "build_engine.py                    # Tesla V100 (Volta)" }
            'sm61' { "build_engine.py --fp32             # GTX 10-series (Pascal — no FP16)" }
            default { "build_engine.py" }
        }

        $mambaExe = "$env:LOCALAPPDATA\micromamba\micromamba.exe"
        if (Test-Path $mambaExe) {
            Write-Host "    & `"$mambaExe`" run -n demucs-trt python $engineHint" -ForegroundColor White
        } else {
            Write-Host "    micromamba run -n demucs-trt python $engineHint" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  Step 3 — once the engine is built, run:" -ForegroundColor Cyan
        Write-Host "    .\Demucs_v4_TRT.exe `"samples\NEFFEX - Fight Back.mp3`"" -ForegroundColor White
        Write-Host ""
        Write-Host "  Engine builds take 5–20 minutes depending on GPU and workspace size." -ForegroundColor DarkGray
        Write-Host "  Output will be named automatically: models\demucsv4_${gpuArch}_trt*.trt" -ForegroundColor DarkGray

    } elseif (-not $hasEngine) {
        # Right GPU, but engine file missing
        Write-Host "  ℹ  Your GPU is sm86 — the pre-built engine should work here." -ForegroundColor Cyan
        Write-Host "  ⚠  But the engine file is missing:" -ForegroundColor DarkYellow
        Write-Host "       $prebuiltEngine" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Download it from the GitHub release page and place it in models\." -ForegroundColor White
        Write-Host "  Or build it yourself:" -ForegroundColor DarkGray
        $mambaExe = "$env:LOCALAPPDATA\micromamba\micromamba.exe"
        if (Test-Path $mambaExe) {
            Write-Host "    & `"$mambaExe`" run -n demucs-trt python build_engine.py" -ForegroundColor White
        } else {
            Write-Host "    micromamba run -n demucs-trt python build_engine.py" -ForegroundColor White
        }

    } elseif (-not $hasSample) {
        # Right GPU, engine present, sample missing
        Write-Host "  ℹ  Your GPU is sm86 — ready to separate." -ForegroundColor Cyan
        Write-Host "  ⚠  Sample track not found at:" -ForegroundColor DarkYellow
        Write-Host "       $sampleTrack" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Run with any mp3:" -ForegroundColor White
        Write-Host "    .\Demucs_v4_TRT.exe `"your_song.mp3`"" -ForegroundColor Cyan

    } else {
        # All clear — sm86, engine present, sample present. Offer the demo.
        Write-Host "  ✅ Your GPU is sm86 (RTX 30-series) — the pre-built engine is a match." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Would you like to run a demo separation now?" -ForegroundColor Cyan
        Write-Host "  Track: NEFFEX - Fight Back  (CC BY 3.0 — credit: NEFFEX)" -ForegroundColor DarkGray
        Write-Host "  Output: $ProjectRoot\stems\NEFFEX - Fight Back\" -ForegroundColor DarkGray
        Write-Host ""

        $answer = Read-Host "  Run demo? [Y/N]"
        if ($answer.Trim().ToUpper() -eq 'Y') {
            Write-Host ""
            Write-Host "  ── Running demo separation ─────────────────────────────────────────────" -ForegroundColor Cyan
            Write-Host ""
            & $exePath $sampleTrack
            Write-Host ""

            $stemsOut = "$ProjectRoot\stems\NEFFEX - Fight Back"
            if (Test-Path $stemsOut) {
                Write-Host "  ✅ Stems written to:" -ForegroundColor Green
                Write-Host "     $stemsOut" -ForegroundColor White
                Write-Host ""
                Get-ChildItem $stemsOut -Filter "*.wav" | ForEach-Object {
                    $mb = [math]::Round($_.Length / 1MB, 1)
                    Write-Host "     $($_.Name.PadRight(20)) $mb MB" -ForegroundColor DarkGray
                }
                Write-Host ""

                # Offer to open the output folder
                $open = Read-Host "  Open stems folder in Explorer? [Y/N]"
                if ($open.Trim().ToUpper() -eq 'Y') {
                    Start-Process explorer.exe $stemsOut
                }
            } else {
                Write-Host "  ⚠  Stems folder not found — check output above for errors." -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  Skipped. Run it any time:" -ForegroundColor DarkGray
            Write-Host "    .\Demucs_v4_TRT.exe `"samples\NEFFEX - Fight Back.mp3`"" -ForegroundColor White
        }
    }

} else {
    Write-Host "  ❌ Build completed with errors. Check output above." -ForegroundColor Red
}

Write-Host ""