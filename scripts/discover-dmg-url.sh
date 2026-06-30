#!/usr/bin/env bash
# Discover the latest CatPawAI DMG download URL from Meituan's public download page.
#
# Why this exists:
#   CatPawAI's update API (https://catpaw.meituan.com/api/update/...) requires SSO
#   authentication, so it can't be used in CI. The download page at
#   catpaw.meituan.com/download embeds the DMG URLs as string literals inside a
#   Vue component bundled in a JS chunk (assets/vue-vendor-{hash}.js). The hash
#   changes on each deploy, so we dynamically: fetch HTML → extract JS chunk URLs
#   → fetch each chunk → grep for the DMG URL pattern.
#
# Usage:
#   discover-dmg-url.sh [--arch x64|arm64]
#
# Output (to stdout):
#   URL=https://s3plus.meituan.net/.../CatPawAI-x64.20260417113254.dmg
#   VERSION=2026.2.3
#
# Exit codes:
#   0  found
#   1  not found / error

set -euo pipefail

ARCH="x64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

DOWNLOAD_PAGE="https://catpaw.meituan.com/download"

# Map arch to the darwin platform suffix used in the URL path.
# x64 → darwin-x64, arm64 → darwin-arm64
case "$ARCH" in
  x64)   DARWIN_ARCH="darwin-x64" ;;
  arm64) DARWIN_ARCH="darwin-arm64" ;;
  *) echo "ERROR: unsupported arch '$ARCH' (use x64 or arm64)" >&2; exit 1 ;;
esac

HTML=$(curl -sSL "$DOWNLOAD_PAGE" 2>/dev/null) || {
  echo "ERROR: failed to fetch $DOWNLOAD_PAGE" >&2
  exit 1
}

# Extract JS chunk URLs from <script src="..."> and <link href="..."> tags.
# URLs are protocol-relative (//s3.meituan.net/...) — prepend https:
JS_URLS=$(echo "$HTML" | grep -oE '(src|href)="[^"]*assets/[a-z0-9-]+\.js"' \
  | sed -E 's/.*="//;s/"$//' \
  | sed 's|^//|https://|' \
  | sort -u)

if [[ -z "$JS_URLS" ]]; then
  echo "ERROR: no JS chunk URLs found in download page" >&2
  exit 1
fi

# DMG URL pattern: the version and timestamp are variable, the rest is fixed.
# e.g. https://s3plus.meituan.net/catpaw-external-resources/ide/darwin-x64/stable/2026.2.3/CatPawAI-x64.20260417113254.dmg
DMG_PATTERN="https://s3plus\.meituan\.net/catpaw-external-resources/ide/${DARWIN_ARCH}/stable/[0-9]+\.[0-9]+\.[0-9]+/CatPawAI-${ARCH}\.[0-9]+\.dmg"

DMG_URL=""
for js_url in $JS_URLS; do
  # Fetch JS chunk, grep for DMG URL
  CONTENT=$(curl -sSL "$js_url" 2>/dev/null) || continue
  DMG_URL=$(echo "$CONTENT" | grep -oE "$DMG_PATTERN" | head -1) || true
  if [[ -n "$DMG_URL" ]]; then
    break
  fi
done

if [[ -z "$DMG_URL" ]]; then
  echo "ERROR: no DMG URL found for ${DARWIN_ARCH} in any JS chunk" >&2
  exit 1
fi

# Extract version from URL path: .../stable/{VERSION}/CatPawAI-...
VERSION=$(echo "$DMG_URL" | grep -oE 'stable/[0-9]+\.[0-9]+\.[0-9]+' | cut -d/ -f2)

echo "URL=$DMG_URL"
echo "VERSION=$VERSION"
