#!/usr/bin/env bash
# Downloads the Apple Silicon rclone binary into app/Driveflow/Resources/ (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/app/Driveflow/Resources"
VERSION_FILE="$DEST_DIR/rclone.version"
VERSION="${RCLONE_VERSION:-$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null || echo "1.71.0")}"
ARCH="${RCLONE_ARCH:-osx-arm64}"
ZIP_NAME="rclone-v${VERSION}-${ARCH}.zip"
URL="https://downloads.rclone.org/v${VERSION}/${ZIP_NAME}"
SUMS_URL="https://downloads.rclone.org/v${VERSION}/SHA256SUMS"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST_DIR"
echo "==> Fetching rclone v${VERSION} (${ARCH})…"
curl -fsSL "$URL" -o "$TMP/$ZIP_NAME"
curl -fsSL "$SUMS_URL" -o "$TMP/SHA256SUMS"

EXPECTED="$(awk -v f="$ZIP_NAME" '$2 == f || $2 == ("*" f) { print $1; exit }' "$TMP/SHA256SUMS")"
if [[ -z "$EXPECTED" ]]; then
  echo "error: $ZIP_NAME not listed in $SUMS_URL" >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$TMP/$ZIP_NAME" | awk '{ print $1 }')"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "error: SHA256 mismatch for $ZIP_NAME" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "==> SHA256 verified ($ACTUAL)"

unzip -q "$TMP/$ZIP_NAME" -d "$TMP"
BIN="$(find "$TMP" -type f -name rclone | head -n1)"
test -n "$BIN"
install -m 755 "$BIN" "$DEST_DIR/rclone"
echo "$VERSION" >"$VERSION_FILE"
echo "Installed: $DEST_DIR/rclone (v$VERSION)"
"$DEST_DIR/rclone" version | head -n3
