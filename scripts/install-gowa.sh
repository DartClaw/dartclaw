#!/usr/bin/env bash
# Install GOWA (go-whatsapp-web-multidevice) for DartClaw.
# Downloads the correct pre-built binary for your platform and adds it to PATH.
#
# Usage:
#   bash scripts/install-gowa.sh            # latest release
#   bash scripts/install-gowa.sh v8.3.2     # specific version
#
# Supports: macOS (Intel + Apple Silicon), Linux (x86_64 + ARM64)

set -euo pipefail

REPO="aldinokemal/go-whatsapp-web-multidevice"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="whatsapp"

# --- Resolve version ----------------------------------------------------------

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Fetching latest release..."
  VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
fi

if [ -z "$VERSION" ]; then
  echo "Error: could not determine version." >&2
  exit 1
fi

VERSION_NUM="${VERSION#v}"
echo "Installing GOWA ${VERSION}..."

# --- Detect platform ----------------------------------------------------------

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) PLATFORM="darwin" ;;
  Linux)  PLATFORM="linux" ;;
  *)      echo "Error: unsupported OS: $OS" >&2; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64)  ARCH_SUFFIX="amd64" ;;
  arm64|aarch64) ARCH_SUFFIX="arm64" ;;
  i386|i686)     ARCH_SUFFIX="386" ;;
  *)             echo "Error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

FILENAME="whatsapp_${VERSION_NUM}_${PLATFORM}_${ARCH_SUFFIX}.zip"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${FILENAME}"

echo "Platform: ${PLATFORM}/${ARCH_SUFFIX}"

# --- Download and install -----------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading ${URL}..."
curl -fsSL "$URL" -o "${TMPDIR}/${FILENAME}"

echo "Extracting..."
unzip -qo "${TMPDIR}/${FILENAME}" -d "${TMPDIR}/extracted"

# Binary inside the zip is named <platform>-<arch> (e.g. darwin-arm64)
SRC="${TMPDIR}/extracted/${PLATFORM}-${ARCH_SUFFIX}"
if [ ! -f "$SRC" ]; then
  echo "Error: binary not found in archive. Contents:" >&2
  ls -la "${TMPDIR}/extracted/"
  exit 1
fi

mkdir -p "$INSTALL_DIR"
mv "$SRC" "${INSTALL_DIR}/${BINARY_NAME}"
chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

# --- Add to PATH if needed ----------------------------------------------------

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    *)    RC_FILE="$HOME/.profile" ;;
  esac

  LINE="export PATH=\"${INSTALL_DIR}:\$PATH\""

  if [ -f "$RC_FILE" ] && grep -qF "$INSTALL_DIR" "$RC_FILE"; then
    echo "PATH entry already in ${RC_FILE}"
  else
    echo "" >> "$RC_FILE"
    echo "# Added by install-gowa.sh" >> "$RC_FILE"
    echo "$LINE" >> "$RC_FILE"
    echo "Added ${INSTALL_DIR} to PATH in ${RC_FILE}"
    echo "Run 'source ${RC_FILE}' or open a new terminal for it to take effect."
  fi
fi

# --- Verify -------------------------------------------------------------------

echo ""
if [ -x "${INSTALL_DIR}/${BINARY_NAME}" ]; then
  echo "GOWA ${VERSION} installed successfully."
  ls -lh "${INSTALL_DIR}/${BINARY_NAME}"
else
  echo "Error: installation failed — binary not executable." >&2
  exit 1
fi
echo ""
echo "Configure gowa_executable in dartclaw.yaml:"
echo "  gowa_executable: ${INSTALL_DIR}/${BINARY_NAME}"
