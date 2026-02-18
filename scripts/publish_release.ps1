#Requires -Version 7.5
# scripts/publish_release.ps1
# Full build + deploy pipeline for Demucs_v4_TRT.
# Compiles the C++ bridge, builds the C# self-contained exe, bundles NVIDIA DLLs.
#
# Called by setup.ps1 -Build with a $Paths object.
# Can also be run standalone — will use config.ini / auto-detect.

param(
    [PSCustomObject]$Paths = $null
)

# ---------------------------------------------------------------------------
# STANDALONE MODE
# ---------------------------------------------------------------------------
if (-not $Paths) {
    $ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $ConfigFile  = "$ProjectRoot\config.ini"
    $TrtRoot = $null; $CudaRoot = $null; $TrtBin = $null; $CudaBin = $null

    if (Test-Path $ConfigFile) {
        Get-Content $ConfigFile | ForEach-Object {
            if ($_ -match "^TensorRT_Root=(.+)$") { $TrtRoot  = $Matches[1].Trim() }
            if ($_ -match "^CUDA_Root=(.+)$")     { $CudaRoot = $Matches[1].Trim() }
            if ($_ -match "^TRT_BIN=(.+)$")       { $TrtBin   = $Matches[1].Trim() }
            if ($_ -match "^CUDA_BIN=(.+)$")      { $CudaBin  = $Matches[1].Trim() }
        }
    }
    if (-not $TrtRoot -or -not (Test-Path $TrtRoot)) {
        $found = Get-ChildItem "C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT*" `
                 -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($found) { $TrtRoot = $found.FullName }
    }
    if (-not $CudaRoot -or -not (Test-Path $CudaRoot)) {
        $found = Get-ChildItem "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*" `
                 -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($found) { $CudaRoot = $found.FullName }
    }
    if ($TrtRoot  -and -not $TrtBin)  { $TrtBin  = "$TrtRoot\bin" }
    if ($CudaRoot -and -not $CudaBin) { $CudaBin = "$CudaRoot\bin\x64" }

    $Paths = [PSCustomObject]@{
        ProjectRoot = $ProjectRoot
        ConfigFile  = $ConfigFile
        TrtRoot     = $TrtRoot
        CudaRoot    = $CudaRoot
        TrtBin      = $TrtBin
        CudaBin     = $CudaBin
        SrcCpp      = "$ProjectRoot\src\demucs_v4_trt.cpp"
        OutDll      = "$ProjectRoot\demucs_v4_trt.dll"
    }
}

$ProjectRoot = $Paths.ProjectRoot
$TrtBin      = $Paths.TrtBin
$CudaBin     = $Paths.CudaBin

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  DEMUCS V4 TRT  -  Release Publisher" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════"

# ---------------------------------------------------------------------------
# [1/4] BUILD C++ BRIDGE
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  [1/4] Building C++ bridge..." -ForegroundColor Yellow
& "$PSScriptRoot\build_bridge.ps1" -Paths $Paths
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Bridge build failed. Fix errors above and re-run." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$ProjectRoot\demucs_v4_trt.dll")) {
    Write-Host "  demucs_v4_trt.dll not found after build. Aborting." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# [2/4] BUILD C# EXE  (self-contained single-file publish)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  [2/4] Building C# executable..." -ForegroundColor Yellow

$distDir = "$ProjectRoot\dist"
if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }

