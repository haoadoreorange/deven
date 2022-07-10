#!/bin/bash
set -euo pipefail

INSTALL_DIR="${1:-"$HOME"/.deven}"
CURRENT_DIR="$(dirname "$(realpath "$BASH_SOURCE")")"

if [ ! -d "$INSTALL_DIR" ]; then
    echo "Install deven to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cp -R "$CURRENT_DIR"/. "$INSTALL_DIR"/
fi

chmod +x "$INSTALL_DIR"/deven.sh
mkdir -p "$HOME"/.local/bin
ln -s "$INSTALL_DIR"/deven.sh "$HOME"/.local/bin/deven
echo "deven installed successfully, you might need to add ~/.local/bin/ to PATH to use it"
