#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m' # No Color
INSTALL_DIR="${1:-"$HOME"/.deven}"

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    git clone https://github.com/haoadoreorange/deven "$INSTALL_DIR"
    echo -e "${GREEN}Download deven to $INSTALL_DIR successfully${NC}"
else
    (
        cd "$INSTALL_DIR"
        git pull
    )
fi

chmod +x "$INSTALL_DIR"/deven.sh
mkdir -p "$HOME"/.local/bin
ln -s "$INSTALL_DIR"/deven.sh "$HOME"/.local/bin/deven
echo -e "${GREEN}Softlink deven binary to $HOME/.local/bin successfully${NC}"
echo -e "${GREEN}deven installed successfully, you might need to add ~/.local/bin/ to PATH to use it${NC}"
