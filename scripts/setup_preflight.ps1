#Requires -Version 7.5
# scripts/setup_preflight.ps1
# Validates all build dependencies, discovers SDK paths, writes config.ini.
# Called by setup.ps1 — do not run directly.
#
# Detection sources:
#   nvidia-smi   →  driver version + GPU name
#   nvcc         →  CUDA toolkit version + cuda_root (walk up from exe)
#   filesystem   →  recursive fallback under NVIDIA GPU Computing Toolkit root
#   trtexec      →  TensorRT version + trt_root (walk up from exe)
#   vswhere      →  Build Tools / VS + vcvars64.bat path
#   dotnet       →  .NET SDK version
#   python       →  informational only, not pass/fail

param(
    [Parameter(Mandatory)][string]       $ProjectRoot,
    [Parameter(Mandatory)][string]       $ConfigFile,
    [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary] $Manifest
)

$ErrorActionPreference = "Continue"

trap {
    Write-Host ""
    Write-Host "  ❌ Preflight hit an unexpected error:" -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
function Write-Check {
    param(
        [string]$Label,
        [bool]  $Ok,
        [string]$Detail = '',
        [string]$Hint   = '',
        [switch]$Info
    )
    $pad    = 22
    $status = if ($Info) { "ℹ " } elseif ($Ok) { "✅" } else { "❌" }
    $color  = if ($Info) { 'Cyan' } elseif ($Ok) { 'Green' } else { 'Red' }
    Write-Host "  $status  $($Label.PadRight($pad)) $Detail" -ForegroundColor $color
    if (-not $Ok -and -not $Info -and $Hint) {
        Write-Host "         $(' ' * $pad) → $Hint" -ForegroundColor DarkYellow
    }
}

function Add-ToUserPath ([string[]]$Dirs) {
    $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $toAdd   = @($Dirs | Where-Object { -not (Test-InPath $_) })
    if ($toAdd.Count -eq 0) { return $false }
    $newPath = ($current.TrimEnd(';') + ';' + ($toAdd -join ';')).TrimStart(';')
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    $env:PATH = $env:PATH.TrimEnd(';') + ';' + ($toAdd -join ';')
    return $true
}

function Get-ActualLibDir ([string]$Root, [string[]]$Candidates) {
    foreach ($c in $Candidates) {
        $full = Join-Path $Root $c
        if (Test-Path $full) { return $full }
    }
    return $null
}

function Read-YN ([string]$Prompt) {
    return (Read-Host $Prompt).Trim().ToUpper() -eq 'Y'
}

function Test-InPath ([string]$Dir) {
    # check both system and user PATH buckets separately —
    # $env:PATH is the merged session view and doesn't distinguish between them
    $systemPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath   = [Environment]::GetEnvironmentVariable('PATH', 'User')
    return ($systemPath -like "*$Dir*") -or ($userPath -like "*$Dir*")
}

function Offer-AddToPath ([string]$Label, [string]$BinDir, [string]$LibDir) {
    $binMissing = -not (Test-InPath $BinDir)
    $libMissing = -not (Test-InPath $LibDir)

    if (-not $binMissing -and -not $libMissing) { return }

    Write-Host ""

    if ($binMissing) {
        # bin is needed for CLI tools (nvcc, trtexec etc) — offer to add
        Write-Host "  ⚠  $Label bin is not on your PATH:" -ForegroundColor DarkYellow
        Write-Host "       · $BinDir" -ForegroundColor White
        Write-Host ""
        if (Read-YN "     Add to your user PATH now? [Y/N]") {
            Add-ToUserPath -Dirs @($BinDir) | Out-Null
            Write-Host "     ✅ Added to user PATH." -ForegroundColor Green
        } else {
            Write-Host "     Skipped." -ForegroundColor DarkGray
        }
    }

    if ($libMissing) {
        # lib\x64 — build script passes it via /LIBPATH: so PATH is not required.
        # Just note it for awareness.
        Write-Host "  ℹ  $Label lib\x64 is not on your PATH (not required — build uses /LIBPATH:):" -ForegroundColor DarkGray
        Write-Host "       · $LibDir" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# FILESYSTEM FALLBACK — recursive DLL/exe discovery under NVIDIA toolkit root
# Used when nvcc or trtexec are not on PATH (common on messy NVIDIA machines).
# Returns the directory containing the file, or $null.
# ---------------------------------------------------------------------------
$NvToolkitRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit'

function Find-NvFile ([string]$FileName) {
    if (-not (Test-Path $NvToolkitRoot)) { return $null }
    $hit = Get-ChildItem -Path $NvToolkitRoot -Filter $FileName -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    return if ($hit) { $hit.DirectoryName } else { $null }
}

# Resolve CUDA root from any file found under it (walk up to the vX.Y folder)
function Resolve-CudaRoot ([string]$Dir) {
    # Walk up until we see a directory named v<major>.<minor>
    $current = $Dir
    while ($current -and $current -ne (Split-Path $current)) {
        if ((Split-Path $current -Leaf) -match '^v\d+\.\d+') { return $current }
        $current = Split-Path $current
    }
    return $null
}

# ---------------------------------------------------------------------------
# STATE
# ---------------------------------------------------------------------------
$allPassed = $true
$cfg       = @{}

Write-Host ""
Write-Host "  ── [2] Preflight Checks ────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

# ===========================================================================
# 1. WINGET
# ===========================================================================
$wingetOk  = $false
$wingetVer = ''
try {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $raw = winget --version 2>&1
        if ($raw -match 'v?(\d+[\.\d]+)') {
            $wingetVer = $Matches[1]
            $parts     = $wingetVer -split '\.' | Select-Object -First 2
            $wingetOk  = [Version]($parts -join '.') -ge $Manifest['winget'].MinVersion
        }
    }
} catch {}

Write-Check 'winget' $wingetOk `
    $(if ($wingetOk) { "v$wingetVer" } else { 'not found' })

if (-not $wingetOk) {
    Write-Host ""
    Write-Host "  winget is required to install Build Tools and .NET SDK." -ForegroundColor DarkYellow
    Write-Host "  Install App Installer from the Microsoft Store:" -ForegroundColor DarkYellow
    Write-Host "    ms-windows-store://pdp/?productid=9NBLGGH4NNS1" -ForegroundColor White
    Write-Host "  Or:" -ForegroundColor DarkYellow
    Write-Host "    https://aka.ms/getwinget" -ForegroundColor White
    Write-Host ""
    $allPassed = $false
}

# ===========================================================================
# 2. NVIDIA DRIVER  →  nvidia-smi
# ===========================================================================
Write-Host ""
$driverOk  = $false
$driverVer = ''
$gpuName   = ''

try {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $smi = nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>&1 |
               Select-Object -First 1
        if ($smi -match '^([\d\.]+),\s*(.+)$') {
            $driverVer = $Matches[1].Trim()
            $gpuName   = $Matches[2].Trim()
            $driverOk  = [Version]$driverVer -ge $Manifest['driver'].MinVersion
        }
    }
} catch {}

Write-Check 'NVIDIA Driver' $driverOk `
    $(if ($driverOk)      { "$driverVer   $gpuName" }
      elseif ($driverVer) { "$driverVer (need ≥ $($Manifest['driver'].MinVersion))   $gpuName" }
      else                { 'nvidia-smi not found' })

if (-not $driverOk) {
    Write-Host ""
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        Write-Host "  nvidia-smi was not found. This usually means:" -ForegroundColor DarkYellow
        Write-Host "    · NVIDIA driver is not installed" -ForegroundColor DarkYellow
        Write-Host "    · Driver installation is incomplete or corrupted" -ForegroundColor DarkYellow
        Write-Host "    · You may need to reboot after a recent install" -ForegroundColor DarkYellow
    } else {
        Write-Host "  Driver $driverVer is too old for CUDA 13 + TensorRT 10." -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "  Download the latest NVIDIA driver:" -ForegroundColor DarkYellow
    Write-Host "    $($Manifest['driver'].Url)" -ForegroundColor White
    Write-Host ""
    Write-Host "  After installing, reboot and re-run preflight." -ForegroundColor DarkGray
    $allPassed = $false
}

if ($gpuName)   { $cfg['gpu_name']       = $gpuName }
if ($driverVer) { $cfg['driver_version'] = $driverVer }

# ===========================================================================
# 3. CUDA TOOLKIT
#    Primary:  nvcc on PATH  →  walk up bin → cuda_root, then resolve bin\x64
#    Fallback: recursive scan of NVIDIA GPU Computing Toolkit root for cudart64_*.dll
#              Pick the highest vX.Y folder that satisfies MinVersion.
# ===========================================================================
Write-Host ""
$cudaOk   = $false
$cudaVer  = ''
$cudaRoot = ''
$cudaBin  = ''
$cudaLib  = ''

try {
    $nvccCmd = Get-Command nvcc -ErrorAction SilentlyContinue
    if ($nvccCmd) {
        $raw = (nvcc --version 2>&1) -join "`n"
        if ($raw -match 'release\s+(\d+\.\d+),') {
            $cudaVer  = $Matches[1]
            $cudaOk   = [Version]$cudaVer -ge $Manifest['cuda'].MinVersion
            $nvccDir  = Split-Path $nvccCmd.Source   # e.g. ...\CUDA\v13.1\bin
            $cudaRoot = Split-Path $nvccDir           # e.g. ...\CUDA\v13.1
            # DLLs live in bin\x64 on CUDA 13.x — verify and fall back to bin
            $x64bin   = Join-Path $cudaRoot 'bin\x64'
            $cudaBin  = if (Test-Path $x64bin) { $x64bin } else { $nvccDir }
            $cudaLib  = Get-ActualLibDir $cudaRoot @('lib\x64', 'lib')
        }
    }
} catch {}

# Fallback: nvcc not on PATH — scan filesystem
if (-not $cudaOk -and (Test-Path $NvToolkitRoot)) {
    Write-Host "  ℹ  nvcc not on PATH — scanning $NvToolkitRoot for CUDA installations..." -ForegroundColor DarkGray

    # Find all vX.Y CUDA folders, pick highest that meets MinVersion
    $cudaFolders = Get-ChildItem "$NvToolkitRoot\CUDA" -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '^v(\d+\.\d+)$' } |
                   Where-Object { [Version]$Matches[1] -ge $Manifest['cuda'].MinVersion } |
                   Sort-Object { [Version]($_.Name -replace '^v','') } -Descending

    foreach ($folder in $cudaFolders) {
        $candidate = $folder.FullName
        # Prefer bin\x64 (CUDA 13.x layout), fall back to bin
        $x64bin  = Join-Path $candidate 'bin\x64'
        $plainbin = Join-Path $candidate 'bin'
        $testBin  = if (Test-Path $x64bin) { $x64bin } else { $plainbin }

        # Confirm cudart is actually there
        if (Test-Path (Join-Path $testBin 'cudart64_*.dll') -ErrorAction SilentlyContinue) {
            $cudaRoot = $candidate
            $cudaBin  = $testBin
            $cudaLib  = Get-ActualLibDir $cudaRoot @('lib\x64', 'lib')
            $cudaVer  = ($folder.Name -replace '^v','')
            $cudaOk   = $true
            break
        }

        # Wildcard Test-Path not reliable in all PS versions — try Get-ChildItem
        $dllCheck = Get-ChildItem $testBin -Filter 'cudart64_*.dll' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
        if ($dllCheck) {
            $cudaRoot = $candidate
            $cudaBin  = $testBin
            $cudaLib  = Get-ActualLibDir $cudaRoot @('lib\x64', 'lib')
            $cudaVer  = ($folder.Name -replace '^v','')
            $cudaOk   = $true
            break
        }
    }

    if ($cudaOk) {
        Write-Host "  ℹ  Found via filesystem: CUDA $cudaVer at $cudaRoot" -ForegroundColor DarkGray
    }
}

Write-Check 'CUDA Toolkit' $cudaOk `
    $(if ($cudaOk)      { "$cudaVer   $cudaBin" }
      elseif ($cudaVer) { "$cudaVer (need ≥ $($Manifest['cuda'].MinVersion))   $cudaRoot" }
      else              { 'not found — nvcc not on PATH and no CUDA installation detected' })

if (-not $cudaOk) {
    Write-Host ""
    Write-Host "  CUDA Toolkit $($Manifest['cuda'].MinVersion)+ not found." -ForegroundColor DarkYellow
    Write-Host "  If CUDA is installed but nvcc is not on PATH, re-run preflight —" -ForegroundColor DarkYellow
    Write-Host "  we will scan $NvToolkitRoot automatically." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Download CUDA Toolkit 13.x:" -ForegroundColor DarkYellow
    Write-Host "    $($Manifest['cuda'].Url)" -ForegroundColor White
    $allPassed = $false
} else {
    # Only offer PATH if nvcc wasn't found there in the first place
    $nvccBin = Join-Path $cudaRoot 'bin'  # nvcc lives in bin, not bin\x64
    Offer-AddToPath 'CUDA' $nvccBin $cudaLib
    $cfg['cuda_root'] = $cudaRoot
    $cfg['cuda_bin']  = $cudaBin
    $cfg['cuda_lib']  = $cudaLib
}

# ===========================================================================
# 4. TENSORRT  →  trtexec
#    Primary:  trtexec on PATH  →  walk up to trt_root
#    Fallback: recursive scan of NVIDIA GPU Computing Toolkit root for nvinfer_10.dll
#    Version from NvInferVersion.h (authoritative), banner as fallback.
# ===========================================================================
Write-Host ""
$trtOk   = $false
$trtVer  = ''
$trtRoot = ''
$trtBin  = ''
$trtLib  = ''

try {
    $trtCmd = Get-Command trtexec -ErrorAction SilentlyContinue
    if ($trtCmd) {
        $trtBin  = Split-Path $trtCmd.Source
        $trtRoot = Split-Path $trtBin
        $trtLib  = Get-ActualLibDir $trtRoot @('lib\x64', 'lib')

        # primary — NvInferVersion.h
        $header = "$trtRoot\include\NvInferVersion.h"
        if (Test-Path $header) {
            $h     = Get-Content $header -Raw
            $major = if ($h -match '#define\s+NV_TENSORRT_MAJOR\s+(\d+)') { $Matches[1] } else { '' }
            $minor = if ($h -match '#define\s+NV_TENSORRT_MINOR\s+(\d+)') { $Matches[1] } else { '' }
            $patch = if ($h -match '#define\s+NV_TENSORRT_PATCH\s+(\d+)') { $Matches[1] } else { '0' }
            if ($major -and $minor) { $trtVer = "$major.$minor.$patch" }
        }

        # fallback — trtexec banner "TensorRT v101501"
        if (-not $trtVer) {
            $banner = (& $trtCmd.Source 2>&1) -join ' '
            if ($banner -match 'TensorRT v(\d{6})') {
                $raw    = $Matches[1]
                $trtVer = "$([int]$raw.Substring(0,2)).$([int]$raw.Substring(2,2)).$([int]$raw.Substring(4,2))"
            }
        }

        if ($trtVer) {
            $verForCompare = ($trtVer -split '\.')[0..1] -join '.'
            $trtOk = [Version]$verForCompare -ge $Manifest['tensorrt'].MinVersion
        }
    }
} catch {}

# Fallback: trtexec not on PATH — scan filesystem for nvinfer_10.dll
if (-not $trtOk -and (Test-Path $NvToolkitRoot)) {
    Write-Host "  ℹ  trtexec not on PATH — scanning $NvToolkitRoot for TensorRT..." -ForegroundColor DarkGray

    $nvinferHit = Get-ChildItem -Path $NvToolkitRoot -Filter 'nvinfer_10.dll' -Recurse -ErrorAction SilentlyContinue |
                  Select-Object -First 1

    if ($nvinferHit) {
        $candidateBin  = $nvinferHit.DirectoryName
        $candidateRoot = Split-Path $candidateBin  # bin → TensorRT-x.y.z.w

        # Read version from header
        $header = Join-Path $candidateRoot 'include\NvInferVersion.h'
        if (Test-Path $header) {
            $h     = Get-Content $header -Raw
            $major = if ($h -match '#define\s+NV_TENSORRT_MAJOR\s+(\d+)') { $Matches[1] } else { '' }
            $minor = if ($h -match '#define\s+NV_TENSORRT_MINOR\s+(\d+)') { $Matches[1] } else { '' }
            $patch = if ($h -match '#define\s+NV_TENSORRT_PATCH\s+(\d+)') { $Matches[1] } else { '0' }
            if ($major -and $minor) { $trtVer = "$major.$minor.$patch" }
        }

        if ($trtVer) {
            $verForCompare = ($trtVer -split '\.')[0..1] -join '.'
            $trtOk = [Version]$verForCompare -ge $Manifest['tensorrt'].MinVersion
        }

        if ($trtOk) {
            $trtRoot = $candidateRoot
            $trtBin  = $candidateBin
            $trtLib  = Get-ActualLibDir $trtRoot @('lib\x64', 'lib')
            Write-Host "  ℹ  Found via filesystem: TensorRT $trtVer at $trtRoot" -ForegroundColor DarkGray
        }
    }
}

Write-Check 'TensorRT' $trtOk `
    $(if ($trtOk)      { "$trtVer   $trtRoot" }
      elseif ($trtVer) { "$trtVer (need ≥ $($Manifest['tensorrt'].MinVersion))   $trtRoot" }
      else             { 'not found — trtexec not on PATH and no TensorRT installation detected' })

if (-not $trtOk) {
    Write-Host ""
    if (-not $trtVer) {
        Write-Host "  TensorRT does not add itself to PATH — it is a zip extract." -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Steps:" -ForegroundColor White
        Write-Host "    1.  Download TensorRT 10.x zip:" -ForegroundColor White
        Write-Host "          $($Manifest['tensorrt'].Url)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    2.  Extract it somewhere permanent, e.g.:" -ForegroundColor White
        Write-Host "          C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT-10.x.x.x" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    3.  Re-run [2] Preflight — we will scan for it automatically." -ForegroundColor White
        Write-Host "        Or add <trt_root>\bin to your PATH for trtexec access." -ForegroundColor DarkGray
    } else {
        Write-Host "  TensorRT $trtVer is too old. This tool requires TensorRT 10.x." -ForegroundColor DarkYellow
        Write-Host "    $($Manifest['tensorrt'].Url)" -ForegroundColor White
    }
    $allPassed = $false
} else {
    Offer-AddToPath 'TensorRT' $trtBin $trtLib
    $cfg['tensorrt_root'] = $trtRoot
    $cfg['tensorrt_bin']  = $trtBin
    $cfg['tensorrt_lib']  = $trtLib
}

# ===========================================================================
# 5. VS BUILD TOOLS  →  vswhere
# ===========================================================================
Write-Host ""
$btOk   = $false
$btVer  = ''
$btPath = ''
$vcvars = ''

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
    # already in a developer shell
    $btOk   = $true
    $btVer  = 'cl.exe in PATH'
    $vcvars = 'already active'
    Write-Check 'VS Build Tools' $true $btVer
} elseif (Test-Path $vswhere) {
    # search Build Tools then full VS editions
    $products = @(
        'Microsoft.VisualStudio.Product.BuildTools',
        'Microsoft.VisualStudio.Product.Community',
        'Microsoft.VisualStudio.Product.Professional',
        'Microsoft.VisualStudio.Product.Enterprise'
    )
    foreach ($product in $products) {
        try {
            $info = & $vswhere -latest -products $product `
                        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                        -format json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($info -and $info.installationPath) {
                $candidate = "$($info.installationPath)\VC\Auxiliary\Build\vcvars64.bat"
                if (Test-Path $candidate) {
                    $btVer  = $info.installationVersion
                    $btPath = $info.installationPath
                    $vcvars = $candidate
                    $btOk   = $true
                    break
                }
            }
        } catch {}
    }

    if ($btOk) {
        Write-Check 'VS Build Tools' $true "$btVer   $btPath"
    } else {
        # VS exists but no C++ workload
        $anyVS = try { & $vswhere -latest -products * -format json 2>$null |
                       ConvertFrom-Json -ErrorAction SilentlyContinue } catch { $null }
        if ($anyVS -and $anyVS.installationPath) {
            Write-Check 'VS Build Tools' $false `
                "$($anyVS.installationVersion) — C++ workload not installed"
            Write-Host ""
            Write-Host "  Visual Studio is installed but the C++ workload is missing." -ForegroundColor DarkYellow
            Write-Host "  Open Visual Studio Installer → Modify → check:" -ForegroundColor DarkYellow
            Write-Host "    'Desktop development with C++'" -ForegroundColor White
            Write-Host ""
            Write-Host "  Or reinstall via winget:" -ForegroundColor DarkYellow
            Write-Host "    winget install $($Manifest['buildtools'].WingetId) ``" -ForegroundColor White
            Write-Host "      --override `"$($Manifest['buildtools'].WingetArgs)`"" -ForegroundColor White
        } else {
            Write-Check 'VS Build Tools' $false 'not found'
            Write-Host ""
            Write-Host "  MSVC C++ compiler not found." -ForegroundColor DarkYellow
            Write-Host "  You need VS 2022 Build Tools — not the full IDE (~6 GB)." -ForegroundColor White
            Write-Host ""
            Write-Host "  Option A — winget (recommended, run as admin):" -ForegroundColor White
            Write-Host "    winget install $($Manifest['buildtools'].WingetId) ``" -ForegroundColor Cyan
            Write-Host "      --override `"$($Manifest['buildtools'].WingetArgs)`"" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Option B — manual:" -ForegroundColor White
            Write-Host "    $($Manifest['buildtools'].Url)" -ForegroundColor Cyan
            Write-Host "    → select 'Desktop development with C++'" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  After installing, restart your terminal and re-run preflight." -ForegroundColor DarkGray
            Write-Host "  You will never need to open Visual Studio." -ForegroundColor DarkGray
        }
        $allPassed = $false
    }
} else {
    Write-Check 'VS Build Tools' $false 'not found'
    Write-Host ""
    Write-Host "  MSVC C++ compiler not found." -ForegroundColor DarkYellow
    Write-Host "  You need VS 2022 Build Tools — not the full IDE (~6 GB)." -ForegroundColor White
    Write-Host ""
    Write-Host "  Option A — winget (recommended, run as admin):" -ForegroundColor White
    Write-Host "    winget install $($Manifest['buildtools'].WingetId) ``" -ForegroundColor Cyan
    Write-Host "      --override `"$($Manifest['buildtools'].WingetArgs)`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Option B — manual:" -ForegroundColor White
    Write-Host "    $($Manifest['buildtools'].Url)" -ForegroundColor Cyan
    Write-Host "    → select 'Desktop development with C++'" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  After installing, restart your terminal and re-run preflight." -ForegroundColor DarkGray
    Write-Host "  You will never need to open Visual Studio." -ForegroundColor DarkGray
    $allPassed = $false
}

if ($btOk) { $cfg['vcvars'] = $vcvars }

# ===========================================================================
# 6. .NET SDK  →  dotnet
# ===========================================================================
Write-Host ""
$dotnetOk  = $false
$dotnetVer = ''

try {
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $raw = dotnet --version 2>&1
        if ($raw -match '(\d+\.\d+)') {
            $dotnetVer = $Matches[1]
            $dotnetOk  = [Version]$dotnetVer -ge $Manifest['dotnet'].MinVersion
        }
    }
} catch {}

Write-Check '.NET SDK' $dotnetOk `
    $(if ($dotnetOk)      { $dotnetVer }
      elseif ($dotnetVer) { "$dotnetVer (need ≥ $($Manifest['dotnet'].MinVersion))" }
      else                { 'not found' })

if (-not $dotnetOk) {
    Write-Host ""
    Write-Host "  Install .NET SDK 9.x:" -ForegroundColor DarkYellow
    Write-Host "    winget install $($Manifest['dotnet'].WingetId)" -ForegroundColor White
    Write-Host "    $($Manifest['dotnet'].Url)" -ForegroundColor Cyan
    $allPassed = $false
}

# ===========================================================================
# 7. PYTHON  (informational — not a pass/fail, micromamba handles this)
# ===========================================================================
Write-Host ""
try {
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $pyVer = python --version 2>&1
        if ($pyVer -match 'Python\s+([\d\.]+)') {
            Write-Check 'Python' $true $Matches[1] -Info
            Write-Host "         $(' ' * 22) system Python — not used by this tool" -ForegroundColor DarkGray
            Write-Host "         $(' ' * 22) [4] Python env uses isolated micromamba" -ForegroundColor DarkGray
        }
    } else {
        Write-Check 'Python' $false 'not found' -Info
        Write-Host "         $(' ' * 22) optional — only needed for [4] Python environment" -ForegroundColor DarkGray
    }
} catch {}

