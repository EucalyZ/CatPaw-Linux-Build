#!/usr/bin/env bash
# Repackage a CatPawAI Linux build into an Arch pacman package (.pkg.tar.zst).
#
# Why this exists:
#   `yay -U` / `pacman -U` require a pacman package containing .PKGINFO
#   metadata. The build's tar.gz is just a portable Electron archive and
#   will be rejected with "缺少软件包元数据" / "invalid or corrupted package".
#   This script lays the app out into /usr/share/catpawai and produces a
#   proper pacman package that pacman/yay can install and track.
#
# Usage:
#   make-arch-pkg.sh <stage_dir|tar.gz> [out_dir]
#
# Output:
#   <out_dir>/catpawai-<version>-1-<arch>.pkg.tar.zst

set -euo pipefail

INPUT="${1:?usage: $0 <stage_dir|tar.gz> [out_dir]}"
OUT_DIR="${2:-.}"
# Resolve to absolute path — the script cd's into a temp dir later, so a
# relative OUT_DIR would break zstd -o "$PKG_PATH".
OUT_DIR="$(cd "$OUT_DIR" 2>/dev/null && pwd)" || {
  err "output dir does not exist: $OUT_DIR"
  exit 1
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} WARN: $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)]${NC} ERROR: $*" >&2; }

for cmd in bsdtar zstd; do
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd not found (install libarchive and zstd)"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE"

# Resolve input: either an existing build stage dir, or a tar.gz to extract.
if [[ -d "$INPUT" ]]; then
  cp -a "$INPUT/." "$STAGE/"
elif [[ -f "$INPUT" ]]; then
  log "Extracting $(basename "$INPUT")..."
  tar xzf "$INPUT" -C "$WORK"
  TOP_DIR=$(ls -d "$WORK"/CatPawAI-linux-* 2>/dev/null | head -1)
  [[ -d "$TOP_DIR" ]] || { err "Could not find CatPawAI-linux-* inside archive"; exit 1; }
  cp -a "$TOP_DIR/." "$STAGE/"
else
  err "Input not found: $INPUT"
  exit 1
fi

# Read version info from product.json
PRODUCT_JSON="$STAGE/resources/app/product.json"
CATPAW_VERSION="2026.2.3"
APP_VERSION="1.101.0"
ELECTRON_VERSION="35.5.1"
if [[ -f "$PRODUCT_JSON" ]]; then
  APP_VERSION=$(python3 -c "import json;print(json.load(open('$PRODUCT_JSON'))['version'])" 2>/dev/null || echo "$APP_VERSION")
  CATPAW_VERSION=$(python3 -c "import json;print(json.load(open('$PRODUCT_JSON')).get('catpawVersion',''))" 2>/dev/null || echo "$CATPAW_VERSION")
fi
[[ -z "$CATPAW_VERSION" ]] && CATPAW_VERSION="2026.2.3"

# Detect target arch from the main binary
PACMAN_ARCH="x86_64"
if file "$STAGE/catpawai" 2>/dev/null | grep -qi 'aarch64\|ARM aarch64'; then
  PACMAN_ARCH="aarch64"
elif file "$STAGE/catpawai" 2>/dev/null | grep -qi 'x86-64'; then
  PACMAN_ARCH="x86_64"
fi

# Build the package filesystem layout.
# /usr/share/catpawai  ← entire app
# /usr/bin/catpawai    ← symlink to launcher
# /usr/share/applications/catpawai.desktop
# /usr/share/icons/hicolor/512x512/apps/catpawai.png
PKG_DIR="$WORK/pkg"
PKG_APP_DIR="$PKG_DIR/usr/share/catpawai"
mkdir -p "$PKG_APP_DIR" \
  "$PKG_DIR/usr/bin" \
  "$PKG_DIR/usr/share/applications" \
  "$PKG_DIR/usr/share/icons/hicolor/512x512/apps"

cp -a "$STAGE/." "$PKG_APP_DIR/"
ln -sf /usr/share/catpawai/bin/catpawai "$PKG_DIR/usr/bin/catpawai"