dotnet publish "$ProjectRoot\src\Demucs_v4_TRT.csproj" `
    -c Release -r win-x64 -o $distDir

if (-not (Test-Path "$distDir\Demucs_v4_TRT.exe")) {
    Write-Host ""
    Write-Host "  C# build failed. Check dotnet output above." -ForegroundColor Red
    Write-Host "  Common causes:" -ForegroundColor DarkYellow
    Write-Host "    - .NET 9 SDK not installed  ->  https://dotnet.microsoft.com/download/dotnet/9.0" -ForegroundColor DarkYellow
    Write-Host "    - Run from a VS Developer shell (needed for the C++ bridge step)" -ForegroundColor DarkYellow
    exit 1
}
Write-Host "  + Demucs_v4_TRT.exe built." -ForegroundColor Green

# ---------------------------------------------------------------------------
# [3/4] ASSEMBLE DEPLOYMENT PACKAGE
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  [3/4] Assembling deployment package..." -ForegroundColor Yellow

Copy-Item "$distDir\Demucs_v4_TRT.exe" -Destination $ProjectRoot -Force
Write-Host "  + Demucs_v4_TRT.exe" -ForegroundColor DarkGray
Write-Host "  + demucs_v4_trt.dll" -ForegroundColor DarkGray

# NVIDIA runtime DLLs — bundled next to exe so the user needs no SDK on PATH
# nvinfer_10.dll        TensorRT inference runtime   https://developer.nvidia.com/tensorrt
# nvinfer_plugin_10.dll TensorRT plugin library      (same install)
# cudart64_13.dll       CUDA runtime                 https://developer.nvidia.com/cuda-downloads
$RuntimesToCopy = @(
    @{ Dir = $TrtBin;  Name = "nvinfer_10.dll";        Desc = "TensorRT runtime" },
    @{ Dir = $TrtBin;  Name = "nvinfer_plugin_10.dll"; Desc = "TensorRT plugins" },
    @{ Dir = $CudaBin; Name = "cudart64_13.dll";       Desc = "CUDA runtime"     }
)

$missingDlls = @()
foreach ($rt in $RuntimesToCopy) {
    if (-not $rt.Dir) { $missingDlls += $rt; continue }
    $src = Join-Path $rt.Dir $rt.Name
    if (Test-Path $src) {
        Copy-Item $src -Destination $ProjectRoot -Force
        Write-Host "  + $($rt.Name)  ($($rt.Desc))" -ForegroundColor DarkGray
    } else {
        $missingDlls += $rt
        Write-Host "  ! $($rt.Name) not found at: $src" -ForegroundColor DarkYellow
    }
}

Write-Host "  + config.ini  (process-local PATH fallback)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# [4/4] CLEANUP
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  [4/4] Cleaning build artifacts..." -ForegroundColor Gray
Remove-Item $distDir                          -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\src\obj"            -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\src\bin"            -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\demucs_v4_trt.lib"  -ErrorAction SilentlyContinue
Remove-Item "$ProjectRoot\demucs_v4_trt.exp"  -ErrorAction SilentlyContinue
Get-ChildItem "$ProjectRoot\*.obj" | Remove-Item -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  SUCCESS  -  Deployment package ready." -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════"
Write-Host ""
Write-Host "  Run it:" -ForegroundColor Cyan
Write-Host "    .\Demucs_v4_TRT.exe `"song.mp3`"" -ForegroundColor White
Write-Host "    .\Demucs_v4_TRT.exe `"song.mp3`" -m demucsv4_sm89_trt10.15.trt" -ForegroundColor White
Write-Host ""

Write-Host "  Root files:" -ForegroundColor Gray
Get-ChildItem $ProjectRoot -File | Where-Object {
    $_.Extension -in @('.exe','.dll','.trt','.onnx','.ini','.py','.ps1','.bat','.md')
} | Sort-Object Name | ForEach-Object {
    Write-Host "    $($_.Name)" -ForegroundColor DarkGray
}

if ($missingDlls.Count -gt 0) {
    Write-Host ""
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  WARNING: The following DLLs could not be bundled:" -ForegroundColor Yellow
    foreach ($d in $missingDlls) { Write-Host "    - $($d.Name)" -ForegroundColor DarkYellow }
    Write-Host ""
    Write-Host "  The exe will work if these are already on your system PATH." -ForegroundColor Yellow
    Write-Host "  Otherwise copy them manually next to the exe:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    nvinfer_10.dll + nvinfer_plugin_10.dll" -ForegroundColor White
    Write-Host "      https://developer.nvidia.com/tensorrt" -ForegroundColor DarkGray
    Write-Host "    cudart64_13.dll" -ForegroundColor White
    Write-Host "      https://developer.nvidia.com/cuda-downloads" -ForegroundColor DarkGray
    Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor Yellow
}
Write-Host ""