# ===========================================================================
# SUMMARY + WRITE config.ini
# ===========================================================================
Write-Host ""
Write-Host "  ────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

if ($allPassed) {
    Write-Host "  ✅ All checks passed." -ForegroundColor Green
    Write-Host ""

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Derive the nvcc bin (not bin\x64 — nvcc itself lives in plain bin)
    $cudaNvccBin = if ($cudaRoot) { Join-Path $cudaRoot 'bin' } else { '' }

@"
; Demucs v4 TRT — machine config
; Generated by setup_preflight.ps1 on $timestamp
; Do not commit — see .gitignore
; Re-run [2] Preflight to regenerate.

[machine]
preflight_passed  = true
preflight_date    = $timestamp
gpu_name          = $($cfg['gpu_name'])
driver_version    = $($cfg['driver_version'])
cuda_root         = $($cfg['cuda_root'])
cuda_bin          = $($cfg['cuda_bin'])
cuda_lib          = $($cfg['cuda_lib'])
tensorrt_root     = $($cfg['tensorrt_root'])
tensorrt_bin      = $($cfg['tensorrt_bin'])
tensorrt_lib      = $($cfg['tensorrt_lib'])
vcvars            = $($cfg['vcvars'])

[runtime]
; These paths are read by Demucs_v4_TRT.exe at startup to prepend to the
; process-local PATH so CUDA and TensorRT DLLs are found without touching
; your system PATH or copying files anywhere.
; cuda_bin points to bin\x64 where the actual runtime DLLs live on CUDA 13.x.
TRT_BIN  = $($cfg['tensorrt_bin'])
CUDA_BIN = $($cfg['cuda_bin'])
"@ | Set-Content $ConfigFile -Encoding UTF8

    Write-Host "  + config.ini written." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    cuda_bin  →  $($cfg['cuda_bin'])" -ForegroundColor DarkGray
    Write-Host "    trt_bin   →  $($cfg['tensorrt_bin'])" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  You can now proceed to [5] Build." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

} else {
    Write-Host "  ❌ One or more checks failed." -ForegroundColor Red
    Write-Host "     Resolve the items above and re-run [2] Preflight." -ForegroundColor DarkYellow
    Write-Host "     [3] Install dependencies can handle winget-installable items." -ForegroundColor DarkYellow

    # stamp config.ini so Build stays gated
    if (Test-Path $ConfigFile) {
        $content = (Get-Content $ConfigFile -Raw) -replace 'preflight_passed\s*=\s*true', 'preflight_passed = false'
        $content | Set-Content $ConfigFile -Encoding UTF8
    }

    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}