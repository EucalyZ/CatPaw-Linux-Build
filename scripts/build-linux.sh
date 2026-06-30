#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# CatPawAI Linux Build Script
#
# This script runs in WSL2 (Ubuntu) and builds a Linux version of CatPawAI
# from the macOS DMG resources.
#
# Usage:
#   ./build-linux.sh [--arch x64|arm64] [--skip-extract] [--skip-download]
#
# Requirements:
#   - WSL2 Ubuntu with build-essential, python3, nodejs
#   - 7zip installed in Windows (for DMG extraction)
#   - The DMG file at ../CatPawAI-x64*.dmg
#=============================================================================

# ─── Configuration ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use native Linux filesystem (/tmp) for intermediate operations — 10-100x faster than /mnt/c/
TMP_ROOT="/tmp/catpawai-build"
BUILD_DIR="$TMP_ROOT/build"
EXTRACTED_DIR="$TMP_ROOT/extracted"
DOWNLOAD_DIR="$TMP_ROOT/downloads"
OUT_DIR="$SCRIPT_DIR/out"

# App info (read from product.json)
ELECTRON_VERSION="35.5.1"
APP_NAME="CatPawAI"
APP_VERSION="1.101.0"
CATPAW_VERSION="2026.2.3"
BUNDLE_ID="com.catpaw.ide"

# Architecture
ARCH="${1:-x64}"
# Map to Electron arch naming
ELECTRON_ARCH="$ARCH"  # x64 or arm64

# Parse args
SKIP_EXTRACT=false
SKIP_DOWNLOAD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; ELECTRON_ARCH="$2"; shift 2 ;;
    --skip-extract) SKIP_EXTRACT=true; shift ;;
    --skip-download) SKIP_DOWNLOAD=true; shift ;;
    *) shift ;;
  esac
done

# Linux arch mapping
LINUX_ARCH="$ARCH"
[[ "$ARCH" == "x64" ]] && LINUX_ARCH="x86_64"
[[ "$ARCH" == "arm64" ]] && LINUX_ARCH="aarch64"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} WARN: $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)]${NC} ERROR: $*" >&2; }

#=============================================================================
# Phase 0: Check prerequisites
#=============================================================================
log "${CYAN}== Phase 0: Prerequisites ==${NC}"

# Check if running in WSL
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  # Not in WSL, check if we're on native Linux
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "This script must run in WSL2 or native Linux"
    exit 1
  fi
fi

# Install build dependencies if needed
install_deps() {
  log "Checking build dependencies..."
  local need_install=false

  # Check for essential tools
  for cmd in gcc g++ make python3 node npm curl; do
    if ! command -v $cmd &>/dev/null; then
      need_install=true
      break
    fi
  done

  if $need_install; then
    log "Installing build dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq build-essential python3 python3-dev \
      curl wget file desktop-file-utils unzip p7zip-full \
      libkrb5-dev libx11-dev libxkbfile-dev libsecret-1-dev \
      libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 \
      xdg-utils libatspi2.0-0 libdrm2 libgbm1 2>/dev/null

    # Install Node.js 22.x if not present
    if ! command -v node &>/dev/null; then
      log "Installing Node.js 22.x..."
      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - -qq
      sudo apt-get install -y -qq nodejs
    fi
  fi

  log "Node: $(node --version), npm: $(npm --version)"
  log "gcc: $(gcc --version | head -1)"
}

install_deps

