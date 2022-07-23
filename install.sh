#!/bin/sh
set -eu

GREEN='\033[0;32m'
NC='\033[0m' # No Color
INSTALL_DIR="$(realpath "${1:-$HOME/.deven}")"

if [ ! -d "$INSTALL_DIR" ]; then
    printf "${GREEN}Downloading deven to %s${NC}\n" "$INSTALL_DIR"
    git clone https://github.com/haoadoreorange/deven "$INSTALL_DIR"
else
    printf "${GREEN}deven already downloaded at %s, pulling newest commit${NC}\n" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git pull
fi

printf "${GREEN}Softlinking deven binary to %s${NC}\n" "$HOME"/.local/bin
chmod +x "$INSTALL_DIR"/deven.sh
mkdir -p "$HOME"/.local/bin
ln -s "$INSTALL_DIR"/deven.sh "$HOME"/.local/bin/deven
printf "${GREEN}deven installed successfully, you might need to add ~/.local/bin/ to PATH to use it${NC}\n"
