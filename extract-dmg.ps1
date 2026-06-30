#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Extract CatPawAI app resources from macOS DMG file.
.DESCRIPTION
    Uses 7-Zip to extract the app directory from the DMG.
    The extracted resources will be used by the Linux build script.
.PARAMETER DmgPath
    Path to the CatPawAI DMG file.
.PARAMETER OutDir
    Output directory for extracted resources.
#>
param(
    [string]$DmgPath = (Resolve-Path "..\CatPawAI-x64*.dmg" -ErrorAction Stop).Path,
    [string]$OutDir = ".\extracted"
)

$ErrorActionPreference = "Stop"

# Find 7-Zip
$SevenZip = $null
foreach ($candidate in @(
    "C:\Program Files\7-Zip\7z.exe",
    (Get-Command 7z -ErrorAction SilentlyContinue)?.Source,
    (Get-Command 7zz -ErrorAction SilentlyContinue)?.Source
)) {
    if ($candidate -and (Test-Path $candidate)) { $SevenZip = $candidate; break }
}
if (-not $SevenZip) {
    Write-Error "7-Zip not found. Install it: winget install 7zip.7zip"
    exit 1
}

Write-Host "`n== CatPawAI DMG Extractor ==" -ForegroundColor Cyan
Write-Host "   DMG:  $DmgPath"
Write-Host "   7zip: $SevenZip"
Write-Host "   Out:  $OutDir"

# Clean output
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Extract the app directory and key resources from DMG
Write-Host "`n[1/3] Extracting app resources from DMG..." -ForegroundColor Yellow
& $SevenZip x $DmgPath -o"_dmg-raw" -y `
    "CatPawAI-x64\CatPawAI.app\Contents\Resources\app\*" `
    "CatPawAI-x64\CatPawAI.app\Contents\Resources\CatPawAI.icns" `
    "CatPawAI-x64\CatPawAI.app\Contents\Info.plist" 2>&1 | Out-Null

$AppSrc = "_dmg-raw\CatPawAI-x64\CatPawAI.app\Contents\Resources\app"
if (-not (Test-Path $AppSrc)) {
    Write-Error "Failed to extract app directory from DMG"
    exit 1
}

# Copy app directory to output
Write-Host "[2/3] Copying app resources..." -ForegroundColor Yellow
Copy-Item $AppSrc -Destination (Join-Path $OutDir "app") -Recurse -Force

# Copy icon
$IcnsSrc = "_dmg-raw\CatPawAI-x64\CatPawAI.app\Contents\Resources\CatPawAI.icns"
if (Test-Path $IcnsSrc) {
    Copy-Item $IcnsSrc -Destination (Join-Path $OutDir "CatPawAI.icns") -Force
}

# Copy Info.plist for reference
$PlistSrc = "_dmg-raw\CatPawAI-x64\CatPawAI.app\Contents\Info.plist"
if (Test-Path $PlistSrc) {
    Copy-Item $PlistSrc -Destination (Join-Path $OutDir "Info.plist") -Force
}

# Cleanup raw extraction
Remove-Item "_dmg-raw" -Recurse -Force -ErrorAction SilentlyContinue

# Report
$AppDir = Join-Path $OutDir "app"
$FileCount = (Get-ChildItem $AppDir -Recurse -File).Count
$SizeMB = [math]::Round((Get-ChildItem $AppDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB, 1)

Write-Host "[3/3] Done!" -ForegroundColor Green
Write-Host "   Files: $FileCount"
Write-Host "   Size:  $SizeMB MB"
Write-Host "   Path:  $(Resolve-Path $OutDir)"