#=============================================================================
# Phase 1: Extract DMG (if not already done)
#=============================================================================
if ! $SKIP_EXTRACT; then
  log "${CYAN}== Phase 1: Extract DMG ==${NC}"

  # Check if extracted dir already exists
  if [[ -f "$EXTRACTED_DIR/app/package.json" ]]; then
    log "Extracted app already exists, skipping. Use --skip-extract to force."
  else
    # Try to find the DMG file
    DMG_PATH=""
    for candidate in \
      "$PROJECT_ROOT/CatPawAI-x64"*.dmg \
      "/mnt/c/LinuxBackup/catpaw-linux/CatPawAI-x64"*.dmg; do
      if ls $candidate 1>/dev/null 2>&1; then
        DMG_PATH=$(ls $candidate 2>/dev/null | head -1)
        break
      fi
    done

    if [[ -z "$DMG_PATH" ]]; then
      err "DMG file not found. Run extract-dmg.ps1 on Windows first."
      err "Or place the extracted app in: $EXTRACTED_DIR/app/"
      exit 1
    fi

    log "DMG: $DMG_PATH"

    # Find 7zip (prefer Linux p7zip over Windows 7z.exe for path compatibility)
    SEVENZ=""
    if command -v 7z &>/dev/null; then
      SEVENZ="7z"
    elif command -v 7zz &>/dev/null; then
      SEVENZ="7zz"
    else
      log "Installing p7zip..."
      sudo apt-get install -y -qq p7zip-full 2>/dev/null
      SEVENZ="7z"
    fi

    log "Extracting app resources from DMG..."
    TMP_EXTRACT="$TMP_ROOT/_dmg-raw"
    rm -rf "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT"

    # Extract using 7zip
    "$SEVENZ" x "$DMG_PATH" -o"$TMP_EXTRACT" -y \
      "CatPawAI-x64/CatPawAI.app/Contents/Resources/app/*" \
      "CatPawAI-x64/CatPawAI.app/Contents/Resources/CatPawAI.icns" \
      "CatPawAI-x64/CatPawAI.app/Contents/Info.plist" 2>/dev/null || true

    APP_SRC="$TMP_EXTRACT/CatPawAI-x64/CatPawAI.app/Contents/Resources/app"
    if [[ ! -d "$APP_SRC" ]]; then
      err "Failed to extract app from DMG"
      exit 1
    fi

    # Copy to extracted dir
    mkdir -p "$EXTRACTED_DIR"
    cp -r "$APP_SRC" "$EXTRACTED_DIR/app"

    # Copy icon and plist
    [[ -f "$TMP_EXTRACT/CatPawAI-x64/CatPawAI.app/Contents/Resources/CatPawAI.icns" ]] && \
      cp "$TMP_EXTRACT/CatPawAI-x64/CatPawAI.app/Contents/Resources/CatPawAI.icns" "$EXTRACTED_DIR/"
    [[ -f "$TMP_EXTRACT/CatPawAI-x64/CatPawAI.app/Contents/Info.plist" ]] && \
      cp "$TMP_EXTRACT/CatPawAI-x64/CatPawAI.app/Contents/Info.plist" "$EXTRACTED_DIR/"

    # Cleanup
    rm -rf "$TMP_EXTRACT"

    log "Extraction complete: $(find "$EXTRACTED_DIR/app" -type f | wc -l) files"
  fi
fi

#=============================================================================
# Phase 2: Download Electron for Linux
#=============================================================================
if ! $SKIP_DOWNLOAD; then
  log "${CYAN}== Phase 2: Download Electron ${ELECTRON_VERSION} for Linux-${ARCH} ==${NC}"

  ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${ELECTRON_ARCH}.zip"
  ELECTRON_ZIP="$DOWNLOAD_DIR/electron-v${ELECTRON_VERSION}-linux-${ELECTRON_ARCH}.zip"
  ELECTRON_EXTRACT="$DOWNLOAD_DIR/electron-linux-${ELECTRON_ARCH}"

  mkdir -p "$DOWNLOAD_DIR"

  if [[ -d "$ELECTRON_EXTRACT" && -f "$ELECTRON_EXTRACT/electron" ]]; then
    log "Electron already downloaded and extracted."
  else
    if [[ ! -f "$ELECTRON_ZIP" ]]; then
      log "Downloading Electron ${ELECTRON_VERSION} for Linux ${ELECTRON_ARCH}..."
      log "URL: $ELECTRON_URL"
      curl -L --retry 3 --retry-delay 2 -o "$ELECTRON_ZIP" "$ELECTRON_URL"
    fi

    log "Extracting Electron..."
    rm -rf "$ELECTRON_EXTRACT"
    mkdir -p "$ELECTRON_EXTRACT"
    # Use unzip (should be available)
    if command -v unzip &>/dev/null; then
      unzip -q "$ELECTRON_ZIP" -d "$ELECTRON_EXTRACT"
    else
      # Fallback to python
      python3 -c "
