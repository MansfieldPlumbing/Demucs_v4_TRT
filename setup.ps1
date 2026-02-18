#Requires -Version 7.5
# setup.ps1
# Root orchestrator for Demucs v4 TRT.
# Builds $Manifest and $Paths, presents the menu loop, delegates to child scripts.
# Nothing happens without the user opting in. Every action returns to this menu.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# POWERSHELL VERSION GATE
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion -lt [Version]"7.5") {
    Write-Host ""
    Write-Host "  ERROR: PowerShell $($PSVersionTable.PSVersion) detected." -ForegroundColor Red
    Write-Host "  Demucs v4 TRT requires PowerShell 7.5 or later." -ForegroundColor Red
    Write-Host ""
    Write-Host "  winget install Microsoft.PowerShell" -ForegroundColor White
    Write-Host "  https://github.com/PowerShell/PowerShell/releases/latest" -ForegroundColor DarkYellow
    Write-Host ""
    pause
    exit 1
}

# ---------------------------------------------------------------------------
# PATHS
# ---------------------------------------------------------------------------
$ProjectRoot = $PSScriptRoot
$ConfigFile  = "$ProjectRoot\config.ini"
$ScriptsDir  = "$ProjectRoot\scripts"

# ---------------------------------------------------------------------------
# MANIFEST — single source of truth for all dependency requirements.
# These constants are never hardcoded anywhere else. Scripts read from here.
# config.ini is generated from discovery — this defines what we are looking for.
# ---------------------------------------------------------------------------
$Manifest = [ordered]@{

    winget = [PSCustomObject]@{
        Label      = 'winget'
        MinVersion = [Version]'1.0'
        WingetId   = $null
        WingetArgs = $null
        Url        = 'https://aka.ms/getwinget'
        UrlLabel   = 'aka.ms/getwinget'
        Note       = $null
    }

    driver = [PSCustomObject]@{
        Label      = 'NVIDIA Driver'
        MinVersion = [Version]'561.0'
        WingetId   = $null
        WingetArgs = $null
        Url        = 'https://www.nvidia.com/drivers'
        UrlLabel   = 'nvidia.com/drivers'
        Note       = $null
    }

    cuda = [PSCustomObject]@{
        Label      = 'CUDA Toolkit'
        MinVersion = [Version]'13.0'
        WingetId   = $null
        WingetArgs = $null
        Url        = 'https://developer.nvidia.com/cuda-downloads'
        UrlLabel   = 'developer.nvidia.com/cuda-downloads'
        Note       = 'custom installer — not winget'
        Registry   = 'HKLM:\SOFTWARE\NVIDIA Corporation\GPU Computing Toolkit\CUDA'
        Glob       = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*'
    }

    tensorrt = [PSCustomObject]@{
        Label      = 'TensorRT SDK'
        MinVersion = [Version]'10.0'
        WingetId   = $null
        WingetArgs = $null
        Url        = 'https://developer.nvidia.com/tensorrt'
        UrlLabel   = 'developer.nvidia.com/tensorrt'
        Note       = 'zip extract — note where you put it'
        Globs      = @(
            'C:\Program Files\NVIDIA GPU Computing Toolkit\TensorRT*',
            'C:\TensorRT*'
        )
    }

    buildtools = [PSCustomObject]@{
        Label      = 'VS Build Tools'
        MinVersion = [Version]'2022.0'
        WingetId   = 'Microsoft.VisualStudio.2022.BuildTools'
        WingetArgs = '--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        Url        = 'https://aka.ms/vs/17/release/vs_buildtools.exe'
        UrlLabel   = 'aka.ms/vs/17/release/vs_buildtools.exe'
        Note       = 'C++ build tools only — no IDE'
    }

    dotnet = [PSCustomObject]@{
        Label      = '.NET SDK'
        MinVersion = [Version]'9.0'
        WingetId   = 'Microsoft.DotNet.SDK.9'
        WingetArgs = $null
        Url        = 'https://dotnet.microsoft.com/download/dotnet/9.0'
        UrlLabel   = 'dotnet.microsoft.com/download/dotnet/9.0'
        Note       = $null
    }
}

