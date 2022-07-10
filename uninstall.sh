#!/bin/bash
set -euo pipefail

BIN_PATH="$HOME/.local/bin/deven"
if [ ! -f "$BIN_PATH" ]; then
    echo "deven is not installed"
    exit 1
fi
INSTALL_DIR="$(dirname "$(realpath "$BIN_PATH")")"
rm "$BIN_PATH"
rm -rf "$INSTALL_DIR"
echo "deven uninstalled successfully"
