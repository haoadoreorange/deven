#!/bin/sh
set -eu

ln_sfT() (
  OPTIND=1
  while getopts 'nbd' opt; do
    case "$opt" in
      n) na="-$opt" ;;
      b) bin= ;; # set but empty: ${bin+X}${bin-Y} -> X, unset -> Y
      d) dot=. ;;
    esac
  done
  shift $((OPTIND - 1))
  : ${1:?}
  case "${2:?}" in */)
    base=$(basename "$1")
    set -- "$1" "$2${dot-}${bin+${base%.*}}${bin-$base}"
    ;;
  esac
  sudo=$(check_sudo "$2")
  # shellcheck disable=SC2086 # no-archive passthrough
  archive ${na-} "$2"
  ${sudo-} ln -s "$1" "$2" # -fT 'effect' by archive
  if [ "${bin+set}" ]; then
    ${sudo-} chmod u+x "$2"
  fi
)

edit() (
  [ "${1:?}" = '-n' ] && na=${1} && shift
  target=$(realpath "${1:?}") && shift
  # If last arg starts with "<< ", use as stdin, simulate herestring
  i=0 && last=$(($# - 1))
  for arg in "$@"; do
    shift
    [ "$i" -eq "$last" ] && case "$arg" in
      '<< '*)
        ztdin=${arg#<< }
        continue
        ;;
    esac
    set -- "$@" "$arg"
    i=$((i + 1))
  done

  tmp=$(mktemp) && tmp2=$(mktemp) && trap 'rm -f "$tmp" "$tmp2"' EXIT INT TERM
  sudo=$(check_sudo "$target")
  ${sudo-} cat "$target" 2>/dev/null >"$tmp2" || : # may not exist
  "${@:-cat}" <"$tmp2" >"$tmp" || return 1
  append=${ztdin:-$(cat)}
  if [ "$append" ]; then
    [ -s "$tmp" ] && echo >>"$tmp"
    printf '%s\n' "$append" >>"$tmp"
  fi
  # shellcheck disable=SC2086 # no-archive passthrough
  archive -k ${na-} "$target"
  sync
  ${sudo-} mv "$tmp" "$target"
)

archive() (
  OPTIND=1
  while getopts 'kn' opt; do
    case "$opt" in
      k) # keep original
        cpPR='cp -PR'
        ;;
      n) # callers no-archive passthrough, keep rm -> no separate `rm` call
        archive=
        ;;
    esac
  done
  shift $((OPTIND - 1))

  sudo=$(check_sudo "${1:?}")
  bak="$(dirname "$1")/.archive" && ${sudo-} mkdir -p "$bak"
  [ ! -L "$1" ] && [ ! -e "$1" ] && return

  if [ "${archive-true}" ]; then
    base=$(basename "$1")
    # shellcheck disable=SC2086 # split `cp -PR`
    ${sudo-} ${cpPR:-mv} "$1" "$bak/$base.$(date +%s).$(head -c1 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    # Keep last 10 copies
    # shellcheck disable=SC2016 # expand inside -c, not here
    ${sudo-} sh -c 'ls -dt "$1"* 2>/dev/null' _ "$bak/$base." | tail -n +11 | while read -r f; do
      ${sudo-} rm -rf "$f"
    done
  elif [ ! "${cpPR-}" ]; then
    ${sudo-} rm -rf "$1"
  fi
)

check_sudo() (
  [ "$(id -u)" -eq 0 ] && return #root
  [ -e "${1:?}" ] && [ ! -r "$1" ] && echo 'sudo' && return
  dir=$(dirname "$1")
  while [ ! -d "$dir" ]; do
    dir=$(dirname "$dir")
  done
  if [ ! -w "$dir" ]; then
    echo 'sudo'
  fi
)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

[ "${SOURCE-}" ] && return 0
INSTALL_DIR=${1:-$HOME/.lxz}

if [ -d "$INSTALL_DIR" ]; then
  git -C "$INSTALL_DIR" pull || printf '%b\n' "${RED}error: Failed to update${NC}"
else
  git clone https://github.com/haoadoreorange/lxz "$INSTALL_DIR"
fi

LOCAL_BIN="$HOME/.local/bin"
ln_sfT -b "$INSTALL_DIR/lxz.sh" "$LOCAL_BIN/"

printf '%b\n' "${GREEN}Installed lxz${NC}"
case ":$PATH:" in *:"$LOCAL_BIN":*) ;; *) printf '%b\n' "${YELLOW}warn: No $LOCAL_BIN in \$PATH${NC}" ;; esac
