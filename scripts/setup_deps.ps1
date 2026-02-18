#Requires -Version 7.5
# scripts/setup_deps.ps1
# Offers to install winget-installable dependencies one at a time.
# Manual deps (CUDA, TensorRT, NVIDIA Driver) are shown with links only.
# Called by setup.ps1 — do not run directly.

param(
    [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary] $Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "  ── [3] Install Dependencies ────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Winget-installable items can be installed from here." -ForegroundColor White
Write-Host "  NVIDIA Driver, CUDA Toolkit, and TensorRT require manual install." -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# HELPER — run a winget install with live output
# ---------------------------------------------------------------------------
function Invoke-WingetInstall {
    param([string]$Id, [string]$Args)

    $cmd = "winget install --id $Id --accept-package-agreements --accept-source-agreements"
    if ($Args) { $cmd += " --override `"$Args`"" }

    Write-Host ""
    Write-Host "  Running: $cmd" -ForegroundColor DarkGray
    Write-Host ""
    Invoke-Expression $cmd
    return $LASTEXITCODE -eq 0
}

# ---------------------------------------------------------------------------
# MANUAL DEPS — display only
# ---------------------------------------------------------------------------
Write-Host "  ── Manual install required ─────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$manualDeps = @('driver', 'cuda', 'tensorrt')
foreach ($key in $manualDeps) {
    $dep = $Manifest[$key]
    Write-Host "  $($dep.Label.PadRight(22)) ≥ $($dep.MinVersion.Major).$($dep.MinVersion.Minor)" -ForegroundColor White
    Write-Host "  $(' ' * 22)   $($dep.Url)" -ForegroundColor DarkGray
    if ($dep.Note) {
        Write-Host "  $(' ' * 22)   ↑ $($dep.Note)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# WINGET DEPS — offer to install each
# ---------------------------------------------------------------------------
Write-Host "  ── Install via winget ──────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# Check winget first
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "  ❌ winget not found — cannot install anything automatically." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Install App Installer from the Microsoft Store:" -ForegroundColor DarkYellow
    Write-Host "  $($Manifest['winget'].Url)" -ForegroundColor White
    Write-Host ""
    return
}

$wingetDeps = $Manifest.Keys | Where-Object { $Manifest[$_].WingetId }

foreach ($key in $wingetDeps) {
    $dep = $Manifest[$key]

    # Check if already installed
    $alreadyInstalled = $false
    switch ($key) {
        'buildtools' {
            $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
            if (Test-Path $vswhere) {
                $found = & $vswhere -latest -products * `
                           -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 2>$null
                $alreadyInstalled = [bool]$found
            }
            if (-not $alreadyInstalled) {
                $alreadyInstalled = [bool](Get-Command cl.exe -ErrorAction SilentlyContinue)
            }
        }
        'dotnet' {
            if (Get-Command dotnet -ErrorAction SilentlyContinue) {
                $v = dotnet --version 2>&1
                if ($v -match '(\d+)\.' -and [int]$Matches[1] -ge $dep.MinVersion.Major) {
                    $alreadyInstalled = $true
                }
            }
        }
    }

    $statusTag = if ($alreadyInstalled) { " (already installed)" } else { "" }
    Write-Host "  $($dep.Label)$statusTag" -ForegroundColor $(if ($alreadyInstalled) { 'Green' } else { 'White' })
    Write-Host "  winget install $($dep.WingetId)" -ForegroundColor DarkGray
    if ($dep.WingetArgs) {
        Write-Host "  args: $($dep.WingetArgs)" -ForegroundColor DarkGray
    }
    Write-Host ""

    if (-not $alreadyInstalled) {
        $answer = Read-Host "  Install $($dep.Label) now? [Y/N]"
        if ($answer.Trim().ToUpper() -eq 'Y') {
            $ok = Invoke-WingetInstall -Id $dep.WingetId -Args $dep.WingetArgs
            if ($ok) {
                Write-Host ""
                Write-Host "  ✅ $($dep.Label) installed." -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "  ⚠  winget returned a non-zero exit code." -ForegroundColor DarkYellow
                Write-Host "     Check output above. It may still have installed correctly." -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  Skipped." -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

Write-Host "  ────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  After installing dependencies, run [2] Preflight to validate." -ForegroundColor Cyan