import zipfile, sys
with zipfile.ZipFile('$ELECTRON_ZIP', 'r') as z:
    z.extractall('$ELECTRON_EXTRACT')
"
    fi

    log "Electron extracted to: $ELECTRON_EXTRACT"
    ls -la "$ELECTRON_EXTRACT" | head -20
  fi
fi

#=============================================================================
# Phase 3: Assemble Linux app
#=============================================================================
log "${CYAN}== Phase 3: Assemble Linux app ==${NC}"

STAGE_DIR="$BUILD_DIR/CatPawAI-linux-${ARCH}"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# 3a. Copy Electron runtime files
log "[3a] Copying Electron runtime..."
cp -r "$ELECTRON_EXTRACT"/* "$STAGE_DIR/"

# Make electron binary executable
chmod +x "$STAGE_DIR/electron" 2>/dev/null || true

# Rename electron binary to CatPawAI
if [[ -f "$STAGE_DIR/electron" ]]; then
  mv "$STAGE_DIR/electron" "$STAGE_DIR/catpawai"
  chmod +x "$STAGE_DIR/catpawai"
fi

# 3b. Copy app resources
log "[3b] Copying app resources..."
mkdir -p "$STAGE_DIR/resources"
cp -r "$EXTRACTED_DIR/app" "$STAGE_DIR/resources/app"

# 3c. Read version from product.json
if [[ -f "$STAGE_DIR/resources/app/product.json" ]]; then
  APP_VERSION=$(python3 -c "import json; print(json.load(open('$STAGE_DIR/resources/app/product.json'))['version'])" 2>/dev/null || echo "$APP_VERSION")
  CATPAW_VERSION=$(python3 -c "import json; print(json.load(open('$STAGE_DIR/resources/app/product.json')).get('catpawVersion', ''))" 2>/dev/null || echo "$CATPAW_VERSION")
  log "   App version: $APP_VERSION"
  log "   CatPaw version: $CATPAW_VERSION"
fi

#=============================================================================
# Phase 4: Rebuild native modules for Linux
#=============================================================================
log "${CYAN}== Phase 4: Rebuild native modules for Linux ==${NC}"

APP_NODE_MODULES="$STAGE_DIR/resources/app/node_modules"

# List of native modules to rebuild
NATIVE_MODULES=(
  "kerberos"
  "@vscode/policy-watcher"
  "@vscode/spdlog"
  "@vscode/sqlite3"
  "node-pty"
  "native-watchdog"
  "native-keymap"
  "@parcel/watcher"
  "native-is-elevated"
)

# Modules to remove (platform-specific, not needed on Linux)
# NOTE: @vscode/deviceid is NOT removed — it's pure JS (uuid + fs-extra) and
# explicitly supports linux (dist/index.js checks process.platform). main.js
# imports it dynamically for getDeviceId(); removing it throws
# ERR_MODULE_NOT_FOUND at startup. The build/Release/windows.node file inside
# is Windows-only and never loaded on Linux.
REMOVE_MODULES=(
  "@vscode/windows-mutex"
  "@vscode/windows-process-tree"
  "@vscode/windows-registry"
  "windows-foreground-love"
)

# 4a. Remove platform-specific modules
log "[4a] Removing platform-specific modules..."
for mod in "${REMOVE_MODULES[@]}"; do
  mod_path="$APP_NODE_MODULES/$mod"
  if [[ -d "$mod_path" ]]; then
    rm -rf "$mod_path"
    log "   removed: $mod"
  fi
done

# 4b. Set up build environment for native modules
log "[4b] Building native modules..."

# Install @electron/rebuild globally
log "   Installing @electron/rebuild..."
npm install -g @electron/rebuild 2>/dev/null || npm install @electron/rebuild 2>/dev/null

# Create a temporary build project
BUILD_TMP="$BUILD_DIR/_native-build"
rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP"

# Generate minimal package.json for native module build
python3 - "$BUILD_TMP" "$STAGE_DIR/resources/app/package.json" << 'PYEOF'
import json, sys, os
build_tmp = sys.argv[1]
app_pkg_path = sys.argv[2]

with open(app_pkg_path, "r") as f:
    pkg = json.load(f)

native_deps = [
    "@parcel/watcher",
    "@vscode/policy-watcher",
    "@vscode/spdlog",
    "@vscode/sqlite3",
    "kerberos",
    "native-is-elevated",
    "native-keymap",
    "native-watchdog",
    "node-pty",
]

# Filter overrides to only include relevant ones for native modules
filtered_overrides = {}
for key, value in pkg.get("overrides", {}).items():
    if key in ["node-gyp-build"] or key.startswith("kerberos"):
        filtered_overrides[key] = value

minimal = {
    "name": "catpawai-native-build",
    "version": "1.0.0",
    "private": True,
    "dependencies": {},
    "overrides": filtered_overrides
}

for dep in native_deps:
    if dep in pkg.get("dependencies", {}):
        minimal["dependencies"][dep] = pkg["dependencies"][dep]

out_path = os.path.join(build_tmp, "package.json")
with open(out_path, "w") as f:
    json.dump(minimal, f, indent=2)
print(f"   Written: {out_path}")
print(f"   Dependencies: {json.dumps(minimal['dependencies'], indent=2)}")
PYEOF

# Install dependencies (this will compile native modules for the current platform)
log "   Installing native dependencies (this may take a while)..."
cd "$BUILD_TMP"
# Set Electron as the runtime for node-gyp
export npm_config_runtime=electron
export npm_config_target="${ELECTRON_VERSION}"
export npm_config_disturl=https://electronjs.org/headers
export npm_config_build_from_source=true

npm install --no-save --no-optional 2>&1 || {
  warn "npm install had issues, trying individual modules..."
  for mod in "${NATIVE_MODULES[@]}"; do
    log "   Installing $mod..."
    npm install "$mod@$(python3 -c "import json; print(json.load(open('$STAGE_DIR/resources/app/package.json')).get('dependencies',{}).get('$mod','latest'))")" --no-save 2>/dev/null || warn "Failed to install $mod"
  done
}

# 4c. Copy rebuilt native modules to app
log "[4c] Copying rebuilt native modules..."
for mod in "${NATIVE_MODULES[@]}"; do
  src="$BUILD_TMP/node_modules/$mod"
  dest="$APP_NODE_MODULES/$mod"

  if [[ -d "$src" ]]; then
    # Remove old macOS version
    rm -rf "$dest"
    # Copy Linux-compiled version
    cp -r "$src" "$dest"
    log "   ${GREEN}ok${NC}: $mod"
  else
    warn "   not built: $mod"
  fi
done

# 4d. Handle catapi.node (already has Linux build in extensions)
log "[4d] Handling @dp/cat-client..."
# @dp/cat-client is in the mt-idekit extension, not in app/node_modules
CATAPI_DIR=$(find "$STAGE_DIR/resources/app/extensions" -path "*/@dp/cat-client" -type d 2>/dev/null | head -1)
if [[ -n "$CATAPI_DIR" && -d "$CATAPI_DIR/build_linux" ]]; then
  log "   Found build_linux, switching to Linux native module..."
  mkdir -p "$CATAPI_DIR/build/Release"
  cp "$CATAPI_DIR/build_linux/Release/catapi.node" "$CATAPI_DIR/build/Release/catapi.node" 2>/dev/null || true
  log "   ${GREEN}ok${NC}: catapi.node (Linux)"
