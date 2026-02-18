#Requires -Version 7.5
# scripts/setup_python.ps1
# Installs micromamba and creates the demucs-trt conda environment.
# Python is strictly optional — for engine building and validation only.
# No system Python. No PATH pollution. Entirely self-contained.
# Called by setup.ps1 — do not run directly.

param(
    [Parameter(Mandatory)][PSCustomObject] $Paths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$MambaExe    = $Paths.MambaExe
$MambaDir    = Split-Path $MambaExe
$RootPrefix  = $Paths.MambaRoot
$EnvName     = $Paths.EnvName
$EnvFile     = $Paths.EnvFile
$MambaVersion = "2.5.0-2"
$MambaUrl     = "https://github.com/mamba-org/micromamba-releases/releases/download/$MambaVersion/micromamba-win-64.exe"

Write-Host "  ── [4] Python Environment (optional) ───────────────────────────────────" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This is strictly optional. Only needed if you want to:" -ForegroundColor DarkGray
Write-Host "    · Build a TRT engine for your GPU  (build_engine.py)" -ForegroundColor DarkGray
Write-Host "    · Validate a new engine            (stemsplit.py)" -ForegroundColor DarkGray
Write-Host "    · Re-export the ONNX               (export_htdemucs.py)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  No system Python. No conda on PATH. micromamba lives in:" -ForegroundColor DarkGray
Write-Host "    $MambaExe" -ForegroundColor DarkGray
Write-Host "  Environment lives in:" -ForegroundColor DarkGray
Write-Host "    $RootPrefix\envs\$EnvName" -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-Host "  Continue? [Y/N]"
if ($confirm.Trim().ToUpper() -ne 'Y') {
    Write-Host "  Skipped." -ForegroundColor DarkGray
    return
}

Write-Host ""

# ---------------------------------------------------------------------------
# [4.1] CHECK ENVIRONMENT FILE
# ---------------------------------------------------------------------------
Write-Host "  [4.1] Checking environment spec..." -ForegroundColor Yellow
if (-not (Test-Path $EnvFile)) {
    Write-Host "  ❌ environment.yml not found at:" -ForegroundColor Red
    Write-Host "     $EnvFile" -ForegroundColor Red
    Write-Host "  This file should be in the repo under python\environment.yml" -ForegroundColor DarkYellow
    return
}
Write-Host "  ✅ $EnvFile" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# [4.2] INSTALL MICROMAMBA
# ---------------------------------------------------------------------------
Write-Host "  [4.2] micromamba $MambaVersion..." -ForegroundColor Yellow

if (Test-Path $MambaExe) {
    $ver = & $MambaExe --version 2>&1
    Write-Host "  ✅ Already installed  ($ver)" -ForegroundColor Green
} else {
    Write-Host "  Downloading micromamba $MambaVersion..." -ForegroundColor White
    Write-Host "  $MambaUrl" -ForegroundColor DarkGray
    Write-Host ""
    New-Item -ItemType Directory -Force -Path $MambaDir | Out-Null
    try {
        Invoke-WebRequest -Uri $MambaUrl -OutFile $MambaExe -UseBasicParsing
        $ver = & $MambaExe --version 2>&1
        Write-Host "  ✅ micromamba $ver installed." -ForegroundColor Green
    } catch {
        Write-Host "  ❌ Download failed." -ForegroundColor Red
        Write-Host "  Grab it manually and save as:" -ForegroundColor DarkYellow
        Write-Host "    $MambaExe" -ForegroundColor White
        Write-Host "  From: https://github.com/mamba-org/micromamba-releases/releases/tag/$MambaVersion" -ForegroundColor DarkGray
        return
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# [4.3] CREATE OR UPDATE ENVIRONMENT
# ---------------------------------------------------------------------------
$env:MAMBA_ROOT_PREFIX = $RootPrefix
$envList   = & $MambaExe env list --root-prefix $RootPrefix 2>&1
$envExists = $envList | Select-String "^\s*$EnvName\s"

if ($envExists) {
    Write-Host "  [4.3] Updating '$EnvName' environment..." -ForegroundColor Yellow
    Write-Host "  (this may take a few minutes)" -ForegroundColor DarkGray
    Write-Host ""
    & $MambaExe env update -n $EnvName -f $EnvFile --root-prefix $RootPrefix --yes
} else {
    Write-Host "  [4.3] Creating '$EnvName' environment..." -ForegroundColor Yellow
    Write-Host "  Downloading PyTorch + CUDA + TensorRT Python bindings (~4-6 GB)" -ForegroundColor DarkGray
    Write-Host "  Go get a coffee." -ForegroundColor DarkGray
    Write-Host ""
    & $MambaExe env create -f $EnvFile --root-prefix $RootPrefix --yes
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  ❌ Environment setup failed. Check output above." -ForegroundColor Red
    return
}
Write-Host ""

# ---------------------------------------------------------------------------
# [4.4] VERIFY
# ---------------------------------------------------------------------------
Write-Host "  [4.4] Verifying environment..." -ForegroundColor Yellow

$pyVer = & $MambaExe run -n $EnvName --root-prefix $RootPrefix python --version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ $pyVer" -ForegroundColor Green
} else {
    Write-Host "  ⚠  Could not verify Python in environment." -ForegroundColor DarkYellow
}
Write-Host ""

# ---------------------------------------------------------------------------
# DONE
# ---------------------------------------------------------------------------
Write-Host "  ✅ Environment '$EnvName' ready." -ForegroundColor Green
Write-Host ""
Write-Host "  Invoke scripts with:" -ForegroundColor Cyan
Write-Host "    & `"$MambaExe`" run -n $EnvName python build_engine.py" -ForegroundColor White
Write-Host "    & `"$MambaExe`" run -n $EnvName python stemsplit.py `"song.mp3`"" -ForegroundColor White