[[ -f "$STAGE/share/applications/catpawai.desktop" ]] && \
  cp "$STAGE/share/applications/catpawai.desktop" "$PKG_DIR/usr/share/applications/"

ICON_SRC=""
for c in \
  "$STAGE/share/icons/hicolor/512x512/apps/catpawai.png" \
  "$STAGE/resources/catpawai.png" \
  "$STAGE/resources/app/extensions/mt-idekit.mt-idekit-code/media/icon.png"; do
  if [[ -f "$c" ]]; then ICON_SRC="$c"; break; fi
done
[[ -n "$ICON_SRC" ]] && cp "$ICON_SRC" "$PKG_DIR/usr/share/icons/hicolor/512x512/apps/catpawai.png"

# Normalize ownership to root:root (pacman packages must not carry user ids).
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R 0:0 "$PKG_DIR"
fi

# chrome-sandbox needs setuid on Linux; record the mode in the package.
# NOTE: must run AFTER chown — Linux's chown() clears suid/sgid even as root.
[[ -f "$PKG_APP_DIR/chrome-sandbox" ]] && chmod 4755 "$PKG_APP_DIR/chrome-sandbox"

INSTALLED_BYTES=$(du -sb "$PKG_APP_DIR" | cut -f1)

# .PKGINFO — the only strictly required metadata file.
cat > "$PKG_DIR/.PKGINFO" <<EOF
pkgname = catpawai
pkgver = ${CATPAW_VERSION}-1
pkgdesc = CatPawAI - AI-powered IDE by Meituan (VS Code ${APP_VERSION}, Electron ${ELECTRON_VERSION})
url = https://catpaw.meituan.com
builddate = $(date +%s)
packager = CatPaw Build Script <build@catpaw.local>
size = ${INSTALLED_BYTES}
arch = ${PACMAN_ARCH}
license = custom:proprietary
depend = gtk3
depend = nss
depend = alsa-lib
depend = libxss
depend = libxtst
depend = libnotify
depend = libsecret
depend = at-spi2-core
depend = libdrm
depend = mesa
EOF

# .MTREE — gzipped file manifest (matches makepkg output). Optional but
# expected by tooling like pacman -F.
log "Generating .MTREE..."
# .MTREE is optional (used by pacman -F file search). Failures here are non-fatal.
( cd "$PKG_DIR" && \
  bsdtar --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256' \
    --exclude=.MTREE --exclude=.PKGINFO \
    -cf - . 2>/dev/null | gzip -n > .MTREE ) || warn "   .MTREE generation failed (non-fatal)"

PKG_PATH="$OUT_DIR/catpawai-${CATPAW_VERSION}-1-${PACMAN_ARCH}.pkg.tar.zst"
mkdir -p "$OUT_DIR"
# Remove any stale package — zstd refuses to overwrite an existing file when
# reading from stdin ("already exists; stdin is an input - not proceeding").
rm -f "$PKG_PATH"
log "Creating $(basename "$PKG_PATH")..."

# Create uncompressed .pkg.tar first, then zstd-compress. Older libarchive
# (Ubuntu 22.04 ships 3.4.2) doesn't support `bsdtar --zstd`, so pipe through
# the zstd binary instead — works everywhere zstd is installed.
( cd "$PKG_DIR" && \
  bsdtar --format=pax -cf - .PKGINFO .MTREE usr 2>"$WORK/bsdtar.err" | \
  zstd -19 -T0 -o "$PKG_PATH" ) || {
    err "bsdtar/zstd failed:"
    cat "$WORK/bsdtar.err" >&2
    exit 1
  }

if [[ ! -f "$PKG_PATH" ]]; then
  err "Failed to create pacman package"
  exit 1
fi

SIZE=$(du -h "$PKG_PATH" | cut -f1)
log "   ${GREEN}Created${NC}: $PKG_PATH ($SIZE)"

# Validate metadata the same way pacman will parse it.
if command -v pacman >/dev/null 2>&1; then
  log "Validating with pacman -Qp..."
  pacman -Qp "$PKG_PATH" 2>&1 | head -20 || warn "   pacman -Qp reported issues"
fi