else
  # Also check app/node_modules
  CATAPI_DIR="$APP_NODE_MODULES/@dp/cat-client"
  if [[ -d "$CATAPI_DIR" && -d "$CATAPI_DIR/build_linux" ]]; then
    mkdir -p "$CATAPI_DIR/build/Release"
    cp "$CATAPI_DIR/build_linux/Release/catapi.node" "$CATAPI_DIR/build/Release/catapi.node" 2>/dev/null || true
    log "   ${GREEN}ok${NC}: catapi.node (Linux)"
  else
    warn "   No build_linux found for @dp/cat-client"
  fi
fi

# 4e. Handle node-pty spawn-helper (compile if missing)
log "[4e] Checking node-pty spawn-helper..."
PTY_DIR="$APP_NODE_MODULES/node-pty"
if [[ -d "$PTY_DIR" ]]; then
  SPAWN_HELPER=$(find "$PTY_DIR" -name "spawn-helper" -type f 2>/dev/null | head -1)
  if [[ -n "$SPAWN_HELPER" ]]; then
    chmod +x "$SPAWN_HELPER"
    log "   ${GREEN}ok${NC}: spawn-helper at $SPAWN_HELPER"
  else
    warn "   spawn-helper not found, trying to compile..."
    # Try to compile spawn-helper from source
    SPAWN_SRC="$PTY_DIR/src/unix/spawn-helper.cc"
    if [[ -f "$SPAWN_SRC" ]]; then
      mkdir -p "$PTY_DIR/build/Release"
      if g++ -o "$PTY_DIR/build/Release/spawn-helper" "$SPAWN_SRC" 2>/dev/null; then
        chmod +x "$PTY_DIR/build/Release/spawn-helper"
        log "   ${GREEN}ok${NC}: spawn-helper compiled"
      else
        warn "   Failed to compile spawn-helper (terminal may not work)"
      fi
    fi
  fi
