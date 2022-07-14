#!/bin/bash
set -euo pipefail

INSTALL_DIR="${1:-"$HOME"/.deven}"

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    git clone https://github.com/haoadoreorange/deven "$INSTALL_DIR"
    echo "Download deven to $INSTALL_DIR successfully"
fi

chmod +x "$INSTALL_DIR"/deven.sh
mkdir -p "$HOME"/.local/bin
ln -s "$INSTALL_DIR"/deven.sh "$HOME"/.local/bin/deven
echo "Softlink deven binary to $HOME/.local/bin successfully"
echo "deven installed successfully, you might need to add ~/.local/bin/ to PATH to use it"
