#!/bin/sh
set -eu

GREEN='\033[0;32m'
RED='\033[0;31m'
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

local_bin="$HOME"/.local/bin
mkdir -p "$local_bin"
if [ ! -f "$local_bin"/deven ]; then
    printf "${GREEN}Softlinking deven to %s${NC}\n" "$local_bin"
    chmod +x "$INSTALL_DIR"/deven.sh
    ln -s "$INSTALL_DIR"/deven.sh "$local_bin"/deven
else
    printf "${RED}ERROR: deven already exists in %s${NC}\n" "$local_bin"
    failed=true
fi

[ "${failed-}" != "true" ] && printf "${GREEN}deven installed successfully, you might need to add ~/.local/bin/ to PATH to use it${NC}\n"
