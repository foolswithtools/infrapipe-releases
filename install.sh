#!/bin/bash
# Verified installer for infrapipe — the ONLY install script.
# Detects OS/arch, downloads the matching artifact from GitHub Releases,
# verifies its SHA256 checksum, and installs it. Nothing is installed
# unless verification succeeds.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/foolswithtools/infrapipe-releases/main/install.sh | bash
#   ... | bash -s -- --version v1.2.3
#   ... | bash -s -- --install-dir "$HOME/.local/bin"
#
# Test overrides:
#   INFRAPIPE_BASE_URL   release base URL (default: the project's GitHub Releases)
#   INFRAPIPE_PLATFORM   force "os-arch" instead of auto-detection
set -euo pipefail

VERSION="latest"
INSTALL_DIR="/usr/local/bin"
BASE_URL="${INFRAPIPE_BASE_URL:-https://github.com/foolswithtools/infrapipe-releases/releases}"
SUPPORTED="linux-amd64 linux-arm64 darwin-amd64 darwin-arm64"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Platform detection (overridable for tests)
if [ -n "${INFRAPIPE_PLATFORM:-}" ]; then
    PLATFORM="$INFRAPIPE_PLATFORM"
else
    OS="$(uname -s)"
    case "$OS" in
        Linux)  OS="linux" ;;
        Darwin) OS="darwin" ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "ERROR: this script targets Unix-like systems." >&2
            echo "Windows: download infrapipe-windows-amd64.exe and its .sha256 from" >&2
            echo "  ${BASE_URL}/latest" >&2
            echo "and verify with: Get-FileHash infrapipe-windows-amd64.exe -Algorithm SHA256" >&2
            exit 1 ;;
        *) OS="$(echo "$OS" | tr '[:upper:]' '[:lower:]')" ;;
    esac
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
    esac
    PLATFORM="${OS}-${ARCH}"
fi

case " $SUPPORTED " in
    *" $PLATFORM "*) : ;;
    *)
        echo "ERROR: unsupported platform: $PLATFORM" >&2
        echo "Supported platforms: $SUPPORTED" >&2
        echo "Other platforms (e.g. windows-amd64): download manually from ${BASE_URL}/latest" >&2
        exit 1 ;;
esac

ASSET="infrapipe-${PLATFORM}"
if [ "$VERSION" = "latest" ]; then
    DOWNLOAD_BASE="${BASE_URL}/latest/download"
else
    DOWNLOAD_BASE="${BASE_URL}/download/${VERSION}"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading infrapipe (${VERSION}, ${PLATFORM})..."
curl -fsSL "${DOWNLOAD_BASE}/${ASSET}" -o "$TMPDIR/$ASSET"
curl -fsSL "${DOWNLOAD_BASE}/${ASSET}.sha256" -o "$TMPDIR/$ASSET.sha256"

echo "Verifying SHA256 checksum..."
cd "$TMPDIR"
if command -v sha256sum >/dev/null 2>&1; then
    CHECK="sha256sum -c"
else
    CHECK="shasum -a 256 -c"   # macOS
fi
if ! $CHECK "$ASSET.sha256"; then
    echo "" >&2
    echo "ERROR: checksum verification FAILED — the download does not match" >&2
    echo "its published checksum. Nothing was installed." >&2
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
    echo "ERROR: install directory not writable: $INSTALL_DIR" >&2
    echo "Re-run with --install-dir <writable-dir> (e.g. \$HOME/.local/bin)," >&2
    echo "or with appropriate permissions." >&2
    exit 1
fi

OLD_VERSION=""
if command -v "$INSTALL_DIR/infrapipe" >/dev/null 2>&1; then
    OLD_VERSION="$("$INSTALL_DIR/infrapipe" version 2>/dev/null || true)"
fi

install -m 0755 "$ASSET" "$INSTALL_DIR/infrapipe"
NEW_VERSION="$("$INSTALL_DIR/infrapipe" version 2>/dev/null || echo "infrapipe (version unavailable)")"

echo "Checksum verified. Installed to $INSTALL_DIR/infrapipe"
[ -n "$OLD_VERSION" ] && echo "Replaced: $OLD_VERSION"
echo "Installed: $NEW_VERSION"
