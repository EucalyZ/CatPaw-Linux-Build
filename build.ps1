#!/usr/bin/env pwsh
<#
.SYNOPSIS
    One-click CatPawAI Linux build orchestrator.
.DESCRIPTION
    This script orchestrates the full build process:
    1. Extracts app resources from DMG (Windows)
    2. Invokes WSL2 to build native modules and package for Linux
.PARAMETER Arch
    Target architecture: x64 or arm64 (default: x64)
.PARAMETER SkipExtract
    Skip DMG extraction (use existing extracted resources)
.PARAMETER SkipDownload
    Skip Electron download (use existing downloaded Electron)
.EXAMPLE
    .\build.ps1
    .\build.ps1 -Arch arm64
#>
param(
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$SkipExtract,
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "`n${CYAN}========================================${NC}" -ForegroundColor Cyan
Write-Host "  CatPawAI Linux Build Orchestrator" -ForegroundColor Cyan
Write-Host "========================================${NC}" -ForegroundColor Cyan
Write-Host "  Architecture: $Arch"
Write-Host "  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ─── Phase 1: Extract DMG ────────────────────────────────────────────────────
if (-not $SkipExtract) {
    Write-Host "`n${YELLOW}[Phase 1] Extract DMG${NC}" -ForegroundColor Yellow
    & "$ScriptDir\extract-dmg.ps1"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "DMG extraction failed"
        exit 1
    }
} else {
    Write-Host "`n${YELLOW}[Phase 1] Skipping DMG extraction${NC}" -ForegroundColor Yellow
}

# ─── Phase 2: WSL2 Build ─────────────────────────────────────────────────────
Write-Host "`n${YELLOW}[Phase 2] WSL2 Linux Build${NC}" -ForegroundColor Yellow

# Check WSL2
$wslCheck = wsl --status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "WSL2 is not available. Please install WSL2: wsl --install"
    exit 1
}

# Convert Windows path to WSL path for the script directory
$WslScriptDir = (wsl wslpath -u $ScriptDir.Replace('\', '/')).Trim()
if ([string]::IsNullOrWhiteSpace($WslScriptDir)) {
    # Fallback: manual conversion
    $WslScriptDir = $ScriptDir -replace 'C:', '/mnt/c' -replace '\\', '/' -replace 'c:', '/mnt/c'
}

Write-Host "  WSL path: $WslScriptDir"
Write-Host "  Running build-linux.sh in WSL2..."

# Build arguments
$buildArgs = @("--arch", $Arch)
if ($SkipExtract) { $buildArgs += "--skip-extract" }
if ($SkipDownload) { $buildArgs += "--skip-download" }

$buildArgsStr = $buildArgs -join " "

# Run the build script in WSL2
wsl bash -c "cd '$WslScriptDir' && chmod +x scripts/build-linux.sh && bash scripts/build-linux.sh $buildArgsStr"

if ($LASTEXITCODE -ne 0) {
    Write-Error "WSL2 build failed (exit code: $LASTEXITCODE)"
    exit 1
}

# ─── Phase 3: Report ─────────────────────────────────────────────────────────
Write-Host "`n${GREEN}========================================${NC}" -ForegroundColor Green
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "========================================${NC}" -ForegroundColor Green

$OutDir = Join-Path $ScriptDir "scripts\out"
if (Test-Path $OutDir) {
    Write-Host "`nOutput files:"
    Get-ChildItem $OutDir -Filter "*.tar.gz" | ForEach-Object {
        $sizeMB = [math]::Round($_.Length / 1MB, 1)
        Write-Host "  $($_.Name) ($sizeMB MB)" -ForegroundColor Green
    }
    Get-ChildItem $OutDir -Filter "*.deb" | ForEach-Object {
        $sizeMB = [math]::Round($_.Length / 1MB, 1)
        Write-Host "  $($_.Name) ($sizeMB MB)" -ForegroundColor Green
    }
}