fi

cd "$SCRIPT_DIR"

#=============================================================================
# Phase 5: Fix up app for Linux
#=============================================================================
log "${CYAN}== Phase 5: Fix up app for Linux ==${NC}"

# 5a. Update product.json platform
log "[5a] Updating product.json..."
PRODUCT_JSON="$STAGE_DIR/resources/app/product.json"
python3 - "$PRODUCT_JSON" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, "r") as f:
    product = json.load(f)

# Update platform
product["platform"] = "linux-x64"

with open(path, "w") as f:
    json.dump(product, f, indent="\t")
    f.write("\n")
print("   Updated platform to linux-x64")
PYEOF

# 5b. Remove macOS-specific files from app
log "[5b] Removing macOS-specific files..."
find "$STAGE_DIR/resources/app/node_modules" -name "*.dylib" -delete 2>/dev/null || true
find "$STAGE_DIR/resources/app/node_modules" -name "*.dll" -delete 2>/dev/null || true
find "$STAGE_DIR/resources/app/node_modules" -name "*.exe" -delete 2>/dev/null || true
# Remove macOS build directories
find "$STAGE_DIR/resources/app/node_modules" -type d -name "build_darwin" -exec rm -rf {} + 2>/dev/null || true
find "$STAGE_DIR/resources/app/node_modules" -type d -name "build_win32" -exec rm -rf {} + 2>/dev/null || true

# 5c. Create launcher script
log "[5c] Creating launcher script..."
mkdir -p "$STAGE_DIR/bin"
cat > "$STAGE_DIR/bin/catpawai" << 'LAUNCHER'
#!/usr/bin/env bash
#
# CatPawAI Linux launcher
#
# Resolves its own path through symlinks (/usr/bin/catpawai → here), detects
# the display session, and starts the Electron binary with the right flags.
# Pattern adapted from codex-desktop-linux/launcher/start.sh.template.
set -e