# ---------------------------------------------------------------------------
# DLL MANIFEST — every DLL required at runtime, source keyed to [machine] paths.
# required = true means hard stop if missing at bundle time.
# ---------------------------------------------------------------------------
$DllManifest = @(
    # TensorRT DLLs — all in <trt_root>\bin (not \lib)
    [PSCustomObject]@{ Name = 'nvinfer_10.dll';                       Source = 'tensorrt_bin'; Required = $true  }
    [PSCustomObject]@{ Name = 'nvinfer_plugin_10.dll';                Source = 'tensorrt_bin'; Required = $true  }
    # sm86 = RTX 3090 / RTX 3080 (Ampere). If targeting other GPUs, add their sm variant here.
    [PSCustomObject]@{ Name = 'nvinfer_builder_resource_sm86_10.dll'; Source = 'tensorrt_bin'; Required = $true  }
    [PSCustomObject]@{ Name = 'nvinfer_lean_10.dll';                  Source = 'tensorrt_bin'; Required = $true  }
    # CUDA DLLs — in <cuda_root>\bin\x64 (note: _13 suffix, cufft is _12)
    [PSCustomObject]@{ Name = 'cudart64_13.dll';                      Source = 'cuda_bin';     Required = $true  }
    [PSCustomObject]@{ Name = 'cublas64_13.dll';                      Source = 'cuda_bin';     Required = $true  }
    [PSCustomObject]@{ Name = 'cublasLt64_13.dll';                    Source = 'cuda_bin';     Required = $true  }
    [PSCustomObject]@{ Name = 'cufft64_12.dll';                       Source = 'cuda_bin';     Required = $true  }
    # MSVC runtime — always in System32, not bundled
    [PSCustomObject]@{ Name = 'msvcp140.dll';                         Source = 'system';       Required = $true  }
    [PSCustomObject]@{ Name = 'vcruntime140.dll';                     Source = 'system';       Required = $true  }
    [PSCustomObject]@{ Name = 'vcruntime140_1.dll';                   Source = 'system';       Required = $true  }
)

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
function Read-Config {
    $cfg = @{}
    if (Test-Path $ConfigFile) {
        $section = ''
        Get-Content $ConfigFile | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^\[(.+)\]$')          { $section = $Matches[1] }
            elseif ($line -match '^([^;=]+)=(.*)$') { $cfg["$section.$($Matches[1].Trim())"] = $Matches[2].Trim() }
        }
    }
    return $cfg
}

function Get-ConfigValue([string]$Key) {
    $cfg = Read-Config
    return $cfg[$Key]
}

function Test-PreflightPassed {
    return (Get-ConfigValue 'machine.preflight_passed') -eq 'true'
}

function Get-PreflightStatus {
    if (-not (Test-Path $ConfigFile)) { return 'never' }
    $val = Get-ConfigValue 'machine.preflight_passed'
    if ($val -eq 'true')  { return 'passed' }
    if ($val -eq 'false') { return 'failed' }
    return 'never'
}

function Build-Paths {
    $cfg = Read-Config
    return [PSCustomObject]@{
        ProjectRoot  = $ProjectRoot
        ConfigFile   = $ConfigFile
        ScriptsDir   = $ScriptsDir
        CudaRoot     = $cfg['machine.cuda_root']
        CudaBin      = $cfg['machine.cuda_bin']
        TrtRoot      = $cfg['machine.tensorrt_root']
        TrtBin       = $cfg['machine.tensorrt_bin']
        MambaExe     = "$env:LOCALAPPDATA\micromamba\micromamba.exe"
        MambaRoot    = "$env:USERPROFILE\micromamba"
        EnvName      = 'demucs-trt'
        EnvFile      = "$ProjectRoot\python\environment.yml"
        SrcCpp       = "$ProjectRoot\src\demucs_v4_trt.cpp"
        OutDll       = "$ProjectRoot\demucs_v4_trt.dll"
        Manifest     = $Manifest
        DllManifest  = $DllManifest
    }
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ████████████████████████████████████████████████████████" -ForegroundColor Cyan
    Write-Host "  ██                                                    ██" -ForegroundColor Cyan
    Write-Host "  ██   DEMUCS V4 TRT                                    ██" -ForegroundColor Cyan
    Write-Host "  ██   6-stem audio separator  ·  HTDemucs + TensorRT   ██" -ForegroundColor Cyan
    Write-Host "  ██   drums · bass · other · vocals · guitar · piano   ██" -ForegroundColor Cyan
    Write-Host "  ██                                                    ██" -ForegroundColor Cyan
    Write-Host "  ████████████████████████████████████████████████████████" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  PowerShell $($PSVersionTable.PSVersion)  |  $ProjectRoot" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Dependencies {
    Write-Host "  ── What you need ───────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""

    $col1 = 20
    $col2 = 10

    foreach ($key in $Manifest.Keys) {
        $dep = $Manifest[$key]
        $label   = $dep.Label.PadRight($col1)
        $version = "≥ $($dep.MinVersion.Major).$($dep.MinVersion.Minor)".PadRight($col2)
        Write-Host "  $label $version $($dep.Url)" -ForegroundColor White
        if ($dep.Note) {
            Write-Host "  $(' ' * ($col1 + $col2 + 1)) ↑ $($dep.Note)" -ForegroundColor DarkGray
        }
        if ($dep.WingetId) {
            Write-Host "  $(' ' * ($col1 + $col2 + 1)) winget install $($dep.WingetId)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  ────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Menu {
    $status = Get-PreflightStatus
    $preflightTag = switch ($status) {
        'passed' { "  ✅ passed" }
        'failed' { "  ❌ last run failed" }
        default  { "  ⚠  not yet run" }
    }
    $buildTag  = if ($status -eq 'passed') { "" } else { "  ⚠  preflight required" }
    $buildColor = if ($status -eq 'passed') { 'White' } else { 'DarkGray' }

    Write-Host "  What would you like to do?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1]  Unblock scripts" -ForegroundColor White
    Write-Host "    [2]  Preflight checks$preflightTag" -ForegroundColor White
    Write-Host "    [3]  Install dependencies" -ForegroundColor White
    Write-Host "    [4]  Python environment     (optional — engine building + validation)" -ForegroundColor DarkGray
    Write-Host "    [5]  Build$buildTag" -ForegroundColor $buildColor
    Write-Host "    [Q]  Quit" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# STEP 1 — UNBLOCK
# ---------------------------------------------------------------------------
function Invoke-Unblock {
    Write-Host ""
    Write-Host "  ── [1] Unblock Scripts ─────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  When you download files from the internet, Windows attaches a" -ForegroundColor DarkGray
    Write-Host "  'Mark of the Web' (MOTW) tag that blocks scripts from running." -ForegroundColor DarkGray
    Write-Host "  This step removes those tags from all .ps1 / .bat / .py files" -ForegroundColor DarkGray
    Write-Host "  in this repo so setup can proceed normally." -ForegroundColor DarkGray
    Write-Host "  You only need to do this once after cloning." -ForegroundColor DarkGray
    Write-Host ""

    $files = Get-ChildItem $ProjectRoot -Recurse -Include "*.ps1","*.bat","*.py" -ErrorAction SilentlyContinue
    $count = 0
    foreach ($f in $files) {
        try {
            Unblock-File $f.FullName -ErrorAction SilentlyContinue
            Write-Host "  + $($f.Name)" -ForegroundColor DarkGray
            $count++
        } catch {}
    }

    Write-Host ""
    Write-Host "  ✅ $count files unblocked." -ForegroundColor Green
    Write-Host ""
    Start-Sleep -Milliseconds 800
    # return to menu — no pause needed, the loop redraws
}

# ---------------------------------------------------------------------------
# STEP 2 — PREFLIGHT
# ---------------------------------------------------------------------------
function Invoke-Preflight {
    Write-Host ""
    & "$ScriptsDir\setup_preflight.ps1" -ProjectRoot $ProjectRoot -ConfigFile $ConfigFile -Manifest $Manifest
    # preflight script handles its own "press any key" on error — no second prompt needed
}

# ---------------------------------------------------------------------------
# STEP 3 — INSTALL DEPENDENCIES
# ---------------------------------------------------------------------------
function Invoke-InstallDeps {
    Write-Host ""
    & "$ScriptsDir\setup_deps.ps1" -Manifest $Manifest
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ---------------------------------------------------------------------------
# STEP 4 — PYTHON ENVIRONMENT (optional)
# ---------------------------------------------------------------------------
function Invoke-Python {
    Write-Host ""
    $Paths = Build-Paths
    & "$ScriptsDir\setup_python.ps1" -Paths $Paths
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ---------------------------------------------------------------------------
# STEP 5 — BUILD
# ---------------------------------------------------------------------------
function Invoke-Build {
    if (-not (Test-PreflightPassed)) {
        Write-Host ""
        Write-Host "  ✋ Preflight has not been run or has unresolved failures." -ForegroundColor Red
        Write-Host "     Run [2] Preflight checks before building." -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }

    Write-Host ""
    $Paths = Build-Paths
    & "$ScriptsDir\build_demucs_v4_trt.ps1" -Paths $Paths -DllManifest $DllManifest
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ---------------------------------------------------------------------------
# MENU LOOP
# ---------------------------------------------------------------------------
do {
    Show-Banner
    Show-Dependencies
    Show-Menu

    $choice = Read-Host "  Enter selection"
    Write-Host ""

    switch ($choice.Trim().ToUpper()) {
        "1" { Invoke-Unblock }
        "2" { Invoke-Preflight }
        "3" { Invoke-InstallDeps }
        "4" { Invoke-Python }
        "5" { Invoke-Build }
        "Q" {
            Write-Host "  Bye." -ForegroundColor DarkGray
            Write-Host ""
            exit 0
        }
        default {
            Write-Host "  Invalid selection." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }

} while ($true)