# ── Resolve real script dir (symlink-safe) ──────────────────────────────
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)"
  SELF="$(readlink "$SELF")"
  case "$SELF" in
    /*) ;;
    *)  SELF="$DIR/$SELF" ;;
  esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

# ── Environment ─────────────────────────────────────────────────────────
# ELECTRON_RUN_AS_NODE's mere presence (even =0) forces Node.js mode, where
# --no-sandbox is rejected. Always unset before exec.
unset ELECTRON_RUN_AS_NODE 2>/dev/null || true
export CHROME_DESKTOP="catpawai.desktop"

if [ ! -f "$APP_DIR/chrome-sandbox" ]; then
  export ELECTRON_DISABLE_SANDBOX=1
fi

# ── Build Electron args ─────────────────────────────────────────────────
APP_ID="catpawai"
ARGS=(
  --no-sandbox
  --class="$APP_ID"
  --app-id="$APP_ID"
  --disable-dev-shm-usage
  --disable-gpu-sandbox
  # KWallet (org.kde.kwalletd6.isEnabled) hangs on this root session, and
  # Chromium calls it synchronously on the main thread to pick a password
  # store — the call never returns and the UI freezes ~1s after launch.
  # 'basic' stores secrets in plaintext (encrypted via OS keyring is not
  # available here anyway). Use --password-store=gnome to force libsecret.
  --password-store=basic
)

# Display backend selection. On KDE kwin_wayland, Electron's default (XWayland)
# produces windows that render but ignore pointer input. Forcing native Wayland
# fixes the input bug. Allow override via --x11 / --wayland / --ozone-platform=*.
OZONE_PLATFORM=""
OZONE_HINT="auto"
EXTRA_FEATURES=""

for arg in "$@"; do
  case "$arg" in
    --x11)                 OZONE_PLATFORM="x11";   OZONE_HINT="" ;;
    --wayland)             OZONE_PLATFORM="wayland"; OZONE_HINT="" ;;
    --ozone-platform=*)    OZONE_PLATFORM="${arg#--ozone-platform=}"; OZONE_HINT="" ;;
    --ozone-platform-hint=*) OZONE_HINT="${arg#--ozone-platform-hint=}" ;;
  esac
done

# Auto-detect Wayland when no explicit platform was requested.
if [ -z "$OZONE_PLATFORM" ] && [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  OZONE_PLATFORM="wayland"
  OZONE_HINT=""
fi

if [ -n "$OZONE_PLATFORM" ]; then
  ARGS+=(--ozone-platform="$OZONE_PLATFORM")
elif [ -n "$OZONE_HINT" ]; then
  ARGS+=(--ozone-platform-hint="$OZONE_HINT")
fi

# On Wayland, enable native window decorations.
# NOTE: do NOT add --disable-gpu-compositing here — on KDE kwin_wayland it
# freezes the renderer after ~1s (window paints once then stops responding to
# input). The codex-desktop reference adds it for side-panel stability, but
# CatPawAI's renderer hangs with it. Leave GPU compositing on.
if [ "$OZONE_PLATFORM" = "wayland" ]; then
  EXTRA_FEATURES="WaylandWindowDecorations"
fi

if [ -n "$EXTRA_FEATURES" ]; then
  ARGS+=(--enable-features="$EXTRA_FEATURES")
fi

# ── Launch ──────────────────────────────────────────────────────────────
exec "$APP_DIR/catpawai" "${ARGS[@]}" "$@"
LAUNCHER
chmod +x "$STAGE_DIR/bin/catpawai"

# Also create a top-level wrapper
cat > "$STAGE_DIR/catpawai-launcher" << 'WRAPPER'
#!/usr/bin/env bash
exec "$(dirname "$0")/catpawai" --no-sandbox "$@"
WRAPPER
chmod +x "$STAGE_DIR/catpawai-launcher"

# 5d. Create desktop entry
log "[5d] Creating desktop entry..."
mkdir -p "$STAGE_DIR/share/applications"
cat > "$STAGE_DIR/share/applications/catpawai.desktop" << 'DESKTOP'
[Desktop Entry]
Name=CatPawAI
Comment=AI-powered IDE by Meituan
GenericName=Text Editor
Exec=catpawai --no-sandbox %F
Icon=catpawai
Type=Application
StartupNotify=false
StartupWMClass=CatPawAI
Categories=TextEditor;Development;IDE;
MimeType=text/plain;application/x-code-workspace;
Keywords=catpaw;ide;code;editor;development;programming;
DESKTOP

# 5e. Create icon (convert from PNG resources or use a placeholder)
log "[5e] Setting up icon..."
ICON_DIR="$STAGE_DIR/share/icons/hicolor/512x512/apps"
mkdir -p "$ICON_DIR"

# Try to find a PNG icon in the app resources
ICON_FOUND=false
for icon_path in \
  "$STAGE_DIR/resources/app/extensions/mt-idekit.mt-idekit-code/media/icon.png" \
  "$STAGE_DIR/resources/app/extensions/mt-idekit.mt-idekit-code/out/media/icon.png" \
  "$STAGE_DIR/resources/app/resources/app/icons/icon_512.png" \
  "$SCRIPT_DIR/resources/catpawai.png"; do
  if [[ -f "$icon_path" ]]; then
    cp "$icon_path" "$ICON_DIR/catpawai.png"
    ICON_FOUND=true
    log "   Icon: $icon_path"
    break
  fi
done

if ! $ICON_FOUND; then
  # Generate a simple icon from the icns if possible, or use a placeholder
  warn "   No PNG icon found, creating placeholder..."
  python3 << 'PYEOF'
import struct, zlib

def create_png(width, height, color):
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    
    # Simple solid color PNG
    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    
    raw = b''
    for y in range(height):
        raw += b'\x00'  # filter byte
        raw += bytes(color) * width
    
    idat = chunk(b'IDAT', zlib.compress(raw))
    iend = chunk(b'IEND', b'')
    
    return header + ihdr + idat + iend

with open("/dev/shm/catpawai_icon.png", "wb") as f:
    f.write(create_png(512, 512, [0x2D, 0x8C, 0xE0]))  # Blue
PYEOF
  cp /dev/shm/catpawai_icon.png "$ICON_DIR/catpawai.png" 2>/dev/null || true
fi

# Also copy icon to resources for app use
cp "$ICON_DIR/catpawai.png" "$STAGE_DIR/resources/catpawai.png" 2>/dev/null || true

# 5f. Set permissions
log "[5f] Setting permissions..."
find "$STAGE_DIR" -name "*.so" -exec chmod 755 {} \; 2>/dev/null || true
find "$STAGE_DIR" -name "*.node" -exec chmod 644 {} \; 2>/dev/null || true
chmod +x "$STAGE_DIR/catpawai" 2>/dev/null || true
chmod +x "$STAGE_DIR/chrome-sandbox" 2>/dev/null || true
chmod +x "$STAGE_DIR/chrome_crashpad_handler" 2>/dev/null || true
find "$STAGE_DIR/resources/app/bin" -type f -exec chmod +x {} \; 2>/dev/null || true

# 5g. Remove unnecessary files
log "[5g] Cleaning up unnecessary files..."
rm -f "$STAGE_DIR/resources/default_app.asar" 2>/dev/null || true
# Remove .DS_Store and other macOS artifacts
find "$STAGE_DIR" -name ".DS_Store" -delete 2>/dev/null || true
find "$STAGE_DIR" -name "._*" -delete 2>/dev/null || true

#=============================================================================
# Phase 6: Package
#=============================================================================
log "${CYAN}== Phase 6: Package ==${NC}"

mkdir -p "$OUT_DIR"

# 6a. Create tar.gz
PKG_NAME="CatPawAI-linux-${ARCH}-${CATPAW_VERSION}"
TAR_PATH="$OUT_DIR/${PKG_NAME}.tar.gz"

log "[6a] Creating ${PKG_NAME}.tar.gz..."
cd "$BUILD_DIR"
tar czf "$TAR_PATH" "CatPawAI-linux-${ARCH}"
cd "$SCRIPT_DIR"

TAR_SIZE=$(du -h "$TAR_PATH" | cut -f1)
log "   ${GREEN}Created${NC}: $TAR_PATH ($TAR_SIZE)"

# 6b. Try to create .deb package
log "[6b] Creating .deb package..."
DEB_DIR="$BUILD_DIR/_deb"
DEB_APP_DIR="$DEB_DIR/usr/share/catpawai"
DEB_SIZE=$(du -sk "$STAGE_DIR" | cut -f1)

rm -rf "$DEB_DIR"
mkdir -p "$DEB_APP_DIR" \
  "$DEB_DIR/usr/bin" \
  "$DEB_DIR/usr/share/applications" \
  "$DEB_DIR/usr/share/icons/hicolor/512x512/apps" \
  "$DEB_DIR/DEBIAN"

# Copy app files
cp -r "$STAGE_DIR"/* "$DEB_APP_DIR/"

# Create symlink in /usr/bin
ln -sf /usr/share/catpawai/bin/catpawai "$DEB_DIR/usr/bin/catpawai"

# Copy desktop entry
cp "$STAGE_DIR/share/applications/catpawai.desktop" "$DEB_DIR/usr/share/applications/" 2>/dev/null || true

# Copy icon
cp "$ICON_DIR/catpawai.png" "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/" 2>/dev/null || true

# Create control file
cat > "$DEB_DIR/DEBIAN/control" << CONTROL
Package: catpawai
Version: ${CATPAW_VERSION}
Section: devel
Priority: optional
Architecture: ${ARCH}
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libdrm2, libgbm1, libxcb-dri3-0
Installed-Size: ${DEB_SIZE}
Maintainer: CatPaw Team
Description: CatPawAI - AI-powered IDE by Meituan
 CatPawAI is an AI-powered IDE based on VS Code,
 developed by Meituan.
Homepage: https://catpaw.meituan.com
CONTROL

# Create postinst script
cat > "$DEB_DIR/DEBIAN/postinst" << 'POSTINST'
#!/bin/bash
set -e
# Update icon cache
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
fi
# Update desktop database
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
fi
chmod 755 /usr/share/catpawai/catpawai 2>/dev/null || true
chmod 755 /usr/share/catpawai/chrome-sandbox 2>/dev/null || true
chmod 4755 /usr/share/catpawai/chrome-sandbox 2>/dev/null || true
exit 0
POSTINST
chmod 755 "$DEB_DIR/DEBIAN/postinst"

# Build deb
DEB_PATH="$OUT_DIR/${PKG_NAME}.deb"
if command -v dpkg-deb &>/dev/null; then
  dpkg-deb --build "$DEB_DIR" "$DEB_PATH" 2>/dev/null
  if [[ -f "$DEB_PATH" ]]; then
    DEB_SIZE=$(du -h "$DEB_PATH" | cut -f1)
    log "   ${GREEN}Created${NC}: $DEB_PATH ($DEB_SIZE)"
  else
    warn "   Failed to create .deb package"
  fi
else
  warn "   dpkg-deb not available, skipping .deb"
fi

# Cleanup
rm -rf "$DEB_DIR"

#=============================================================================
# Phase 6c: Create pacman package (Arch Linux)
#=============================================================================
log "${CYAN}== Phase 6c: Create pacman (.pkg.tar.zst) package ==${NC}"

IS_ARCH=false
if [[ -f /etc/arch-release ]] || grep -qiE '^(ID|ID_LIKE)=.*arch' /etc/os-release 2>/dev/null; then
  IS_ARCH=true
fi

if $IS_ARCH && command -v bsdtar >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
  if bash "$SCRIPT_DIR/make-arch-pkg.sh" "$STAGE_DIR" "$OUT_DIR"; then
    log "   pacman package created"
  else
    warn "   pacman package creation failed"
  fi
else
  warn "   Not on Arch or bsdtar/zstd missing — skipping pacman package"
  warn "   (this is normal on Debian/Ubuntu/WSL2; the tar.gz/.deb are still produced)"
fi

#=============================================================================
# Phase 7: Summary
#=============================================================================
log "${CYAN}== Build Complete! ==${NC}"
echo ""
echo "Output files:"
ls -lh "$OUT_DIR"/*.tar.gz "$OUT_DIR"/*.deb "$OUT_DIR"/*.pkg.tar.zst 2>/dev/null
echo ""
echo "App info:"
echo "  Name:    CatPawAI"
echo "  Version: $CATPAW_VERSION (VS Code $APP_VERSION)"
echo "  Arch:    Linux $ARCH"
echo "  Electron: $ELECTRON_VERSION"
echo ""
echo "To install (tar.gz):"
echo "  tar xzf $(basename "$TAR_PATH") -C /opt/"
echo "  sudo ln -sf /opt/CatPawAI-linux-$ARCH/bin/catpawai /usr/local/bin/catpawai"
echo ""
echo "To install (.deb):"
echo "  sudo dpkg -i $(basename "$DEB_PATH")"
echo ""
echo "To run:"
echo "  ./CatPawAI-linux-$ARCH/catpawai --no-sandbox"
